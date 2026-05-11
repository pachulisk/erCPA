-module(access_control).

%% API key + password validation
%% Used as middleware in HTTP handlers

-export([authenticate/1, validate_key/1, is_authenticated/1, hash_password/1]).

-define(API_KEYS_TABLE, api_keys_tab).

%% Authenticate a Cowboy request
-spec authenticate(cowboy_req:req()) -> {ok, binary()} | {error, term()}.
authenticate(Req) ->
    case check_password(Req) of
        {error, _} = Err -> Err;
        ok ->
            Key = extract_key(Req),
            case Key of
                <<>> ->
                    case has_configured_keys() of
                        false -> {ok, <<"anonymous">>};
                        true -> {error, no_credentials}
                    end;
                _ -> validate_key(Key)
            end
    end.

%% Validate a key against the configured API keys
-spec validate_key(binary()) -> {ok, binary()} | {error, invalid_key}.
validate_key(Key) ->
    case ets:info(?API_KEYS_TABLE) of
        undefined ->
            {ok, Key};
        _ ->
            case ets:info(?API_KEYS_TABLE, size) of
                0 ->
                    {ok, Key};
                _ ->
                    case ets:member(?API_KEYS_TABLE, Key) of
                        true -> {ok, Key};
                        false -> {error, invalid_key}
                    end
            end
    end.

%% Check if request has valid auth (for use in handler guards)
-spec is_authenticated(cowboy_req:req()) -> boolean().
is_authenticated(Req) ->
    case authenticate(Req) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%%====================================================================
%% Internal
%%====================================================================

check_password(Req) ->
    case config_loader:get(password) of
        undefined -> ok;
        <<>> -> ok;
        Password when is_binary(Password) ->
            Provided = extract_password(Req),
            case Provided of
                <<>> -> {error, password_required};
                _ ->
                    case verify_password(Provided, Password) of
                        true -> ok;
                        false -> {error, invalid_password}
                    end
            end;
        _ -> ok
    end.

extract_password(Req) ->
    %% Check X-Password header first
    case cowboy_req:header(<<"x-password">>, Req, <<>>) of
        <<>> ->
            %% Fallback to query param
            #{password := P} = cowboy_req:match_qs([{password, [], <<>>}], Req),
            P;
        P -> P
    end.

extract_key(Req) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> -> Token;
        <<"bearer ", Token/binary>> -> Token;
        <<>> ->
            cowboy_req:header(<<"x-api-key">>, Req, <<>>);
        _ ->
            <<>>
    end.

has_configured_keys() ->
    case ets:info(?API_KEYS_TABLE) of
        undefined -> false;
        _ -> ets:info(?API_KEYS_TABLE, size) > 0
    end.

%% Password verification — supports both plain and hashed passwords
%% Hashed format: "$pbkdf2$..." prefix
verify_password(Provided, <<"$pbkdf2$", _/binary>> = Hashed) ->
    %% PBKDF2 hashed password
    verify_pbkdf2(Provided, Hashed);
verify_password(Provided, Stored) ->
    %% Plain text — constant-time comparison
    constant_time_compare(Provided, Stored).

%% Hash a password for storage
-spec hash_password(binary()) -> binary().
hash_password(Password) ->
    Salt = crypto:strong_rand_bytes(16),
    Iterations = 10000,
    DK = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32),
    SaltB64 = base64:encode(Salt),
    DKB64 = base64:encode(DK),
    <<"$pbkdf2$sha256$", (integer_to_binary(Iterations))/binary,
      "$", SaltB64/binary, "$", DKB64/binary>>.

verify_pbkdf2(Password, <<"$pbkdf2$sha256$", Rest/binary>>) ->
    case binary:split(Rest, <<"$">>, [global]) of
        [IterBin, SaltB64, DKB64] ->
            Iterations = binary_to_integer(IterBin),
            Salt = base64:decode(SaltB64),
            StoredDK = base64:decode(DKB64),
            ComputedDK = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32),
            constant_time_compare(ComputedDK, StoredDK);
        _ -> false
    end;
verify_pbkdf2(_, _) -> false.

%% Constant-time binary comparison to prevent timing attacks
constant_time_compare(A, B) when is_binary(A), is_binary(B) ->
    case byte_size(A) =:= byte_size(B) of
        false -> false;
        true ->
            constant_time_compare(A, B, 0, 0)
    end.

constant_time_compare(<<>>, <<>>, _Idx, Acc) ->
    Acc =:= 0;
constant_time_compare(<<A, RestA/binary>>, <<B, RestB/binary>>, Idx, Acc) ->
    constant_time_compare(RestA, RestB, Idx + 1, Acc bor (A bxor B)).
