-module(oauth_kimi).

%% Kimi (Moonshot AI) OAuth implementation
%% RFC 8628 Device Authorization Grant

-export([request_device_code/1, poll_device_token/2, refresh/1]).

-define(CLIENT_ID, <<"17e5f671-d194-4dfb-9706-5516cb48c098">>).
-define(DEVICE_CODE_URL, <<"https://auth.kimi.com/api/oauth/device_authorization">>).
-define(TOKEN_URL, <<"https://auth.kimi.com/api/oauth/token">>).

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
                <<"https://auth.kimi.com/device">>),
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
    case hackney:post(?TOKEN_URL, Headers, Body, [{recv_timeout, 10000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            TokenData = jiffy:decode(RespBody, [return_maps]),
            {ok, TokenData#{<<"type">> => <<"kimi">>}};
        {ok, 400, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            Data = jiffy:decode(RespBody, [return_maps]),
            case maps:get(<<"error">>, Data, <<>>) of
                <<"authorization_pending">> -> {error, authorization_pending};
                <<"slow_down">> -> {error, slow_down};
                <<"expired_token">> -> {error, expired_token};
                _ -> {error, unknown}
            end;
        {ok, Status, _, Ref} ->
            {ok, _} = hackney:body(Ref),
            {error, {http_error, Status}};
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
