-module(pg_store).
-behaviour(auth_store).

%% PostgreSQL-backed auth storage
%% Requires: {pg_dsn, "postgres://user:pass@host/db"} in config

-export([load_all/0, save/2, update/2, delete/1, load_config/0, save_config/1]).

load_all() ->
    case get_conn() of
        {ok, Conn} ->
            case epgsql:equery(Conn, "SELECT id, provider, metadata, disabled FROM auth_credentials", []) of
                {ok, _Cols, Rows} ->
                    Creds = [#{
                        id => Id,
                        provider => binary_to_atom(Provider, utf8),
                        metadata => jiffy:decode(Meta, [return_maps]),
                        disabled => Disabled
                    } || {Id, Provider, Meta, Disabled} <- Rows],
                    {ok, Creds};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

save(Provider, TokenData) ->
    case get_conn() of
        {ok, Conn} ->
            Id = maps:get(<<"id">>, TokenData, generate_id(Provider)),
            Meta = jiffy:encode(TokenData),
            ProvBin = atom_to_binary(Provider, utf8),
            epgsql:equery(Conn,
                "INSERT INTO auth_credentials (id, provider, metadata, disabled) "
                "VALUES ($1, $2, $3, false) "
                "ON CONFLICT (id) DO UPDATE SET metadata = $3",
                [Id, ProvBin, Meta]),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

update(Id, NewMetadata) ->
    case get_conn() of
        {ok, Conn} ->
            Meta = jiffy:encode(NewMetadata),
            case epgsql:equery(Conn,
                "UPDATE auth_credentials SET metadata = metadata || $2 WHERE id = $1",
                [Id, Meta]) of
                {ok, _} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

delete(Id) ->
    case get_conn() of
        {ok, Conn} ->
            epgsql:equery(Conn, "DELETE FROM auth_credentials WHERE id = $1", [Id]),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

load_config() ->
    case get_conn() of
        {ok, Conn} ->
            case epgsql:equery(Conn, "SELECT key, value FROM proxy_config", []) of
                {ok, _Cols, Rows} ->
                    Config = maps:from_list([{K, jiffy:decode(V)} || {K, V} <- Rows]),
                    {ok, Config};
                {error, _} ->
                    {ok, #{}}
            end;
        {error, _} ->
            {ok, #{}}
    end.

save_config(Config) ->
    case get_conn() of
        {ok, Conn} ->
            maps:foreach(fun(K, V) ->
                epgsql:equery(Conn,
                    "INSERT INTO proxy_config (key, value) VALUES ($1, $2) "
                    "ON CONFLICT (key) DO UPDATE SET value = $2",
                    [K, jiffy:encode(V)])
            end, Config),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Internal
%%====================================================================

get_conn() ->
    case config_loader:get(pg_dsn) of
        undefined -> {error, pg_dsn_not_configured};
        DSN -> epgsql:connect(binary_to_list(DSN))
    end.

generate_id(Provider) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<(atom_to_binary(Provider, utf8))/binary, "-", Suffix/binary>>.
