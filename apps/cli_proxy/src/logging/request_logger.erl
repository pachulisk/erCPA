-module(request_logger).
-behaviour(gen_server).

%% Async request logging with file rotation

-export([start_link/0, log/1, is_enabled/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    enabled :: boolean(),
    error_only :: boolean(),
    log_dir :: string(),
    fd :: file:io_device() | undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec log(map()) -> ok.
log(Entry) ->
    gen_server:cast(?MODULE, {log, Entry}).

-spec is_enabled() -> boolean().
is_enabled() ->
    case whereis(?MODULE) of
        undefined -> false;
        _Pid -> gen_server:call(?MODULE, is_enabled)
    end.

init([]) ->
    Enabled = config_loader:get(request_log, false),
    LogDir = config_loader:get(log_dir, "/tmp/ercpa_logs"),
    Fd = case Enabled of
        true ->
            ok = filelib:ensure_dir(filename:join(LogDir, "dummy")),
            Path = filename:join(LogDir, "requests.log"),
            {ok, F} = file:open(Path, [append, raw, binary]),
            F;
        false ->
            undefined
    end,
    {ok, #state{enabled = Enabled, error_only = false, log_dir = LogDir, fd = Fd}}.

handle_call(is_enabled, _From, #state{enabled = E} = State) ->
    {reply, E, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast({log, Entry}, #state{enabled = true, fd = Fd} = State) when Fd =/= undefined ->
    _ = case should_log(Entry, State#state.error_only) of
        true ->
            Line = format_entry(Entry),
            file:write(Fd, [Line, <<"\n">>]);
        false ->
            ok
    end,
    {noreply, State};
handle_cast({log, _Entry}, State) ->
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, #state{fd = undefined}) -> ok;
terminate(_Reason, #state{fd = Fd}) -> file:close(Fd).

should_log(#{status := S}, true) when S < 400 -> false;
should_log(_, _) -> true.

format_entry(#{method := Method, path := Path, status := Status} = Entry) ->
    Ts = maps:get(timestamp, Entry, erlang:system_time(millisecond)),
    Latency = maps:get(latency_ms, Entry, 0),
    Model = maps:get(model, Entry, <<>>),
    jiffy:encode(#{
        <<"ts">> => Ts,
        <<"method">> => Method,
        <<"path">> => Path,
        <<"status">> => Status,
        <<"latency_ms">> => Latency,
        <<"model">> => Model
    });
format_entry(Entry) ->
    jiffy:encode(Entry).
