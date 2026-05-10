-module(oauth_antigravity).

%% Antigravity OAuth implementation

-export([auth_url/2, exchange/3, refresh/1]).

-spec auth_url(binary(), binary()) -> binary().
auth_url(State, _Verifier) ->
    ClientId = get_env("ANTIGRAVITY_CLIENT_ID", <<"configure-in-env">>),
    AuthEndpoint = get_env("ANTIGRAVITY_AUTH_URL", <<"https://accounts.google.com/o/oauth2/v2/auth">>),
    iolist_to_binary([
        AuthEndpoint,
        <<"?client_id=">>, ClientId,
        <<"&redirect_uri=http://localhost:8085/antigravity/callback">>,
        <<"&response_type=code">>,
        <<"&access_type=offline">>,
        <<"&prompt=consent">>,
        <<"&state=">>, State
    ]).

-spec exchange(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
exchange(Code, _Verifier, _Config) ->
    ClientId = get_env("ANTIGRAVITY_CLIENT_ID", <<>>),
    ClientSecret = get_env("ANTIGRAVITY_CLIENT_SECRET", <<>>),
    TokenURL = get_env("ANTIGRAVITY_TOKEN_URL", <<"https://oauth2.googleapis.com/token">>),
    Body = iolist_to_binary([
        <<"grant_type=authorization_code">>,
        <<"&client_id=">>, ClientId,
        <<"&client_secret=">>, ClientSecret,
        <<"&code=">>, Code,
        <<"&redirect_uri=http://localhost:8085/antigravity/callback">>
    ]),
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    case hackney:post(TokenURL, Headers, Body, [{recv_timeout, 30000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            TokenData = jiffy:decode(RespBody, [return_maps]),
            {ok, TokenData#{<<"type">> => <<"antigravity">>}};
        {ok, Status, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {error, {Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec refresh(map()) -> {ok, map()} | {error, term()}.
refresh(Metadata) ->
    ClientId = get_env("ANTIGRAVITY_CLIENT_ID", <<>>),
    ClientSecret = get_env("ANTIGRAVITY_CLIENT_SECRET", <<>>),
    TokenURL = get_env("ANTIGRAVITY_TOKEN_URL", <<"https://oauth2.googleapis.com/token">>),
    RefreshToken = maps:get(<<"refresh_token">>, Metadata, <<>>),
    Body = iolist_to_binary([
        <<"grant_type=refresh_token">>,
        <<"&client_id=">>, ClientId,
        <<"&client_secret=">>, ClientSecret,
        <<"&refresh_token=">>, RefreshToken
    ]),
    Headers = [{<<"Content-Type">>, <<"application/x-www-form-urlencoded">>}],
    case hackney:post(TokenURL, Headers, Body, [{recv_timeout, 30000}]) of
        {ok, 200, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {ok, maps:merge(Metadata, jiffy:decode(RespBody, [return_maps]))};
        {ok, Status, _, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            {error, {Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

get_env(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        Val -> list_to_binary(Val)
    end.
