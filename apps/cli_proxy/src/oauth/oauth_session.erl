-module(oauth_session).
-behaviour(gen_statem).

%% OAuth login session state machine
%% States: idle → awaiting_callback | awaiting_device_poll → exchanging → persisting → done | failed

-export([
    start_link/2,
    get_state/1,
    notify_callback/3
]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3]).
-export([idle/3, awaiting_callback/3, awaiting_device_poll/3,
         exchanging/3, persisting/3, done/3, failed/3]).

-record(data, {
    provider    :: atom(),
    config      :: map(),
    state_token :: binary(),
    code_verifier :: binary(),
    caller      :: pid(),
    auth_url    :: binary(),
    device_code :: binary() | undefined,
    result      :: map() | undefined
}).

%%====================================================================
%% API
%%====================================================================

start_link(Provider, Config) ->
    gen_statem:start_link(?MODULE, [Provider, Config, self()], []).

-spec get_state(pid()) -> atom().
get_state(Pid) ->
    gen_statem:call(Pid, get_state).

-spec notify_callback(pid(), binary(), binary()) -> ok.
notify_callback(Pid, StateToken, Code) ->
    gen_statem:cast(Pid, {oauth_callback, StateToken, Code}).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() -> [state_functions, state_enter].

init([Provider, Config, Caller]) ->
    Data = #data{
        provider = Provider,
        config = Config,
        state_token = generate_state_token(),
        code_verifier = generate_code_verifier(),
        caller = Caller,
        auth_url = <<>>,
        device_code = undefined
    },
    {ok, idle, Data}.

%%====================================================================
%% State: idle — build auth URL, open browser
%%====================================================================

idle(enter, _OldState, Data) ->
    Provider = Data#data.provider,
    Config = Data#data.config,
    StateToken = Data#data.state_token,
    Verifier = Data#data.code_verifier,

    case Provider of
        P when P =:= codex_device; P =:= kimi ->
            %% Device flow — no browser, get device code
            case request_device_code(Provider, Config) of
                {ok, DeviceCode, UserCode, VerificationURL} ->
                    Data#data.caller ! {oauth_device_code, self(), UserCode, VerificationURL},
                    {next_state, awaiting_device_poll,
                     Data#data{device_code = DeviceCode},
                     [{state_timeout, 300000, login_timeout}]};
                {error, Reason} ->
                    Data#data.caller ! {oauth_error, self(), Reason},
                    {next_state, failed, Data}
            end;
        _ ->
            %% Authorization code flow
            AuthURL = build_auth_url(Provider, Config, StateToken, Verifier),
            Data#data.caller ! {oauth_url, self(), AuthURL},
            maybe_open_browser(AuthURL, Config),
            {keep_state, Data#data{auth_url = AuthURL},
             [{state_timeout, 300000, login_timeout}]}
    end;

idle(state_timeout, login_timeout, Data) ->
    Data#data.caller ! {oauth_error, self(), timeout},
    {next_state, failed, Data};

