-module(aistudio_executor).
-behaviour(gen_server).

%% AI Studio executor — handles WebSocket runtime credentials
%% Credentials arrive dynamically via WS connections

-export([start_link/1, execute/4, execute_stream/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    config :: map(),
    pool :: atom()
}).

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Config], []).

execute(AuthId, Auth, Request, Opts) ->
    gen_server:call(?MODULE, {execute, AuthId, Auth, Request, Opts}, 120000).

execute_stream(AuthId, Auth, Request, Opts) ->
    gen_server:call(?MODULE, {execute_stream, AuthId, Auth, Request, Opts}, 120000).

init([Config]) ->
    {ok, #state{config = Config, pool = aistudio_pool}}.

handle_call({execute, _AuthId, Auth, Request, _Opts}, From, State) ->
    spawn_link(fun() ->
        gen_server:reply(From, do_execute(Auth, Request, State))
    end),
    {noreply, State};

handle_call({execute_stream, _AuthId, Auth, Request, Opts}, From, State) ->
    Caller = maps:get(caller, Opts, element(1, From)),
    spawn_link(fun() ->
        gen_server:reply(From, do_execute_stream(Auth, Request, State, Caller))
    end),
    {noreply, State};

handle_call(_, _From, State) -> {reply, {error, unknown}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

do_execute(Auth, Request, State) ->
    %% AI Studio uses Gemini API format with OAuth token
    URL = build_url(Auth, Request),
    Headers = [{<<"Content-Type">>, <<"application/json">>},
               {<<"Authorization">>, <<"Bearer ", (maps:get(<<"access_token">>, Auth, <<>>))/binary>>}],
    Body = jiffy:encode(Request),
    case hackney:post(URL, Headers, Body, [{pool, State#state.pool}, {recv_timeout, 120000}]) of
        {ok, S, _, Ref} when S >= 200, S < 300 ->
            {ok, RB} = hackney:body(Ref),
            {ok, jiffy:decode(RB, [return_maps])};
        {ok, S, _, Ref} ->
            {ok, RB} = hackney:body(Ref),
            {error, S, RB};
        {error, R} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [R]))}
    end.

do_execute_stream(Auth, Request, State, Caller) ->
    URL = build_url_stream(Auth, Request),
    Headers = [{<<"Content-Type">>, <<"application/json">>},
               {<<"Authorization">>, <<"Bearer ", (maps:get(<<"access_token">>, Auth, <<>>))/binary>>}],
    Body = jiffy:encode(Request),
    case hackney:post(URL, Headers, Body, [{pool, State#state.pool}, {recv_timeout, 120000}, async]) of
        {ok, Ref} ->
            stream_loop(Ref, Caller),
            {ok, self()};
        {error, R} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [R]))}
    end.

stream_loop(Ref, Caller) ->
    receive
        {hackney_response, Ref, {status, S, _}} when S >= 200, S < 300 -> stream_loop(Ref, Caller);
        {hackney_response, Ref, {status, S, _}} -> Caller ! {stream_error, S, <<"error">>};
        {hackney_response, Ref, {headers, _}} -> stream_loop(Ref, Caller);
        {hackney_response, Ref, done} -> Caller ! stream_done;
        {hackney_response, Ref, Data} when is_binary(Data) ->
            Caller ! {stream_chunk, Data}, stream_loop(Ref, Caller);
        {hackney_response, Ref, {error, R}} ->
            Caller ! {stream_error, 502, iolist_to_binary(io_lib:format("~p", [R]))}
    after 120000 -> Caller ! {stream_error, 408, <<"timeout">>}
    end.

build_url(Auth, Request) ->
    BaseURL = maps:get(<<"base_url">>, Auth, <<"https://generativelanguage.googleapis.com">>),
    Model = maps:get(<<"model">>, Request, <<"gemini-pro">>),
    <<BaseURL/binary, "/v1beta/models/", Model/binary, ":generateContent">>.

build_url_stream(Auth, Request) ->
    BaseURL = maps:get(<<"base_url">>, Auth, <<"https://generativelanguage.googleapis.com">>),
    Model = maps:get(<<"model">>, Request, <<"gemini-pro">>),
    <<BaseURL/binary, "/v1beta/models/", Model/binary, ":streamGenerateContent?alt=sse">>.
