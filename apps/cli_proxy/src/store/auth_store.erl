-module(auth_store).

%% Behaviour definition for auth storage backends
%% Implementations: file_store, pg_store, git_store, s3_store

-callback load_all() -> {ok, [map()]} | {error, term()}.
-callback save(atom(), map()) -> ok | {error, term()}.
-callback update(binary(), map()) -> ok | {error, term()}.
-callback delete(binary()) -> ok | {error, term()}.
-callback load_config() -> {ok, map()} | {error, term()}.
-callback save_config(map()) -> ok | {error, term()}.

%% API using configured backend
-export([
    load_all/0,
    save/2,
    update/2,
    delete/1,
    load_config/0,
    save_config/1,
    get_backend/0
]).

%%====================================================================
%% API - delegates to configured backend
%%====================================================================

-spec load_all() -> {ok, [map()]} | {error, term()}.
load_all() ->
    Mod = get_backend(),
    Mod:load_all().

-spec save(atom(), map()) -> ok | {error, term()}.
save(Provider, TokenData) ->
    Mod = get_backend(),
    Mod:save(Provider, TokenData).

-spec update(binary(), map()) -> ok | {error, term()}.
update(Id, NewMetadata) ->
    Mod = get_backend(),
    Mod:update(Id, NewMetadata).

-spec delete(binary()) -> ok | {error, term()}.
delete(Id) ->
    Mod = get_backend(),
    Mod:delete(Id).

-spec load_config() -> {ok, map()} | {error, term()}.
load_config() ->
    Mod = get_backend(),
    Mod:load_config().

-spec save_config(map()) -> ok | {error, term()}.
save_config(Config) ->
    Mod = get_backend(),
    Mod:save_config(Config).

-spec get_backend() -> module().
get_backend() ->
    case config_loader:get(store_backend) of
        undefined -> file_store;
        Mod when is_atom(Mod) -> Mod;
        <<"file">> -> file_store;
        <<"pg">> -> pg_store;
        <<"git">> -> git_store;
        <<"s3">> -> s3_store;
        _ -> file_store
    end.