idle(cast, {oauth_callback, StateToken, Code}, #data{state_token = StateToken} = Data) ->
    {next_state, exchanging, Data#data{result = #{code => Code}}};

idle(cast, {oauth_callback, _WrongToken, _Code}, Data) ->
    %% Invalid state token — ignore
    {keep_state, Data};

idle({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, idle}]};

idle(_EventType, _Event, _Data) ->
    keep_state_and_data.

%%====================================================================
%% State: awaiting_callback (authorization code flow)
%%====================================================================

awaiting_callback(enter, _OldState, _Data) ->
    keep_state_and_data;

awaiting_callback(cast, {oauth_callback, StateToken, Code},
                  #data{state_token = StateToken} = Data) ->
    {next_state, exchanging, Data#data{result = #{code => Code}}};

awaiting_callback(state_timeout, login_timeout, Data) ->
    Data#data.caller ! {oauth_error, self(), timeout},
    {next_state, failed, Data};

awaiting_callback({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, awaiting_callback}]};

awaiting_callback(_EventType, _Event, _Data) ->
    keep_state_and_data.

%%====================================================================
%% State: awaiting_device_poll (device code flow)
%%====================================================================

awaiting_device_poll(enter, _OldState, _Data) ->
    {keep_state_and_data, [{state_timeout, 5000, poll}]};

awaiting_device_poll(state_timeout, poll, Data) ->
    case poll_device_token(Data#data.provider, Data#data.device_code, Data#data.config) of
        {ok, TokenData} ->
            {next_state, persisting, Data#data{result = TokenData}};
        {error, authorization_pending} ->
            {keep_state, Data, [{state_timeout, 5000, poll}]};
        {error, slow_down} ->
            {keep_state, Data, [{state_timeout, 10000, poll}]};
        {error, expired_token} ->
            Data#data.caller ! {oauth_error, self(), expired},
            {next_state, failed, Data};
        {error, _Reason} ->
            Data#data.caller ! {oauth_error, self(), poll_failed},
            {next_state, failed, Data}
    end;

awaiting_device_poll(state_timeout, login_timeout, Data) ->
    Data#data.caller ! {oauth_error, self(), timeout},
    {next_state, failed, Data};

awaiting_device_poll({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, awaiting_device_poll}]};

awaiting_device_poll(_EventType, _Event, _Data) ->
    keep_state_and_data.

%%====================================================================
%% State: exchanging (code → tokens)
%%====================================================================

exchanging(enter, _OldState, Data) ->
    #{code := Code} = Data#data.result,
    case exchange_code(Data#data.provider, Code,
                       Data#data.code_verifier, Data#data.config) of
        {ok, TokenData} ->
            {next_state, persisting, Data#data{result = TokenData}};
        {error, Reason} ->
            Data#data.caller ! {oauth_error, self(), Reason},
            {next_state, failed, Data}
    end;

exchanging({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, exchanging}]};

exchanging(_EventType, _Event, _Data) ->
    keep_state_and_data.

%%====================================================================
%% State: persisting (save token)
%%====================================================================

persisting(enter, _OldState, Data) ->
    TokenData = Data#data.result,
    case auth_store:save(Data#data.provider, TokenData) of
        ok ->
            Data#data.caller ! {oauth_complete, self(), ok},
            {next_state, done, Data};
        {error, Reason} ->
            Data#data.caller ! {oauth_error, self(), Reason},
            {next_state, failed, Data}
    end;

persisting({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, persisting}]};

persisting(_EventType, _Event, _Data) ->
    keep_state_and_data.

%%====================================================================
%% State: done / failed (terminal)
%%====================================================================

done(enter, _OldState, _Data) ->
    {keep_state_and_data, [{state_timeout, 5000, cleanup}]};
done(state_timeout, cleanup, _Data) ->
    {stop, normal};
done({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, done}]};
done(_EventType, _Event, _Data) ->
    keep_state_and_data.

failed(enter, _OldState, _Data) ->
    {keep_state_and_data, [{state_timeout, 5000, cleanup}]};
failed(state_timeout, cleanup, _Data) ->
    {stop, normal};
failed({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, failed}]};
failed(_EventType, _Event, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

%%====================================================================
%% Internal — Provider-specific (stubs, will be filled by oauth_* modules)
%%====================================================================

build_auth_url(claude, _Config, State, Verifier) ->
    Challenge = base64url_encode(crypto:hash(sha256, Verifier)),
    iolist_to_binary([
        <<"https://claude.ai/oauth/authorize">>,
        <<"?client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e">>,
        <<"&redirect_uri=http://localhost:54545/callback">>,
        <<"&response_type=code">>,
        <<"&code_challenge=">>, Challenge,
        <<"&code_challenge_method=S256">>,
        <<"&state=">>, State
    ]);
build_auth_url(codex, _Config, State, Verifier) ->
    Challenge = base64url_encode(crypto:hash(sha256, Verifier)),
    iolist_to_binary([
        <<"https://auth.openai.com/oauth/authorize">>,
        <<"?client_id=app_EMoamEEZ73f0CkXaXp7hrann">>,
        <<"&redirect_uri=http://localhost:1455/auth/callback">>,
        <<"&response_type=code">>,
        <<"&scope=openid+email+profile+offline_access">>,
        <<"&code_challenge=">>, Challenge,
        <<"&code_challenge_method=S256">>,
        <<"&state=">>, State
    ]);
build_auth_url(gemini, _Config, State, _Verifier) ->
    iolist_to_binary([
        <<"https://accounts.google.com/o/oauth2/v2/auth">>,
        <<"?client_id=681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com">>,
        <<"&redirect_uri=http://localhost:8085/callback">>,
        <<"&response_type=code">>,
        <<"&scope=https://www.googleapis.com/auth/cloud-platform+https://www.googleapis.com/auth/userinfo.email">>,
        <<"&access_type=offline">>,
        <<"&state=">>, State
    ]);
build_auth_url(_Provider, _Config, State, _Verifier) ->
    <<"https://example.com/oauth?state=", State/binary>>.

exchange_code(_Provider, _Code, _Verifier, _Config) ->
    %% TODO: Implement per-provider token exchange
    {error, not_implemented}.

request_device_code(_Provider, _Config) ->
    %% TODO: Implement device code request
    {error, not_implemented}.

poll_device_token(_Provider, _DeviceCode, _Config) ->
    %% TODO: Implement device token polling
    {error, not_implemented}.

maybe_open_browser(URL, Config) ->
    case maps:get(no_browser, Config, false) of
        true -> ok;
        false ->
            %% Try to open browser
            case os:type() of
                {unix, darwin} -> os:cmd("open " ++ binary_to_list(URL));
                {unix, _} -> os:cmd("xdg-open " ++ binary_to_list(URL));
                _ -> ok
            end
    end.

generate_state_token() ->
    base64url_encode(crypto:strong_rand_bytes(32)).

generate_code_verifier() ->
    base64url_encode(crypto:strong_rand_bytes(96)).

base64url_encode(Bin) ->
    B64 = base64:encode(Bin),
    %% Convert to URL-safe: + → -, / → _, strip =
    B1 = binary:replace(B64, <<"+">>, <<"-">>, [global]),
    B2 = binary:replace(B1, <<"/">>, <<"_">>, [global]),
    binary:replace(B2, <<"=">>, <<>>, [global]).
