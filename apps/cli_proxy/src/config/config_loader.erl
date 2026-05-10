-module(config_loader).
-behaviour(gen_server).

%% ETS-backed configuration access
%% Provides O(1) reads for hot-path config lookups

-export([
    start_link/0,
    start_link/1,
    get/1,
    get/2,
    get_all/0,
    apply_config/1,
    update_api_keys/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CONFIG_TABLE, config_loader_tab).
-define(API_KEYS_TABLE, api_keys_tab).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    start_link(#{}).

start_link(InitialConfig) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [InitialConfig], []).

%% Get a single config value by key (atom or binary)
-spec get(atom() | binary()) -> term() | undefined.
get(Key) ->
    get(Key, undefined).

-spec get(atom() | binary(), term()) -> term().
get(Key, Default) ->
    case ets:lookup(?CONFIG_TABLE, Key) of
        [{Key, Value}] -> Value;
        [] -> Default
    end.

%% Get all config as a map
-spec get_all() -> map().
get_all() ->
    maps:from_list(ets:tab2list(?CONFIG_TABLE)).

%% Apply a full config map (replaces all values)
-spec apply_config(map()) -> ok.
apply_config(Config) ->
    gen_server:call(?MODULE, {apply_config, Config}).

%% Update API keys (hot-reloadable)
-spec update_api_keys([binary()]) -> ok.
update_api_keys(Keys) ->
    gen_server:call(?MODULE, {update_api_keys, Keys}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([InitialConfig]) ->
    ets:new(?CONFIG_TABLE, [named_table, set, public, {read_concurrency, true}]),
    ets:new(?API_KEYS_TABLE, [named_table, set, public, {read_concurrency, true}]),
    do_apply_config(InitialConfig),
    {ok, #{config => InitialConfig}}.

handle_call({apply_config, Config}, _From, State) ->
    do_apply_config(Config),
    {reply, ok, State#{config => Config}};

handle_call({update_api_keys, Keys}, _From, State) ->
    ets:delete_all_objects(?API_KEYS_TABLE),
    lists:foreach(fun(K) -> ets:insert(?API_KEYS_TABLE, {K, true}) end, Keys),
    ets:insert(?CONFIG_TABLE, {api_keys, Keys}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, error, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

do_apply_config(Config) when is_map(Config) ->
    %% Store each key-value pair in ETS
    maps:foreach(fun(K, V) ->
        ets:insert(?CONFIG_TABLE, {K, V})
    end, Config),
    %% Update API keys table
    case maps:get(api_keys, Config, maps:get(<<"api_keys">>, Config, undefined)) of
        undefined -> ok;
        Keys when is_list(Keys) ->
            ets:delete_all_objects(?API_KEYS_TABLE),
            lists:foreach(fun(K) -> ets:insert(?API_KEYS_TABLE, {K, true}) end, Keys)
    end;
do_apply_config(_) ->
    ok.
