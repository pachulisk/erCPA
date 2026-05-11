-module(gemini_executor).
-behaviour(gen_server).

%% Gemini (Google AI) provider executor
%% Sends requests to generativelanguage.googleapis.com

-export([start_link/1, execute/4, execute_stream/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_BASE_URL, <<"https://generativelanguage.googleapis.com">>).

-record(state, {
    config :: map(),
    pool :: atom()
}).

%%====================================================================
%% API
%%====================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

-spec execute(binary(), map(), map(), map()) -> {ok, map()} | {error, integer(), binary()}.
execute(AuthId, Auth, Request, Opts) ->
    gen_server:call(?MODULE, {execute, AuthId, Auth, Request, Opts}, 120000).

-spec execute_stream(binary(), map(), map(), map()) -> {ok, pid()} | {error, integer(), binary()}.
execute_stream(AuthId, Auth, Request, Opts) ->
    gen_server:call(?MODULE, {execute_stream, AuthId, Auth, Request, Opts}, 120000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Config]) ->
    {ok, #state{config = Config, pool = gemini_pool}}.

handle_call({execute, _AuthId, Auth, Request, Opts}, From, State) ->
    spawn_link(fun() ->
        Result = do_execute(Auth, Request, Opts, State),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call({execute_stream, _AuthId, Auth, Request, Opts}, From, State) ->
    Caller = maps:get(caller, Opts, element(1, From)),
    spawn_link(fun() ->
        Result = do_execute_stream(Auth, Request, Opts, State, Caller),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.

%%====================================================================
%% Internal
%%====================================================================

do_execute(Auth, Request, Opts, State) ->
    Model = maps:get(<<"model">>, Request, maps:get(model, Opts, <<"gemini-pro">>)),
    URL = build_url(Auth, Model, false),
    Headers = build_headers(Auth),
    Body = jiffy:encode(Request),

    case hackney:post(URL, Headers, Body, [{pool, State#state.pool},
                                            {recv_timeout, 120000}]) of
        {ok, Status, _RH, ClientRef} when Status >= 200, Status < 300 ->
            {ok, RespBody} = hackney:body(ClientRef),
            {ok, jiffy:decode(RespBody, [return_maps])};
        {ok, Status, _RH, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            {error, Status, RespBody};
        {error, Reason} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_execute_stream(Auth, Request, Opts, State, Caller) ->
    Model = maps:get(<<"model">>, Request, maps:get(model, Opts, <<"gemini-pro">>)),
    URL = build_url(Auth, Model, true),
    Headers = build_headers(Auth),
    Body = jiffy:encode(Request),

    case hackney:post(URL, Headers, Body, [{pool, State#state.pool},
                                            {recv_timeout, 120000},
                                            async]) of
        {ok, ClientRef} ->
            stream_loop(ClientRef, Caller),
            {ok, self()};
        {error, Reason} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

stream_loop(ClientRef, Caller) ->
    receive
        {hackney_response, ClientRef, {status, Status, _}} ->
            case Status >= 200 andalso Status < 300 of
                true -> stream_loop(ClientRef, Caller);
                false -> Caller ! {stream_error, Status, <<"upstream error">>}
            end;
        {hackney_response, ClientRef, {headers, _}} ->
            stream_loop(ClientRef, Caller);
        {hackney_response, ClientRef, done} ->
            Caller ! stream_done;
        {hackney_response, ClientRef, Data} when is_binary(Data) ->
            Caller ! {stream_chunk, Data},
            stream_loop(ClientRef, Caller);
        {hackney_response, ClientRef, {error, Reason}} ->
            Caller ! {stream_error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    after 120000 ->
        Caller ! {stream_error, 408, <<"timeout">>}
    end.

build_url(Auth, Model, Stream) ->
    BaseURL = maps:get(<<"base_url">>, Auth, ?DEFAULT_BASE_URL),
    Action = case Stream of
        true -> <<"streamGenerateContent?alt=sse">>;
        false -> <<"generateContent">>
    end,
    <<BaseURL/binary, "/v1beta/models/", Model/binary, ":", Action/binary>>.

build_headers(Auth) ->
    case maps:get(<<"access_token">>, Auth, undefined) of
        undefined ->
            %% API key auth
            APIKey = maps:get(<<"api_key">>, Auth, <<>>),
            [{<<"Content-Type">>, <<"application/json">>},
             {<<"x-goog-api-key">>, APIKey}];
        Token ->
            %% OAuth token
            [{<<"Content-Type">>, <<"application/json">>},
             {<<"Authorization">>, <<"Bearer ", Token/binary>>}]
    end.
