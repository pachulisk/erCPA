-module(usage_queue).
-behaviour(gen_server).

%% In-memory usage statistics queue with configurable retention
%% Compatible with Redis RESP protocol via resp_handler

-export([start_link/0, enqueue/1, pop_oldest/1, is_enabled/0, get_retention/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CLEANUP_INTERVAL, 10000). %% 10 seconds

-record(state, {
    queue :: queue:queue({integer(), binary()}),
    size :: non_neg_integer()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec enqueue(binary()) -> ok.
enqueue(Payload) ->
    case is_enabled() of
        true -> gen_server:cast(?MODULE, {enqueue, Payload});
        false -> ok
    end.

-spec pop_oldest(pos_integer()) -> [binary()].
pop_oldest(Count) ->
    gen_server:call(?MODULE, {pop, Count}).

-spec is_enabled() -> boolean().
is_enabled() ->
    config_loader:get(usage_statistics_enabled, false) =:= true.

-spec get_retention() -> integer().
get_retention() ->
    config_loader:get(usage_queue_retention_seconds, 60).

init([]) ->
    schedule_cleanup(),
    {ok, #state{queue = queue:new(), size = 0}}.

handle_call({pop, Count}, _From, #state{queue = Q, size = S} = State) ->
    {Items, Q1, S1} = pop_n(Q, S, Count, []),
    {reply, Items, State#state{queue = Q1, size = S1}};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast({enqueue, Payload}, #state{queue = Q, size = S} = State) ->
    Now = erlang:system_time(second),
    Q1 = queue:in({Now, Payload}, Q),
    {noreply, State#state{queue = Q1, size = S + 1}};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(cleanup, #state{queue = Q, size = S} = State) ->
    Retention = get_retention(),
    Cutoff = erlang:system_time(second) - Retention,
    {Q1, S1} = prune(Q, S, Cutoff),
    schedule_cleanup(),
    {noreply, State#state{queue = Q1, size = S1}};
handle_info(_, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

pop_n(Q, S, 0, Acc) -> {lists:reverse(Acc), Q, S};
pop_n(Q, S, N, Acc) ->
    case queue:out(Q) of
        {{value, {_Ts, Payload}}, Q1} ->
            pop_n(Q1, S - 1, N - 1, [Payload | Acc]);
        {empty, Q} ->
            {lists:reverse(Acc), Q, S}
    end.

prune(Q, S, Cutoff) ->
    case queue:peek(Q) of
        {value, {Ts, _}} when Ts < Cutoff ->
            {_, Q1} = queue:out(Q),
            prune(Q1, S - 1, Cutoff);
        _ ->
            {Q, S}
    end.

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).
