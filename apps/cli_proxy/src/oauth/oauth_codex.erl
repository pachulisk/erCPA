-module(oauth_codex).

%% Codex (OpenAI) OAuth implementation
%% Supports: PKCE Authorization Code + Device Code flow

-export([auth_url/2, exchange/3, refresh/1]).
-export([request_device_code/1, poll_device_token/2]).

-define(CLIENT_ID, <<"app_EMoamEEZ73f0CkXaXp7hrann">>).
-define(AUTH_URL, <<"https://auth.openai.com/oauth/authorize">>).
-define(TOKEN_URL, <<"https://auth.openai.com/oauth/token">>).
-define(DEVICE_CODE_URL, <<"https://auth.openai.com/api/accounts/deviceauth/usercode">>).
-define(DEVICE_TOKEN_URL, <<"https://auth.openai.com/api/accounts/deviceauth/token">>).
-define(CALLBACK_PORT, 1455).

-spec auth_url(binary(), binary()) -> binary().
auth_url(State, Verifier) ->
    Challenge = base64url_encode(crypto:hash(sha256, Verifier)),
    iolist_to_binary([
        ?AUTH_URL,
        <<"?client_id=">>, ?CLIENT_ID,
        <<"&redirect_uri=http://localhost:">>, integer_to_binary(?CALLBACK_PORT), <<"/auth/callback">>,
        <<"&response_type=code">>,
        <<"&scope=openid+email+profile+offline_access">>,
        <<"&code_challenge=">>, Challenge,
        <<"&code_challenge_method=S256">>,
        <<"&prompt=login">>,
        <<"&state=">>, State
    ]).

-spec exchange(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
exchange(Code, Verifier, _Config) ->
    Body = jiffy:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => ?CLIENT_ID,
        <<"code">> => Code,
        <<"code_verifier">> => Verifier,
        <<"redirect_uri">> => <<"http://localhost:", (integer_to_binary(?CALLBACK_PORT))/binary, "/auth/callback">>
    }),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(?TOKEN_URL, Headers, Body, [{recv_timeout, 30000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            TokenData = jiffy:decode(RespBody, [return_maps]),
            {ok, TokenData#{<<"type">> => <<"codex">>}};
        {ok, Status, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {error, {Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec refresh(map()) -> {ok, map()} | {error, term()}.
refresh(Metadata) ->
    RefreshToken = maps:get(<<"refresh_token">>, Metadata, <<>>),
    Body = jiffy:encode(#{
        <<"grant_type">> => <<"refresh_token">>,
        <<"client_id">> => ?CLIENT_ID,
        <<"refresh_token">> => RefreshToken
    }),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(?TOKEN_URL, Headers, Body, [{recv_timeout, 30000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            NewTokens = jiffy:decode(RespBody, [return_maps]),
            {ok, maps:merge(Metadata, NewTokens)};
        {ok, Status, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {error, {Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

%% --- Device Code Flow ---

-spec request_device_code(map()) -> {ok, binary(), binary(), binary()} | {error, term()}.
request_device_code(_Config) ->
    Body = jiffy:encode(#{<<"client_id">> => ?CLIENT_ID}),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(?DEVICE_CODE_URL, Headers, Body, [{recv_timeout, 10000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            Data = jiffy:decode(RespBody, [return_maps]),
            DeviceCode = maps:get(<<"device_code">>, Data, <<>>),
            UserCode = maps:get(<<"user_code">>, Data, <<>>),
            VerifyURL = maps:get(<<"verification_uri">>, Data,
                <<"https://auth.openai.com/codex/device">>),
            {ok, DeviceCode, UserCode, VerifyURL};
        {ok, Status, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {error, {Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec poll_device_token(binary(), map()) -> {ok, map()} | {error, atom()}.
poll_device_token(DeviceCode, _Config) ->
    Body = jiffy:encode(#{
        <<"client_id">> => ?CLIENT_ID,
        <<"device_code">> => DeviceCode,
        <<"grant_type">> => <<"urn:ietf:params:oauth:grant-type:device_code">>
    }),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(?DEVICE_TOKEN_URL, Headers, Body, [{recv_timeout, 10000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            TokenData = jiffy:decode(RespBody, [return_maps]),
            {ok, TokenData#{<<"type">> => <<"codex">>}};
        {ok, 400, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            Data = jiffy:decode(RespBody, [return_maps]),
            case maps:get(<<"error">>, Data, <<>>) of
                <<"authorization_pending">> -> {error, authorization_pending};
                <<"slow_down">> -> {error, slow_down};
                <<"expired_token">> -> {error, expired_token};
                Other -> {error, {unknown_error, Other}}
            end;
        {ok, Status, _, Ref} ->
            {ok, _} = hackney:body(Ref),
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

base64url_encode(Bin) ->
    B64 = base64:encode(Bin),
    B1 = binary:replace(B64, <<"+">>, <<"-">>, [global]),
    B2 = binary:replace(B1, <<"/">>, <<"_">>, [global]),
    binary:replace(B2, <<"=">>, <<>>, [global]).
