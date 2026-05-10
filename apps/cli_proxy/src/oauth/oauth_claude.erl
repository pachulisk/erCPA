-module(oauth_claude).

%% Claude (Anthropic) OAuth implementation
%% PKCE Authorization Code flow

-export([auth_url/2, exchange/3, refresh/1]).

-define(CLIENT_ID, <<"9d1c250a-e61b-44d9-88ed-5944d1962f5e">>).
-define(TOKEN_URL, <<"https://api.anthropic.com/v1/oauth/token">>).
-define(CALLBACK_PORT, 54545).

-spec auth_url(binary(), binary()) -> binary().
auth_url(State, Verifier) ->
    Challenge = base64url_encode(crypto:hash(sha256, Verifier)),
    iolist_to_binary([
        <<"https://claude.ai/oauth/authorize">>,
        <<"?client_id=">>, ?CLIENT_ID,
        <<"&redirect_uri=http://localhost:">>, integer_to_binary(?CALLBACK_PORT), <<"/callback">>,
        <<"&response_type=code">>,
        <<"&code_challenge=">>, Challenge,
        <<"&code_challenge_method=S256">>,
        <<"&state=">>, State
    ]).

-spec exchange(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
exchange(Code, Verifier, _Config) ->
    Body = jiffy:encode(#{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => ?CLIENT_ID,
        <<"code">> => Code,
        <<"code_verifier">> => Verifier,
        <<"redirect_uri">> => <<"http://localhost:", (integer_to_binary(?CALLBACK_PORT))/binary, "/callback">>
    }),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(?TOKEN_URL, Headers, Body, [{recv_timeout, 30000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            TokenData = jiffy:decode(RespBody, [return_maps]),
            {ok, TokenData#{<<"type">> => <<"claude">>}};
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

base64url_encode(Bin) ->
    B64 = base64:encode(Bin),
    B1 = binary:replace(B64, <<"+">>, <<"-">>, [global]),
    B2 = binary:replace(B1, <<"/">>, <<"_">>, [global]),
    binary:replace(B2, <<"=">>, <<>>, [global]).
