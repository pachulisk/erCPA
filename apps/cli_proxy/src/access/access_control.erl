-module(access_control).

%% API key validation via ETS lookup
%% Used as middleware in HTTP handlers

-export([authenticate/1, validate_key/1, is_authenticated/1]).

-define(API_KEYS_TABLE, api_keys_tab).

%% Authenticate a Cowboy request
-spec authenticate(cowboy_req:req()) -> {ok, binary()} | {error, term()}.
authenticate(Req) ->
    Key = extract_key(Req),
    case Key of
        <<>> ->
            %% No key provided — check if any keys are configured
            case has_configured_keys() of
                false -> {ok, <<"anonymous">>};  %% No keys = allow all
                true -> {error, no_credentials}
            end;
        _ -> validate_key(Key)
    end.

%% Validate a key against the configured API keys
-spec validate_key(binary()) -> {ok, binary()} | {error, invalid_key}.
validate_key(Key) ->
    case ets:info(?API_KEYS_TABLE) of
        undefined ->
            %% Table doesn't exist yet - allow all (no keys configured)
            {ok, Key};
        _ ->
            case ets:info(?API_KEYS_TABLE, size) of
                0 ->
                    %% No keys configured - allow all
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

extract_key(Req) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> -> Token;
        <<"bearer ", Token/binary>> -> Token;
        <<>> ->
            %% Fallback to X-API-Key header
            cowboy_req:header(<<"x-api-key">>, Req, <<>>);
        _ ->
            <<>>
    end.

has_configured_keys() ->
    case ets:info(?API_KEYS_TABLE) of
        undefined -> false;
        _ -> ets:info(?API_KEYS_TABLE, size) > 0
    end.
