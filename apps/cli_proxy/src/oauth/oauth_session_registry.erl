-module(oauth_session_registry).

%% Registry for active OAuth sessions
%% Maps state tokens to session PIDs for callback routing

-export([start_link/0, register_session/2, find/1, unregister/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-behaviour(gen_server).

-define(TABLE, oauth_session_registry_tab).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_session(binary(), pid()) -> ok.
register_session(StateToken, Pid) ->
    gen_server:call(?MODULE, {register, StateToken, Pid}).

-spec find(binary()) -> {ok, pid()} | error.
find(StateToken) ->
    case ets:lookup(?TABLE, StateToken) of
        [{StateToken, Pid}] ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    ets:delete(?TABLE, StateToken),
                    error
            end;
        [] -> error
    end.

-spec unregister(binary()) -> ok.
unregister(StateToken) ->
    gen_server:cast(?MODULE, {unregister, StateToken}).

init([]) ->
    ets:new(?TABLE, [named_table, set, public, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register, StateToken, Pid}, _From, State) ->
    ets:insert(?TABLE, {StateToken, Pid}),
    monitor(process, Pid),
    {reply, ok, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast({unregister, StateToken}, State) ->
    ets:delete(?TABLE, StateToken),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% Clean up entries for dead sessions
    ets:match_delete(?TABLE, {'_', Pid}),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.
