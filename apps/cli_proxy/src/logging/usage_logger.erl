-module(usage_logger).
-behaviour(gen_server).

%% Usage statistics tracking
%% Per-credential counters + optional queue for external consumption

-export([
    start_link/0,
    log/1,
    batch_log/2,
    get_usage/0,
    get_usage/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, usage_logger_tab).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec log(map()) -> ok.
log(Record) ->
    gen_server:cast(?MODULE, {log, Record}).

-spec batch_log(node(), [map()]) -> ok.
batch_log(_SourceNode, Records) ->
    gen_server:cast(?MODULE, {batch_log, Records}).

-spec get_usage() -> [map()].
get_usage() ->
    gen_server:call(?MODULE, get_usage).

-spec get_usage(binary()) -> map().
get_usage(CredentialId) ->
    gen_server:call(?MODULE, {get_usage, CredentialId}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?TABLE, [named_table, set, public]),
    {ok, #{}}.

handle_call(get_usage, _From, State) ->
    All = ets:tab2list(?TABLE),
    Usage = [#{credential_id => K, success => S, failed => F}
             || {K, S, F} <- All],
    {reply, Usage, State};

handle_call({get_usage, CredId}, _From, State) ->
    case ets:lookup(?TABLE, CredId) of
        [{CredId, Success, Failed}] ->
            {reply, #{success => Success, failed => Failed}, State};
        [] ->
            {reply, #{success => 0, failed => 0}, State}
    end;

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({log, Record}, State) ->
    do_log(Record),
    {noreply, State};

handle_cast({batch_log, Records}, State) ->
    lists:foreach(fun do_log/1, Records),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

do_log(#{credential_id := CredId, status := Status}) ->
    case Status >= 200 andalso Status < 300 of
        true ->
            ets:update_counter(?TABLE, CredId, {2, 1}, {CredId, 0, 0});
        false ->
            ets:update_counter(?TABLE, CredId, {3, 1}, {CredId, 0, 0})
    end;
do_log(_) ->
    ok.
