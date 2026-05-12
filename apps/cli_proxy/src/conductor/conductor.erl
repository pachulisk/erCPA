-module(conductor).
-behaviour(gen_server).

%% Request orchestration: credential selection + translation + execution + retry
%% Integrates with CLIPS for selection and credential_proc for state management

-export([
    start_link/0,
    execute/3,
    execute/4,
    select_credential/2,
    select_credential/3,
    classify_status/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Execute a request with automatic credential selection and retry
-spec execute(atom(), binary(), map()) ->
    {ok, map()} | {ok, stream, pid()} | {error, integer(), binary()}.
execute(SourceFormat, Model, Request) ->
    execute(SourceFormat, Model, Request, #{}).

-spec execute(atom(), binary(), map(), map()) ->
    {ok, map()} | {ok, stream, pid()} | {error, integer(), binary()}.
execute(SourceFormat, Model, Request, Opts) ->
    gen_server:call(?MODULE, {execute, SourceFormat, Model, Request, Opts}, 120000).

%% Select a credential for a model (exposed for testing)
-spec select_credential(binary(), map()) -> {ok, binary(), atom()} | {error, no_credential_available}.
select_credential(Model, Opts) ->
    select_credential(Model, Opts, <<>>).

-spec select_credential(binary(), map(), binary()) -> {ok, binary(), atom()} | {error, no_credential_available}.
select_credential(Model, _Opts, SessionId) ->
    %% Use CLIPS for selection
    RequestId = generate_request_id(),
    Now = erlang:system_time(second),

    _ = clips_engine:assert({select_request, #{
        id => RequestId,
        model => Model,
        session_id => SessionId,
        need_websocket => no,
        now => Now
    }}),
    _ = clips_engine:run(),

    Result = clips_engine:query(selection_result, <<"request-id">>, RequestId),

    %% Clean up transient facts
    _ = clips_engine:retract({select_request, RequestId}),

    case Result of
        {ok, #{<<"credential-id">> := CredId}} ->
            %% Look up provider for this credential
            Provider = get_provider(CredId),
            {ok, CredId, Provider};
        error ->
            {error, no_credential_available}
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call({execute, SourceFormat, Model, Request, Opts}, From, State) ->
    MaxRetries = config_loader:get(request_retry, 3),
    MaxCreds = config_loader:get(max_retry_credentials, 0),
    Stream = maps:get(<<"stream">>, Request, false),

    case Stream of
        true ->
            Caller = element(1, From),
            spawn_link(fun() ->
                Result = execute_with_retry(SourceFormat, Model, Request,
                    Opts#{caller => Caller}, true, MaxRetries, MaxCreds, 0),
                gen_server:reply(From, Result)
            end),
            {noreply, State};
        false ->
            Result = execute_with_retry(SourceFormat, Model, Request, Opts,
                                        false, MaxRetries, MaxCreds, 0),
            {reply, Result, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal - Retry Loop
%%====================================================================

execute_with_retry(_SF, _Model, _Req, _Opts, _Stream, 0, _MaxCreds, _Tried) ->
    {error, 503, <<"max retries exceeded">>};
execute_with_retry(_SF, _Model, _Req, _Opts, _Stream, _Retries, MaxCreds, Tried)
  when MaxCreds > 0, Tried >= MaxCreds ->
    {error, 503, <<"max credentials exceeded">>};
execute_with_retry(SourceFormat, Model, Request, Opts, Stream, Retries, MaxCreds, Tried) ->
    SessionId = maps:get(session_id, Opts, <<>>),
    case select_credential(Model, Opts, SessionId) of
        {error, no_credential_available} ->
            {error, 503, <<"no credential available">>};
        {ok, AuthId, Provider} ->
            %% Translate request
            TranslatedReq = translator_registry:translate_request(
                SourceFormat, Provider, Model, Request, Stream),

            %% Apply payload rules
            PayloadConfig = config_loader:get(payload, #{}),
            FinalReq = case is_map(PayloadConfig) andalso map_size(PayloadConfig) > 0 of
                true -> payload_rules:apply_rules(TranslatedReq, Model, Provider, PayloadConfig);
                false -> TranslatedReq
            end,

            %% Execute via provider executor
            case do_execute(Provider, AuthId, FinalReq, Stream, Opts) of
                {ok, Response} ->
                    mark_credential_result(AuthId, Model, 200),
                    _ = bind_session(SessionId, AuthId),
                    TranslatedResp = translator_registry:translate_nonstream(
                        SourceFormat, Provider, Response),
                    {ok, TranslatedResp};
                {ok, stream, StreamPid} ->
                    mark_credential_result(AuthId, Model, 200),
                    _ = bind_session(SessionId, AuthId),
                    {ok, stream, StreamPid};
                {error, Status, Body} ->
                    mark_credential_result(AuthId, Model, Status),
                    case classify_status(Status) of
                        #{action := retry} ->
                            execute_with_retry(SourceFormat, Model, Request, Opts,
                                               Stream, Retries - 1, MaxCreds, Tried + 1);
                        #{action := <<"quota-fallback">>} ->
                            model_registry:set_quota_exceeded(AuthId, Model),
                            case try_quota_fallback(SourceFormat, Model, Request, Opts, Stream) of
                                {ok, _} = Ok -> Ok;
                                {ok, stream, _} = Ok -> Ok;
                                _ -> {error, Status, Body}
                            end;
                        _ ->
                            {error, Status, Body}
                    end
            end
    end.

%%====================================================================
%% Internal - Execution dispatch
%%====================================================================

do_execute(Provider, AuthId, Request, Stream, Opts) ->
    case credential_proc:get_auth(AuthId) of
        {error, not_found} ->
            {error, 503, <<"credential not found">>};
        {ok, Auth} ->
            Mod = executor_module(Provider),
            case Stream of
                true ->
                    case Mod:execute_stream(AuthId, Auth, Request, Opts) of
                        {ok, Pid} -> {ok, stream, Pid};
                        {error, S, B} -> {error, S, B}
                    end;
                false ->
                    Mod:execute(AuthId, Auth, Request, Opts)
            end
    end.

executor_module(claude) -> claude_executor;
executor_module(openai_compat) -> openai_compat_executor;
executor_module(gemini) -> gemini_executor;
executor_module(codex) -> codex_executor;
executor_module(vertex) -> vertex_executor;
executor_module(aistudio) -> aistudio_executor;
executor_module(antigravity) -> antigravity_executor;
executor_module(kimi) -> kimi_executor;
executor_module(_) -> openai_compat_executor.

%%====================================================================
%% Internal - Helpers
%%====================================================================

mark_credential_result(AuthId, Model, StatusCode) ->
    case whereis(binary_to_atom(<<"cred_", AuthId/binary>>, utf8)) of
        undefined -> ok;
        _Pid -> credential_proc:mark_result(AuthId, Model, StatusCode)
    end.

get_provider(CredId) ->
    %% Query CLIPS for credential provider
    case clips_engine:query(credential, <<"id">>, CredId) of
        {ok, #{<<"provider">> := P}} -> binary_to_atom(P, utf8);
        _ -> claude  %% default fallback
    end.

generate_request_id() ->
    <<"req_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

classify_status(Status) ->
    case whereis(clips_engine) of
        undefined ->
            classify_status_fallback(Status);
        _ ->
            Id = generate_request_id(),
            _ = clips_engine:assert({status_input, #{
                id => Id,
                status_code => Status
            }}),
            _ = clips_engine:run(),
            Result = clips_engine:query(status_output, <<"id">>, Id),
            _ = clips_engine:retract({status_input, Id}),
            _ = clips_engine:retract({status_output, Id}),
            case Result of
                {ok, Map} -> Map;
                error -> classify_status_fallback(Status)
            end
    end.

classify_status_fallback(Status) when Status =:= 408;
                                       Status >= 500, Status =< 504 ->
    #{action => retry};
classify_status_fallback(429) ->
    #{action => <<"quota-fallback">>};
classify_status_fallback(_) ->
    #{action => pass}.

try_quota_fallback(SourceFormat, Model, Request, Opts, Stream) ->
    %% Chain: switch-preview-model → retry with different cred
    case config_loader:get(quota_switch_preview_model, false) of
        true ->
            PreviewModel = to_preview_model(Model),
            case PreviewModel =/= Model of
                true ->
                    MaxRetries = config_loader:get(request_retry, 3),
                    execute_with_retry(SourceFormat, PreviewModel,
                        Request#{<<"model">> => PreviewModel}, Opts,
                        Stream, MaxRetries, 0, 0);
                false -> {error, 429, <<"quota exceeded">>}
            end;
        false -> {error, 429, <<"quota exceeded">>}
    end.

to_preview_model(Model) ->
    %% Append -preview if not already present
    case binary:match(Model, <<"-preview">>) of
        nomatch -> <<Model/binary, "-preview">>;
        _ -> Model
    end.

bind_session(<<>>, _AuthId) -> ok;
bind_session(SessionId, AuthId) ->
    case whereis(clips_engine) of
        undefined -> ok;
        _ ->
            TTL = config_loader:get(session_affinity_ttl, 3600),
            Now = erlang:system_time(second),
            _ = clips_engine:assert({session_binding, #{
                session_id => SessionId,
                credential_id => AuthId,
                bound_at => Now,
                ttl => TTL
            }}),
            ok
    end.
