-module(model_registry).
-behaviour(gen_server).

%% Model registry: tracks available models across providers
%% ETS-backed for concurrent reads

-export([
    start_link/0,
    register_client/3,
    unregister_client/1,
    get_available_models/0,
    get_available_models/1,
    is_model_available/1,
    is_model_available/2,
    get_model_info/1,
    set_quota_exceeded/2,
    resolve_alias/1,
    is_excluded/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MODELS_TAB, model_registry_models).
-define(CLIENTS_TAB, model_registry_clients).

-record(model_reg, {
    id :: binary(),
    total_count = 0 :: non_neg_integer(),
    providers = #{} :: #{binary() => non_neg_integer()},
    info = #{} :: map(),
    quota_exceeded = #{} :: #{binary() => integer()},
    suspended = #{} :: #{binary() => binary()}
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_client(binary(), binary(), [map()]) -> ok.
register_client(ClientId, Provider, Models) ->
    gen_server:call(?MODULE, {register_client, ClientId, Provider, Models}).

-spec unregister_client(binary()) -> ok.
unregister_client(ClientId) ->
    gen_server:call(?MODULE, {unregister_client, ClientId}).

-spec get_available_models() -> [map()].
get_available_models() ->
    get_available_models(openai).

-spec get_available_models(atom()) -> [map()].
get_available_models(HandlerType) ->
    gen_server:call(?MODULE, {get_available_models, HandlerType}).

-spec is_model_available(binary()) -> boolean().
is_model_available(ModelId) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{total_count = C}] when C > 0 -> true;
        _ -> false
    end.

-spec is_model_available(binary(), binary()) -> boolean().
is_model_available(ModelId, ClientId) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{} = Reg] ->
            not is_quota_exceeded(Reg, ClientId) andalso
            not is_suspended(Reg, ClientId);
        [] -> false
    end.

-spec get_model_info(binary()) -> map() | undefined.
get_model_info(ModelId) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{info = Info}] -> Info;
        [] -> undefined
    end.

-spec set_quota_exceeded(binary(), binary()) -> ok.
set_quota_exceeded(ClientId, ModelId) ->
    gen_server:cast(?MODULE, {quota_exceeded, ClientId, ModelId}).

