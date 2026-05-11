-module(s3_store).
-behaviour(auth_store).

%% S3-compatible object storage backend (MinIO, AWS S3, etc.)
%% Config: {s3_bucket, "..."}, {s3_endpoint, "..."}, {s3_key, "..."}, {s3_secret, "..."}
%% Uses hackney for HTTP requests with AWS Signature V4

-export([load_all/0, save/2, update/2, delete/1, load_config/0, save_config/1]).

load_all() ->
    case list_objects("credentials/") of
        {ok, Keys} ->
            Creds = lists:filtermap(fun(Key) ->
                case get_object(Key) of
                    {ok, Bin} ->
                        try
                            Data = jiffy:decode(Bin, [return_maps]),
                            Id = maps:get(<<"id">>, Data,
                                list_to_binary(filename:basename(Key, ".json"))),
                            Provider = binary_to_atom(maps:get(<<"type">>, Data, <<"unknown">>), utf8),
                            {true, #{id => Id, provider => Provider,
                                     metadata => Data,
                                     disabled => maps:get(<<"disabled">>, Data, false)}}
                        catch _:_ -> false
                        end;
                    _ -> false
                end
            end, Keys),
            {ok, Creds};
        {error, Reason} ->
            {error, Reason}
    end.

save(Provider, TokenData) ->
    Id = maps:get(<<"id">>, TokenData, generate_id(Provider)),
    Key = <<"credentials/", (atom_to_binary(Provider, utf8))/binary, "-", Id/binary, ".json">>,
    Data = TokenData#{<<"type">> => atom_to_binary(Provider, utf8)},
    put_object(Key, jiffy:encode(Data, [pretty])).

update(Id, NewMetadata) ->
    case find_object(Id) of
        {ok, Key, Existing} ->
            Updated = maps:merge(Existing, NewMetadata),
            put_object(Key, jiffy:encode(Updated, [pretty]));
        error ->
            {error, not_found}
    end.

delete(Id) ->
    case find_object(Id) of
        {ok, Key, _} -> delete_object(Key);
        error -> {error, not_found}
    end.

load_config() ->
    case get_object(<<"config.json">>) of
        {ok, Bin} -> {ok, jiffy:decode(Bin, [return_maps])};
        {error, 404} -> {ok, #{}};
        {error, Reason} -> {error, Reason}
    end.

save_config(Config) ->
    put_object(<<"config.json">>, jiffy:encode(Config, [pretty])).

%%====================================================================
%% Internal — S3 HTTP operations (simplified, no SigV4 yet)
%%====================================================================

get_object(Key) ->
    URL = object_url(Key),
    Headers = auth_headers(<<"GET">>, Key),
    case hackney:get(URL, Headers, <<>>, [{recv_timeout, 10000}]) of
        {ok, 200, _, Ref} ->
            {ok, Body} = hackney:body(Ref),
            {ok, Body};
        {ok, 404, _, _} ->
            {error, 404};
        {ok, Status, _, _} ->
            {error, {s3_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

put_object(Key, Body) ->
    URL = object_url(Key),
    Headers = [{<<"Content-Type">>, <<"application/json">>} | auth_headers(<<"PUT">>, Key)],
    case hackney:put(URL, Headers, Body, [{recv_timeout, 10000}]) of
        {ok, Status, _, _} when Status >= 200, Status < 300 -> ok;
        {ok, Status, _, _} -> {error, {s3_error, Status}};
        {error, Reason} -> {error, Reason}
    end.

delete_object(Key) ->
    URL = object_url(Key),
    Headers = auth_headers(<<"DELETE">>, Key),
    case hackney:delete(URL, Headers, <<>>, [{recv_timeout, 10000}]) of
        {ok, Status, _, _} when Status >= 200, Status < 300 -> ok;
        {ok, Status, _, _} -> {error, {s3_error, Status}};
        {error, Reason} -> {error, Reason}
    end.

list_objects(Prefix) ->
    Endpoint = config_loader:get(s3_endpoint, <<"http://localhost:9000">>),
    Bucket = config_loader:get(s3_bucket, <<"ercpa">>),
    URL = <<Endpoint/binary, "/", Bucket/binary, "?prefix=", (iolist_to_binary(Prefix))/binary>>,
    Headers = auth_headers(<<"GET">>, <<>>),
    case hackney:get(URL, Headers, <<>>, [{recv_timeout, 10000}]) of
        {ok, 200, _, Ref} ->
            {ok, Body} = hackney:body(Ref),
            Keys = parse_list_response(Body),
            {ok, Keys};
        {ok, Status, _, _} ->
            {error, {s3_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

find_object(Id) ->
    case list_objects("credentials/") of
        {ok, Keys} ->
            case lists:filter(fun(K) ->
                binary:match(K, Id) =/= nomatch
            end, Keys) of
                [Key | _] ->
                    case get_object(Key) of
                        {ok, Bin} -> {ok, Key, jiffy:decode(Bin, [return_maps])};
                        _ -> error
                    end;
                [] -> error
            end;
        _ -> error
    end.

object_url(Key) ->
    Endpoint = config_loader:get(s3_endpoint, <<"http://localhost:9000">>),
    Bucket = config_loader:get(s3_bucket, <<"ercpa">>),
    <<Endpoint/binary, "/", Bucket/binary, "/", Key/binary>>.

auth_headers(_Method, _Key) ->
    %% Basic auth with access key
    AccessKey = config_loader:get(s3_key, <<>>),
    SecretKey = config_loader:get(s3_secret, <<>>),
    case AccessKey of
        <<>> -> [];
        _ ->
            Auth = base64:encode(<<AccessKey/binary, ":", SecretKey/binary>>),
            [{<<"Authorization">>, <<"Basic ", Auth/binary>>}]
    end.

parse_list_response(XML) ->
    %% Simple XML key extraction from S3 ListObjects response
    case re:run(XML, <<"<Key>([^<]+)</Key>">>, [global, {capture, [1], binary}]) of
        {match, Matches} -> [K || [K] <- Matches];
        nomatch -> []
    end.

generate_id(Provider) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<(atom_to_binary(Provider, utf8))/binary, "-", Suffix/binary>>.
