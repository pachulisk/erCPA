-module(vertex_import).

%% Vertex AI service account import
%% Reads a JSON key file and stores as auth credential

-export([import/1, import/2]).

-spec import(binary() | string()) -> ok | {error, term()}.
import(FilePath) ->
    import(FilePath, <<>>).

-spec import(binary() | string(), binary()) -> ok | {error, term()}.
import(FilePath, Prefix) ->
    Path = if is_binary(FilePath) -> binary_to_list(FilePath); true -> FilePath end,
    case file:read_file(Path) of
        {ok, Bin} ->
            case jiffy:decode(Bin, [return_maps]) of
                #{<<"project_id">> := ProjectId, <<"client_email">> := Email} = SA ->
                    TokenData = #{
                        <<"type">> => <<"vertex">>,
                        <<"service_account">> => SA,
                        <<"project_id">> => ProjectId,
                        <<"email">> => Email,
                        <<"prefix">> => Prefix
                    },
                    auth_store:save(vertex, TokenData);
                _ ->
                    {error, invalid_service_account}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