%% Resolve model alias to real model name
-spec resolve_alias(binary()) -> binary().
resolve_alias(ModelId) ->
    Aliases = config_loader:get(model_aliases, #{}),
    maps:get(ModelId, Aliases, ModelId).

%% Check if model is excluded for a given channel/provider
-spec is_excluded(binary(), atom()) -> boolean().
is_excluded(ModelId, Provider) ->
    Exclusions = config_loader:get(model_exclusions, #{}),
    ProviderBin = atom_to_binary(Provider, utf8),
    ExcludedList = maps:get(ProviderBin, Exclusions, []),
    lists:any(fun(Pattern) ->
        case Pattern of
            <<"*">> -> true;
            _ ->
                case binary:match(Pattern, <<"*">>) of
                    nomatch -> Pattern =:= ModelId;
                    _ ->
                        RE = binary:replace(Pattern, <<"*">>, <<".*">>, [global]),
                        case re:run(ModelId, RE) of
                            {match, _} -> true;
                            nomatch -> false
                        end
                end
        end
    end, ExcludedList).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    _ = ets:new(?MODELS_TAB, [named_table, set, public, {read_concurrency, true},
                          {keypos, #model_reg.id}]),
    _ = ets:new(?CLIENTS_TAB, [named_table, set, protected]),
    {ok, #{}}.

handle_call({register_client, ClientId, Provider, Models}, _From, State) ->
    %% Remove old registrations for this client
    unregister_client_internal(ClientId),
    %% Register new models
    lists:foreach(fun(ModelInfo) ->
        ModelId = maps:get(<<"id">>, ModelInfo, <<>>),
        case ModelId of
            <<>> -> ok;
            _ -> register_model(ClientId, Provider, ModelId, ModelInfo)
        end
    end, Models),
    %% Store client → models mapping
    ModelIds = [maps:get(<<"id">>, M, <<>>) || M <- Models, maps:get(<<"id">>, M, <<>>) =/= <<>>],
    ets:insert(?CLIENTS_TAB, {ClientId, Provider, ModelIds}),
    {reply, ok, State};

handle_call({unregister_client, ClientId}, _From, State) ->
    unregister_client_internal(ClientId),
    {reply, ok, State};

handle_call({get_available_models, HandlerType}, _From, State) ->
    Models = ets:foldl(fun(#model_reg{total_count = C, info = Info} = _Reg, Acc) when C > 0 ->
        [format_model(Info, HandlerType) | Acc];
    (_, Acc) -> Acc
    end, [], ?MODELS_TAB),
    {reply, Models, State};

handle_call(_Req, _From, State) ->
    {reply, error, State}.

handle_cast({quota_exceeded, ClientId, ModelId}, State) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{quota_exceeded = QE} = Reg] ->
            Expiry = erlang:system_time(second) + 300,
            Reg1 = Reg#model_reg{quota_exceeded = QE#{ClientId => Expiry}},
            ets:insert(?MODELS_TAB, Reg1);
        [] -> ok
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

register_model(_ClientId, Provider, ModelId, ModelInfo) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{total_count = C, providers = P} = Reg] ->
            ProvCount = maps:get(Provider, P, 0),
            Reg1 = Reg#model_reg{
                total_count = C + 1,
                providers = P#{Provider => ProvCount + 1},
                info = ModelInfo
            },
            ets:insert(?MODELS_TAB, Reg1);
        [] ->
            Reg = #model_reg{
                id = ModelId,
                total_count = 1,
                providers = #{Provider => 1},
                info = ModelInfo
            },
            ets:insert(?MODELS_TAB, Reg)
    end,
    %% Update CLIPS model-capability fact
    update_clips_capability(ModelId, ModelInfo, Provider).

unregister_client_internal(ClientId) ->
    case ets:lookup(?CLIENTS_TAB, ClientId) of
        [{ClientId, Provider, ModelIds}] ->
            lists:foreach(fun(ModelId) ->
                case ets:lookup(?MODELS_TAB, ModelId) of
                    [#model_reg{total_count = C, providers = P} = Reg] when C > 0 ->
                        ProvCount = maps:get(Provider, P, 1),
                        Reg1 = Reg#model_reg{
                            total_count = C - 1,
                            providers = case ProvCount - 1 of
                                0 -> maps:remove(Provider, P);
                                N -> P#{Provider => N}
                            end
                        },
                        ets:insert(?MODELS_TAB, Reg1);
                    _ -> ok
                end
            end, ModelIds),
            ets:delete(?CLIENTS_TAB, ClientId);
        [] -> ok
    end.

is_quota_exceeded(#model_reg{quota_exceeded = QE}, ClientId) ->
    case maps:get(ClientId, QE, 0) of
        0 -> false;
        Expiry ->
            Now = erlang:system_time(second),
            Expiry > Now
    end.

is_suspended(#model_reg{suspended = S}, ClientId) ->
    maps:is_key(ClientId, S).

format_model(Info, openai) ->
    #{
        <<"id">> => maps:get(<<"id">>, Info, <<>>),
        <<"object">> => <<"model">>,
        <<"created">> => maps:get(<<"created">>, Info, 0),
        <<"owned_by">> => maps:get(<<"provider">>, Info, <<"system">>)
    };
format_model(Info, _) ->
    Info.

update_clips_capability(ModelId, ModelInfo, Provider) ->
    case whereis(clips_engine) of
        undefined -> ok;
        _Pid ->
            Thinking = maps:get(<<"thinking">>, ModelInfo, undefined),
            case Thinking of
                undefined -> ok;
                ThinkMap ->
                    clips_engine:assert({model_capability, #{
                        model => ModelId,
                        provider => Provider,
                        thinking_min => maps:get(<<"min">>, ThinkMap, 0),
                        thinking_max => maps:get(<<"max">>, ThinkMap, 0),
                        thinking_mode => determine_thinking_mode(ThinkMap)
                    }})
            end
    end.

determine_thinking_mode(#{<<"levels">> := L, <<"min">> := Min}) when L =/= [], Min > 0 ->
    <<"hybrid">>;
determine_thinking_mode(#{<<"levels">> := L}) when L =/= [] ->
    <<"level">>;
determine_thinking_mode(#{<<"min">> := Min}) when Min > 0 ->
    <<"budget">>;
determine_thinking_mode(_) ->
    <<"none">>.
