-module(kimi_executor).
-behaviour(gen_server).

%% Kimi (Moonshot AI) executor

-export([start_link/1, execute/4, execute_stream/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_BASE_URL, <<"https://api.moonshot.cn">>).

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
    {ok, #state{config = Config, pool = kimi_pool}}.

handle_call({execute, _AuthId, Auth, Request, _Opts}, From, State) ->
    spawn_link(fun() ->
        gen_server:reply(From, do_execute(Auth, Request, State))
    end),
    {noreply, State};

handle_call({execute_stream, _AuthId, Auth, Request, _Opts}, From, State) ->
    Caller = element(1, From),
    spawn_link(fun() ->
        gen_server:reply(From, do_execute_stream(Auth, Request, State, Caller))
    end),
    {noreply, State};

handle_call(_, _From, State) -> {reply, {error, unknown}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

do_execute(Auth, Request, State) ->
    URL = build_url(Auth),
    Headers = build_headers(Auth),
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
    URL = build_url(Auth),
    Headers = build_headers(Auth),
    Body = jiffy:encode(Request#{<<"stream">> => true}),
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

build_url(Auth) ->
    BaseURL = maps:get(<<"base_url">>, Auth, ?DEFAULT_BASE_URL),
    <<BaseURL/binary, "/v1/chat/completions">>.

build_headers(Auth) ->
    Token = maps:get(<<"access_token">>, Auth, <<>>),
    [{<<"Content-Type">>, <<"application/json">>},
     {<<"Authorization">>, <<"Bearer ", Token/binary>>}].
