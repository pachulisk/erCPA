-module(vertex_executor).
-behaviour(gen_server).

%% Vertex AI (Google Cloud) executor
%% Uses service account authentication

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
    {ok, #state{config = Config, pool = vertex_pool}}.

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

handle_call(_, _From, State) -> {reply, {error, unknown}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

do_execute(Auth, Request, Opts, State) ->
    URL = build_url(Auth, Opts, false),
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

do_execute_stream(Auth, Request, Opts, State, Caller) ->
    URL = build_url(Auth, Opts, true),
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

build_url(Auth, Opts, Stream) ->
    ProjectId = maps:get(<<"project_id">>, Auth, <<>>),
    Location = maps:get(<<"location">>, Auth, <<"us-central1">>),
    Model = maps:get(model, Opts, <<"gemini-pro">>),
    Action = case Stream of
        true -> <<"streamGenerateContent?alt=sse">>;
        false -> <<"generateContent">>
    end,
    <<"https://", Location/binary,
      "-aiplatform.googleapis.com/v1/projects/", ProjectId/binary,
      "/locations/", Location/binary,
      "/publishers/google/models/", Model/binary, ":", Action/binary>>.

build_headers(Auth) ->
    Token = maps:get(<<"access_token">>, Auth, <<>>),
    [{<<"Content-Type">>, <<"application/json">>},
     {<<"Authorization">>, <<"Bearer ", Token/binary>>}].
