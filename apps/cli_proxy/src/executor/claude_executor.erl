-module(claude_executor).
-behaviour(gen_server).

%% Claude (Anthropic) provider executor
%% Sends requests to https://api.anthropic.com/v1/messages

-export([start_link/1, execute/4, execute_stream/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_BASE_URL, <<"https://api.anthropic.com">>).
-define(API_VERSION, <<"2023-06-01">>).

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
    Pool = claude_pool,
    %% hackney pool will be created on first use
    {ok, #state{config = Config, pool = Pool}}.

handle_call({execute, _AuthId, Auth, Request, _Opts}, From, State) ->
    spawn_link(fun() ->
        Result = do_execute(Auth, Request, State),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call({execute_stream, _AuthId, Auth, Request, _Opts}, From, State) ->
    Caller = element(1, From),
    spawn_link(fun() ->
        Result = do_execute_stream(Auth, Request, State, Caller),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

do_execute(Auth, Request, State) ->
    BaseURL = maps:get(<<"base_url">>, Auth, ?DEFAULT_BASE_URL),
    URL = <<BaseURL/binary, "/v1/messages">>,
    Headers = build_headers(Auth),
    Body = jiffy:encode(Request),

    case hackney:post(URL, Headers, Body, [{pool, State#state.pool},
                                            {recv_timeout, 120000}]) of
        {ok, Status, _RespHeaders, ClientRef} when Status >= 200, Status < 300 ->
            {ok, RespBody} = hackney:body(ClientRef),
            {ok, jiffy:decode(RespBody, [return_maps])};
        {ok, Status, _RespHeaders, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            {error, Status, RespBody};
        {error, Reason} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

do_execute_stream(Auth, Request, State, Caller) ->
    BaseURL = maps:get(<<"base_url">>, Auth, ?DEFAULT_BASE_URL),
    URL = <<BaseURL/binary, "/v1/messages">>,
    Headers = build_headers(Auth),
    %% Ensure stream is true
    StreamReq = Request#{<<"stream">> => true},
    Body = jiffy:encode(StreamReq),

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
        {hackney_response, ClientRef, {status, Status, _Reason}} ->
            case Status of
                S when S >= 200, S < 300 ->
                    stream_loop(ClientRef, Caller);
                S ->
                    Caller ! {stream_error, S, <<"upstream error">>}
            end;
        {hackney_response, ClientRef, {headers, _Headers}} ->
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

build_headers(Auth) ->
    Token = maps:get(<<"access_token">>, Auth,
                maps:get(<<"api_key">>, Auth, <<>>)),
    [
        {<<"Content-Type">>, <<"application/json">>},
        {<<"x-api-key">>, Token},
        {<<"anthropic-version">>, ?API_VERSION},
        {<<"Accept">>, <<"application/json">>}
    ].
