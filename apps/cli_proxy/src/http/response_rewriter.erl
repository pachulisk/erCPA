-module(response_rewriter).

%% Response rewriting — model name, tool name normalization, signature injection
%% Uses CLIPS rules for tool name mappings (hot-configurable)

-export([rewrite/2, rewrite_stream_chunk/2]).

-spec rewrite(map(), map()) -> map().
rewrite(Response, Opts) ->
    R1 = rewrite_model(Response, Opts),
    R2 = rewrite_tool_names(R1),
    R3 = inject_signatures(R2),
    R3.

-spec rewrite_stream_chunk(binary(), map()) -> binary().
rewrite_stream_chunk(Chunk, Opts) ->
    try
        Map = jiffy:decode(Chunk, [return_maps]),
        case is_map(Map) of
            true -> jiffy:encode(rewrite(Map, Opts));
            false -> Chunk
        end
    catch _:_ -> Chunk
    end.

%%====================================================================
%% Internal
%%====================================================================

rewrite_model(Response, #{original_model := OrigModel}) ->
    replace_in_paths(Response, [<<"model">>, <<"message.model">>], OrigModel);
rewrite_model(Response, _) ->
    Response.

rewrite_tool_names(#{<<"content">> := Content} = Response) when is_list(Content) ->
    Rewrites = get_tool_rewrites(),
    NewContent = [rewrite_block_tool_name(Block, Rewrites) || Block <- Content],
    Response#{<<"content">> => NewContent};
rewrite_tool_names(Response) ->
    Response.

rewrite_block_tool_name(#{<<"type">> := <<"tool_use">>, <<"name">> := Name} = Block, Rewrites) ->
    NewName = maps:get(Name, Rewrites, Name),
    Block#{<<"name">> => NewName};
rewrite_block_tool_name(Block, _) ->
    Block.

inject_signatures(#{<<"content">> := Content} = Response) when is_list(Content) ->
    NewContent = [ensure_signature(Block) || Block <- Content],
    Response#{<<"content">> => NewContent};
inject_signatures(Response) ->
    Response.

ensure_signature(#{<<"type">> := <<"tool_use">>} = Block) ->
    case maps:is_key(<<"signature">>, Block) of
        true -> Block;
        false -> Block#{<<"signature">> => <<>>}
    end;
ensure_signature(#{<<"type">> := <<"thinking">>} = Block) ->
    case maps:is_key(<<"signature">>, Block) of
        true -> Block;
        false -> Block#{<<"signature">> => <<>>}
    end;
ensure_signature(Block) ->
    Block.

get_tool_rewrites() ->
    %% Try CLIPS first, fallback to defaults
    case whereis(clips_engine) of
        undefined -> default_rewrites();
        _ ->
            case config_loader:get(tool_rewrites) of
                undefined -> default_rewrites();
                Map when is_map(Map) -> Map;
                _ -> default_rewrites()
            end
    end.

default_rewrites() ->
    #{<<"bash">> => <<"Bash">>, <<"read">> => <<"Read">>,
      <<"grep">> => <<"Grep">>, <<"task">> => <<"Task">>,
      <<"check">> => <<"Check">>}.

replace_in_paths(Map, [], _Value) -> Map;
replace_in_paths(Map, [Path | Rest], Value) ->
    Keys = binary:split(Path, <<".">>, [global]),
    Map1 = set_nested(Map, Keys, Value),
    replace_in_paths(Map1, Rest, Value).

set_nested(Map, [Key], Value) when is_map(Map) ->
    case maps:is_key(Key, Map) of
        true -> maps:put(Key, Value, Map);
        false -> Map
    end;
set_nested(Map, [Key | Rest], Value) when is_map(Map) ->
    case maps:get(Key, Map, undefined) of
        Sub when is_map(Sub) ->
            maps:put(Key, set_nested(Sub, Rest, Value), Map);
        _ -> Map
    end;
set_nested(Map, _, _) -> Map.
