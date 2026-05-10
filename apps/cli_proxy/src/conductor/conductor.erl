-module(conductor).
-behaviour(gen_server).

%% Request orchestration: credential selection + translation + execution + retry
%% Integrates with CLIPS for selection and credential_proc for state management

-export([
    start_link/0,
    execute/3,
    execute/4,
    select_credential/2,
    select_credential/3
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
-spec select_credential(binary(), map()) -> {ok, binary(), atom()} | {error, term()}.
select_credential(Model, Opts) ->
    select_credential(Model, Opts, <<>>).

-spec select_credential(binary(), map(), binary()) -> {ok, binary(), atom()} | {error, term()}.
select_credential(Model, _Opts, SessionId) ->
    %% Use CLIPS for selection
    RequestId = generate_request_id(),
    Now = erlang:system_time(second),
    NeedWS = false,  %% TODO: derive from opts

    clips_engine:assert({select_request, #{
        id => RequestId,
        model => Model,
        session_id => SessionId,
        need_websocket => case NeedWS of true -> yes; false -> no end,
        now => Now
    }}),
    clips_engine:run(),

    Result = clips_engine:query(selection_result, <<"request-id">>, RequestId),

    %% Clean up transient facts
    clips_engine:retract({select_request, RequestId}),

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

handle_call({execute, SourceFormat, Model, Request, Opts}, _From, State) ->
    MaxRetries = config_loader:get(request_retry, 3),
    MaxCreds = config_loader:get(max_retry_credentials, 0),
    Stream = maps:get(<<"stream">>, Request, false),

    Result = execute_with_retry(SourceFormat, Model, Request, Opts,
                                Stream, MaxRetries, MaxCreds, 0),
    {reply, Result, State};

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
                    %% Mark success
                    mark_credential_result(AuthId, Model, 200),
                    %% Translate response back to source format
                    TranslatedResp = translator_registry:translate_nonstream(
                        Provider, SourceFormat, Response),
                    {ok, TranslatedResp};
                {ok, stream, StreamPid} ->
                    mark_credential_result(AuthId, Model, 200),
                    {ok, stream, StreamPid};
                {error, Status, Body} when Status =:= 408;
                                           Status =:= 500;
                                           Status =:= 502;
                                           Status =:= 503;
                                           Status =:= 504 ->
                    %% Retriable — mark failure, retry
                    mark_credential_result(AuthId, Model, Status),
                    execute_with_retry(SourceFormat, Model, Request, Opts,
                                       Stream, Retries - 1, MaxCreds, Tried + 1);
                {error, Status, Body} ->
                    %% Non-retriable
                    mark_credential_result(AuthId, Model, Status),
                    {error, Status, Body}
            end
    end.

%%====================================================================
%% Internal - Execution dispatch
%%====================================================================

do_execute(_Provider, _AuthId, _Request, _Stream, _Opts) ->
    %% TODO: Dispatch to provider executor gen_server
    %% For now return a placeholder
    {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                               <<"text">> => <<"[conductor: executor not yet wired]">>}],
           <<"stop_reason">> => <<"end_turn">>,
           <<"usage">> => #{<<"input_tokens">> => 0, <<"output_tokens">> => 0}}}.

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
