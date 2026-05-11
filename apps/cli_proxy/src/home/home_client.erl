-module(home_client).
-behaviour(gen_server).

%% Satellite-side home control plane client
%% Uses Erlang distribution for communication with home node

-export([
    start_link/1,
    is_connected/0,
    select_auth/3,
    forward_usage/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    home_node :: node(),
    connected :: boolean(),
    config_cache :: map(),
    usage_buffer :: [map()],
    buffer_timer :: reference() | undefined
}).

%%====================================================================
%% API
%%====================================================================

start_link(HomeNode) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [HomeNode], []).

-spec is_connected() -> boolean().
is_connected() ->
    case whereis(?MODULE) of
        undefined -> false;
        _Pid -> gen_server:call(?MODULE, is_connected)
    end.

-spec select_auth(binary(), binary(), map()) ->
    {ok, map()} | {error, term()}.
select_auth(Model, SessionId, Headers) ->
    gen_server:call(?MODULE, {select_auth, Model, SessionId, Headers}, 5000).

-spec forward_usage(map()) -> ok.
forward_usage(UsageRecord) ->
    gen_server:cast(?MODULE, {log_usage, UsageRecord}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([HomeNode]) ->
    _ = net_kernel:monitor_nodes(true),
    Connected = case net_adm:ping(HomeNode) of
        pong ->
            _ = fetch_and_apply_config(HomeNode),
            true;
        pang ->
            false
    end,
    {ok, #state{
        home_node = HomeNode,
        connected = Connected,
        config_cache = #{},
        usage_buffer = [],
        buffer_timer = undefined
    }}.

handle_call(is_connected, _From, #state{connected = C} = State) ->
    {reply, C, State};

handle_call({select_auth, Model, SessionId, Headers},
            _From, #state{home_node = Home, connected = true} = State) ->
    case rpc:call(Home, conductor, select_credential, [Model, #{}, SessionId], 5000) of
        {ok, AuthId, Provider} ->
            {reply, {ok, #{auth_id => AuthId, provider => Provider}}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State};
        {badrpc, Reason} ->
            {reply, {error, {rpc_failed, Reason}}, State}
    end;

handle_call({select_auth, _, _, _}, _From, #state{connected = false} = State) ->
    {reply, {error, home_unavailable}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({log_usage, UsageRecord}, #state{usage_buffer = Buf} = State) ->
    Buf1 = [UsageRecord | Buf],
    State1 = case length(Buf1) >= 64 of
        true -> flush_usage(State#state{usage_buffer = Buf1});
        false -> ensure_flush_timer(State#state{usage_buffer = Buf1})
    end,
    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodedown, Node}, #state{home_node = Node} = State) ->
    {noreply, State#state{connected = false}};

handle_info({nodeup, Node}, #state{home_node = Node} = State) ->
    _ = fetch_and_apply_config(Node),
    State1 = flush_usage(State#state{connected = true}),
    {noreply, State1};

handle_info(flush_timer, State) ->
    State1 = flush_usage(State#state{buffer_timer = undefined}),
    {noreply, State1};

handle_info({config_updated, NewConfig}, State) ->
    apply_config_overlay(NewConfig),
    {noreply, State#state{config_cache = NewConfig}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

fetch_and_apply_config(HomeNode) ->
    case rpc:call(HomeNode, config_loader, get_all, [], 5000) of
        Config when is_map(Config) ->
            apply_config_overlay(Config);
        _ ->
            ok
    end.

apply_config_overlay(HomeConfig) ->
    %% Preserve local network settings, force satellite-mode settings
    LocalPort = config_loader:get(port),
    LocalHost = config_loader:get(host),
    Merged = HomeConfig#{
        port => LocalPort,
        host => LocalHost,
        disable_cooling => true,
        ws_auth => false,
        usage_statistics_enabled => true
    },
    config_loader:apply_config(Merged).

flush_usage(#state{usage_buffer = [], buffer_timer = T} = State) ->
    _ = cancel_timer(T),
    State#state{buffer_timer = undefined};
flush_usage(#state{home_node = Home, usage_buffer = Buf, connected = true} = State) ->
    %% Forward buffered usage to home node
    _ = rpc:cast(Home, usage_logger, batch_log, [node(), Buf]),
    _ = cancel_timer(State#state.buffer_timer),
    State#state{usage_buffer = [], buffer_timer = undefined};
flush_usage(State) ->
    State.  %% Keep buffering if disconnected

ensure_flush_timer(#state{buffer_timer = undefined} = State) ->
    Ref = erlang:send_after(500, self(), flush_timer),
    State#state{buffer_timer = Ref};
ensure_flush_timer(State) ->
    State.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).
