-module(access_control).

%% API key + password validation
%% Used as middleware in HTTP handlers

-export([authenticate/1, validate_key/1, is_authenticated/1]).

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
            case Provided =:= Password of
                true -> ok;
                false ->
                    case Provided of
                        <<>> -> {error, password_required};
                        _ -> {error, invalid_password}
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
