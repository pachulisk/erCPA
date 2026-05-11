-module(credential_proc).
-behaviour(gen_statem).

%% Per-credential lifecycle process
%% States: ready | refreshing | cooldown | disabled
%% Each credential is its own process — no shared mutable state

-export([
    start_link/1,
    get_status/2,
    mark_result/3,
    disable/1,
    enable/1,
    get_metadata/2,
    get_auth/1,
    stop/1
]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3]).
-export([ready/3, refreshing/3, cooldown/3, disabled/3]).

-record(data, {
    id              :: binary(),
    provider        :: atom(),
    metadata        :: map(),
    backoff_level   :: non_neg_integer(),
    last_error      :: term(),
    model_states    :: #{binary() => model_state()},
    refresh_module  :: module() | undefined,
    backoff_base_ms :: pos_integer()
}).

-type model_state() :: #{
    available := boolean(),
    cooldown_until := integer(),
    backoff_level := non_neg_integer()
}.

%%====================================================================
%% API
%%====================================================================

start_link(Config) ->
    Id = maps:get(id, Config),
    gen_statem:start_link({local, proc_name(Id)}, ?MODULE, [Config], []).

-spec get_status(pid() | binary(), binary()) -> available | unavailable | disabled.
get_status(Pid, Model) when is_pid(Pid) ->
    gen_statem:call(Pid, {get_status, Model});
get_status(Id, Model) when is_binary(Id) ->
    gen_statem:call(proc_name(Id), {get_status, Model}).

-spec mark_result(pid() | binary(), binary(), integer()) -> ok.
mark_result(Pid, Model, StatusCode) when is_pid(Pid) ->
    gen_statem:call(Pid, {mark_result, Model, StatusCode});
mark_result(Id, Model, StatusCode) when is_binary(Id) ->
    gen_statem:call(proc_name(Id), {mark_result, Model, StatusCode}).

-spec disable(pid() | binary()) -> ok.
disable(Pid) when is_pid(Pid) ->
    gen_statem:cast(Pid, disable);
disable(Id) when is_binary(Id) ->
    gen_statem:cast(proc_name(Id), disable).

-spec enable(pid() | binary()) -> ok.
enable(Pid) when is_pid(Pid) ->
    gen_statem:cast(Pid, enable);
enable(Id) when is_binary(Id) ->
    gen_statem:cast(proc_name(Id), enable).

-spec get_metadata(pid() | binary(), binary()) -> term().
get_metadata(Pid, Key) when is_pid(Pid) ->
    gen_statem:call(Pid, {get_metadata, Key});
get_metadata(Id, Key) when is_binary(Id) ->
    gen_statem:call(proc_name(Id), {get_metadata, Key}).

-spec get_auth(binary()) -> {ok, map()} | {error, not_found}.
get_auth(Id) ->
    case whereis(proc_name(Id)) of
        undefined -> {error, not_found};
        Pid -> {ok, gen_statem:call(Pid, get_auth)}
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() -> [state_functions, state_enter].

init([Config]) ->
    Data = #data{
        id = maps:get(id, Config),
        provider = maps:get(provider, Config),
        metadata = maps:get(metadata, Config, #{}),
        backoff_level = 0,
        last_error = undefined,
        model_states = #{},
        refresh_module = maps:get(refresh_module, Config, undefined),
        backoff_base_ms = maps:get(backoff_base_ms, Config, 5000)
    },
    assert_to_clips(Data),
    register_models(Data),
    {ok, ready, Data}.

%%====================================================================
%% State: ready
%%====================================================================

ready(enter, _OldState, Data) ->
    %% Schedule refresh if we have a refresh module
    Delay = calc_refresh_delay(Data),
    case Delay of
        infinity -> {keep_state, Data};
        _ -> {keep_state, Data, [{state_timeout, Delay, time_to_refresh}]}
    end;

ready(state_timeout, time_to_refresh, Data) ->
    {next_state, refreshing, Data};

ready({call, From}, {get_status, Model}, Data) ->
    Status = check_model_status(Model, Data),
    {keep_state, Data, [{reply, From, Status}]};

ready({call, From}, {mark_result, Model, StatusCode}, Data) ->
    {NewState, Data1} = handle_mark_result(Model, StatusCode, Data),
    case NewState of
        ready -> {keep_state, Data1, [{reply, From, ok}]};
        cooldown -> {next_state, cooldown, Data1, [{reply, From, ok}]}
    end;

