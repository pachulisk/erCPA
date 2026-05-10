-module(oauth_gemini).

%% Gemini (Google) OAuth implementation
%% Standard OAuth2 Authorization Code flow
%% Client credentials loaded from environment variables

-export([auth_url/2, exchange/3, refresh/1]).

-define(TOKEN_URL, <<"https://oauth2.googleapis.com/token">>).
-define(CALLBACK_PORT, 8085).

-spec auth_url(binary(), binary()) -> binary().
auth_url(State, _Verifier) ->
    ClientId = get_client_id(),
    iolist_to_binary([
        <<"https://accounts.google.com/o/oauth2/v2/auth">>,
        <<"?client_id=">>, ClientId,
        <<"&redirect_uri=http://localhost:">>, integer_to_binary(?CALLBACK_PORT), <<"/callback">>,
        <<"&response_type=code">>,
        <<"&scope=https://www.googleapis.com/auth/cloud-platform+https://www.googleapis.com/auth/userinfo.email+https://www.googleapis.com/auth/userinfo.profile">>,
        <<"&access_type=offline">>,
        <<"&prompt=consent">>,
        <<"&state=">>, State
    ]).

-spec exchange(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
exchange(Code, _Verifier, Config) ->
    ClientId = get_client_id(),
    ClientSecret = get_client_secret(),
    RedirectURI = maps:get(redirect_uri, Config,
        <<"http://localhost:", (integer_to_binary(?CALLBACK_PORT))/binary, "/callback">>),
    Body = iolist_to_binary([
        <<"grant_type=authorization_code">>,
        <<"&client_id=">>, ClientId,
        <<"&client_secret=">>, ClientSecret,
        <<"&code=">>, Code,
        <<"&redirect_uri=">>, RedirectURI
    ]),
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    case hackney:post(?TOKEN_URL, Headers, Body, [{recv_timeout, 30000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            TokenData = jiffy:decode(RespBody, [return_maps]),
            {ok, TokenData#{<<"type">> => <<"gemini">>}};
        {ok, Status, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {error, {Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec refresh(map()) -> {ok, map()} | {error, term()}.
refresh(Metadata) ->
    ClientId = get_client_id(),
    ClientSecret = get_client_secret(),
    RefreshToken = maps:get(<<"refresh_token">>, Metadata, <<>>),
    Body = iolist_to_binary([
        <<"grant_type=refresh_token">>,
        <<"&client_id=">>, ClientId,
        <<"&client_secret=">>, ClientSecret,
        <<"&refresh_token=">>, RefreshToken
    ]),
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
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

%%====================================================================
%% Internal - credentials from environment
%%====================================================================

get_client_id() ->
    get_env("GEMINI_OAUTH_CLIENT_ID", <<"configure-gemini-client-id">>).

get_client_secret() ->
    get_env("GEMINI_OAUTH_CLIENT_SECRET", <<"configure-gemini-client-secret">>).

get_env(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        Val -> list_to_binary(Val)
    end.
