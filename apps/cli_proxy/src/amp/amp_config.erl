-module(amp_config).
-behaviour(gen_server).

%% Hot-reloadable Amp CLI configuration

-export([
    start_link/0,
    is_enabled/0,
    get_upstream_url/0,
    get_model_mappings/0,
    force_model_mappings/0,
    resolve_upstream_key/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    enabled :: boolean(),
    upstream_url :: binary() | undefined,
    upstream_api_key :: binary() | undefined,
    upstream_api_keys :: [map()],
    model_mappings :: [map()],
    force_mappings :: boolean()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

is_enabled() ->
    case whereis(?MODULE) of
        undefined -> false;
        _Pid -> gen_server:call(?MODULE, is_enabled)
    end.

get_upstream_url() ->
    gen_server:call(?MODULE, get_upstream_url).

get_model_mappings() ->
    gen_server:call(?MODULE, get_model_mappings).

force_model_mappings() ->
    gen_server:call(?MODULE, force_model_mappings).

resolve_upstream_key(ClientKey) ->
    gen_server:call(?MODULE, {resolve_upstream_key, ClientKey}).

init([]) ->
    Config = load_from_config(),
    {ok, Config}.

handle_call(is_enabled, _From, #state{enabled = E} = State) ->
    {reply, E, State};
handle_call(get_upstream_url, _From, #state{upstream_url = U} = State) ->
    {reply, U, State};
handle_call(get_model_mappings, _From, #state{model_mappings = M} = State) ->
    {reply, M, State};
handle_call(force_model_mappings, _From, #state{force_mappings = F} = State) ->
    {reply, F, State};
handle_call({resolve_upstream_key, ClientKey}, _From, State) ->
    Key = do_resolve_key(ClientKey, State),
    {reply, Key, State};
handle_call(_, _From, State) ->
    {reply, undefined, State}.

handle_cast(reload, _State) ->
    {noreply, load_from_config()};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

load_from_config() ->
    AmpConfig = config_loader:get(ampcode, #{}),
    #state{
        enabled = AmpConfig =/= #{} andalso AmpConfig =/= undefined,
        upstream_url = maps:get(upstream_url, AmpConfig, undefined),
        upstream_api_key = maps:get(upstream_api_key, AmpConfig, undefined),
        upstream_api_keys = maps:get(upstream_api_keys, AmpConfig, []),
        model_mappings = maps:get(model_mappings, AmpConfig, []),
        force_mappings = maps:get(force_model_mappings, AmpConfig, false)
    }.

do_resolve_key(ClientKey, #state{upstream_api_keys = Entries, upstream_api_key = Default}) ->
    case find_client_entry(ClientKey, Entries) of
        {ok, Key} -> Key;
        nomatch ->
            case Default of
                undefined -> resolve_env_key();
                Key -> Key
            end
    end.

find_client_entry(_ClientKey, []) -> nomatch;
find_client_entry(ClientKey, [#{upstream_api_key := Key, api_keys := Keys} | Rest]) ->
    case lists:member(ClientKey, Keys) of
        true -> {ok, Key};
        false -> find_client_entry(ClientKey, Rest)
    end;
find_client_entry(ClientKey, [_ | Rest]) ->
    find_client_entry(ClientKey, Rest).

resolve_env_key() ->
    case os:getenv("AMP_API_KEY") of
        false -> undefined;
        Key -> list_to_binary(Key)
    end.