ready({call, From}, {get_metadata, Key}, Data) ->
    Val = maps:get(Key, Data#data.metadata, undefined),
    {keep_state, Data, [{reply, From, Val}]};

ready({call, From}, get_auth, Data) ->
    {keep_state, Data, [{reply, From, Data#data.metadata}]};

ready(cast, disable, Data) ->
    {next_state, disabled, Data};

ready(_EventType, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% State: refreshing
%%====================================================================

refreshing(enter, _OldState, Data) ->
    %% Spawn refresh process
    Self = self(),
    case Data#data.refresh_module of
        undefined ->
            %% No refresh module — go back to ready
            {next_state, ready, Data};
        Mod ->
            spawn_link(fun() ->
                Result = Mod:refresh(Data#data.metadata),
                gen_statem:cast(Self, {refresh_result, Result})
            end),
            {keep_state, Data, [{state_timeout, 60000, refresh_timeout}]}
    end;

refreshing(cast, {refresh_result, {ok, NewMetadata}}, Data) ->
    {next_state, ready, Data#data{
        metadata = NewMetadata,
        backoff_level = 0,
        last_error = undefined
    }};

refreshing(cast, {refresh_result, {error, Reason}}, Data) ->
    {next_state, cooldown, Data#data{last_error = Reason}};

refreshing(state_timeout, refresh_timeout, Data) ->
    {next_state, cooldown, Data#data{last_error = timeout}};

refreshing({call, From}, {get_status, Model}, Data) ->
    Status = check_model_status(Model, Data),
    {keep_state, Data, [{reply, From, Status}]};

refreshing({call, From}, {mark_result, Model, StatusCode}, Data) ->
    {_NewState, Data1} = handle_mark_result(Model, StatusCode, Data),
    {keep_state, Data1, [{reply, From, ok}]};

refreshing({call, From}, get_auth, Data) ->
    {keep_state, Data, [{reply, From, Data#data.metadata}]};

refreshing(cast, disable, Data) ->
    {next_state, disabled, Data};

refreshing(_EventType, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% State: cooldown
%%====================================================================

cooldown(enter, _OldState, Data) ->
    Delay = backoff_delay(Data#data.backoff_level, Data#data.backoff_base_ms),
    {keep_state, Data#data{backoff_level = Data#data.backoff_level + 1},
     [{state_timeout, Delay, cooldown_expired}]};

cooldown(state_timeout, cooldown_expired, Data) ->
    {next_state, ready, Data};

cooldown({call, From}, {get_status, _Model}, Data) ->
    {keep_state, Data, [{reply, From, unavailable}]};

cooldown({call, From}, {mark_result, Model, StatusCode}, Data) ->
    case StatusCode >= 200 andalso StatusCode < 300 of
        true ->
            %% Success while in cooldown — clear and go ready
            Data1 = clear_model_cooldown(Model, Data),
            {next_state, ready, Data1, [{reply, From, ok}]};
        false ->
            {keep_state, Data, [{reply, From, ok}]}
    end;

cooldown({call, From}, {get_metadata, Key}, Data) ->
    Val = maps:get(Key, Data#data.metadata, undefined),
    {keep_state, Data, [{reply, From, Val}]};

cooldown({call, From}, get_auth, Data) ->
    {keep_state, Data, [{reply, From, Data#data.metadata}]};

cooldown(cast, disable, Data) ->
    {next_state, disabled, Data};

cooldown(_EventType, _Event, Data) ->
    {keep_state, Data}.

%%====================================================================
%% State: disabled
%%====================================================================

disabled(enter, _OldState, _Data) ->
    keep_state_and_data;

disabled({call, From}, {get_status, _Model}, _Data) ->
    {keep_state_and_data, [{reply, From, disabled}]};

disabled({call, From}, {mark_result, _Model, _StatusCode}, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

disabled({call, From}, {get_metadata, Key}, Data) ->
    Val = maps:get(Key, Data#data.metadata, undefined),
    {keep_state_and_data, [{reply, From, Val}]};

disabled({call, From}, get_auth, Data) ->
    {keep_state, Data, [{reply, From, Data#data.metadata}]};

disabled(cast, enable, Data) ->
    {next_state, ready, Data#data{backoff_level = 0}};

disabled(_EventType, _Event, _Data) ->
    keep_state_and_data.

%%====================================================================
%% Terminate
%%====================================================================

terminate(_Reason, _State, #data{id = Id}) ->
    case whereis(model_registry) of
        undefined -> ok;
        _ -> model_registry:unregister_client(Id)
    end,
    case whereis(clips_engine) of
        undefined -> ok;
        _ -> clips_engine:retract({credential, Id})
    end,
    ok.

%%====================================================================
%% Internal
%%====================================================================

proc_name(Id) ->
    binary_to_atom(<<"cred_", Id/binary>>, utf8).

register_models(#data{id = Id, provider = Provider, metadata = Meta}) ->
    case whereis(model_registry) of
        undefined -> ok;
        _Pid ->
            case maps:get(<<"models">>, Meta, undefined) of
                undefined -> ok;
                Models when is_list(Models) ->
                    ProviderBin = atom_to_binary(Provider, utf8),
                    ModelInfos = [#{<<"id">> => M, <<"provider">> => ProviderBin} || M <- Models],
                    model_registry:register_client(Id, ProviderBin, ModelInfos);
                _ -> ok
            end
    end.

assert_to_clips(#data{id = Id, provider = Provider, metadata = Meta}) ->
    case whereis(clips_engine) of
        undefined -> ok;
        _Pid ->
            clips_engine:assert({credential, #{
                id => Id,
                provider => atom_to_binary(Provider, utf8),
                priority => maps:get(<<"priority">>, Meta, 0),
                status => active,
                cooldown_until => 0,
                backoff_level => 0,
                prefix => maps:get(<<"prefix">>, Meta, <<>>),
                has_websocket => no
            }})
    end.

check_model_status(Model, Data) ->
    %% Strip thinking suffix for model state lookup
    BaseModel = strip_thinking_suffix(Model),
    case maps:get(BaseModel, Data#data.model_states, undefined) of
        undefined -> available;
        #{available := false, cooldown_until := Until} ->
            Now = erlang:system_time(second),
            case Until > Now of
                true -> unavailable;
                false -> available
            end;
        #{available := true} -> available
    end.

handle_mark_result(Model, StatusCode, Data) when StatusCode >= 200, StatusCode < 300 ->
    %% Success — clear model cooldown
    Data1 = clear_model_cooldown(Model, Data),
    {ready, Data1};

handle_mark_result(Model, 429, Data) ->
    %% Rate limited — exponential backoff on model
    BaseModel = strip_thinking_suffix(Model),
    ModelState = maps:get(BaseModel, Data#data.model_states, default_model_state()),
    Level = maps:get(backoff_level, ModelState, 0),
    Now = erlang:system_time(second),
    Cooldown = min(trunc(math:pow(2, Level)), 1800),
    NewMS = ModelState#{
        available => false,
        cooldown_until => Now + Cooldown,
        backoff_level => Level + 1
    },
    Data1 = Data#data{model_states = maps:put(BaseModel, NewMS, Data#data.model_states)},
    {cooldown, Data1};

handle_mark_result(Model, StatusCode, Data) when StatusCode =:= 401;
                                                  StatusCode =:= 402;
                                                  StatusCode =:= 403 ->
    %% Auth error — 30 minute hold
    BaseModel = strip_thinking_suffix(Model),
    Now = erlang:system_time(second),
    NewMS = #{available => false, cooldown_until => Now + 1800, backoff_level => 0},
    Data1 = Data#data{model_states = maps:put(BaseModel, NewMS, Data#data.model_states)},
    {cooldown, Data1};

handle_mark_result(Model, StatusCode, Data) when StatusCode >= 500 ->
    %% Server error — short cooldown
    BaseModel = strip_thinking_suffix(Model),
    ModelState = maps:get(BaseModel, Data#data.model_states, default_model_state()),
    Level = maps:get(backoff_level, ModelState, 0),
    Now = erlang:system_time(second),
    Cooldown = min(trunc(math:pow(2, Level)), 60),
    NewMS = ModelState#{
        available => false,
        cooldown_until => Now + Cooldown,
        backoff_level => Level + 1
    },
    Data1 = Data#data{model_states = maps:put(BaseModel, NewMS, Data#data.model_states)},
    {ready, Data1};  %% Don't go to cooldown state for 5xx (just model-level)

handle_mark_result(_Model, _StatusCode, Data) ->
    {ready, Data}.

clear_model_cooldown(Model, Data) ->
    BaseModel = strip_thinking_suffix(Model),
    NewMS = default_model_state(),
    Data#data{model_states = maps:put(BaseModel, NewMS, Data#data.model_states)}.

default_model_state() ->
    #{available => true, cooldown_until => 0, backoff_level => 0}.

strip_thinking_suffix(Model) ->
    case binary:match(Model, <<"(">>) of
        {Pos, _} -> binary:part(Model, 0, Pos);
        nomatch -> Model
    end.

calc_refresh_delay(#data{refresh_module = undefined}) ->
    infinity;
calc_refresh_delay(#data{provider = claude}) ->
    4 * 3600 * 1000;  %% 4 hours
calc_refresh_delay(#data{provider = codex}) ->
    5 * 86400 * 1000;  %% 5 days
calc_refresh_delay(#data{provider = P}) when P =:= antigravity; P =:= kimi ->
    300000;  %% 5 minutes
calc_refresh_delay(_) ->
    3600000.  %% 1 hour default

backoff_delay(Level, BaseMs) ->
    min(BaseMs * (1 bsl Level), 300000).  %% Cap at 5 minutes
