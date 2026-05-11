-module(builtin_tools).

%% Claude builtin tools registry
%% Detects and augments builtin tools in cross-provider translation

-export([default_tools/0, augment_registry/2, is_builtin/2]).

-define(DEFAULT_BUILTINS, [<<"web_search">>, <<"code_execution">>,
                            <<"text_editor">>, <<"computer">>]).

-spec default_tools() -> [binary()].
default_tools() -> ?DEFAULT_BUILTINS.

%% Augment the builtin registry from request body tools array
-spec augment_registry(map(), [binary()]) -> [binary()].
augment_registry(Request, Registry) ->
    Tools = maps:get(<<"tools">>, Request, []),
    NewTools = lists:filtermap(fun(Tool) when is_map(Tool) ->
        case maps:is_key(<<"type">>, Tool) of
            true ->
                Name = maps:get(<<"name">>, Tool, <<>>),
                case Name of
                    <<>> -> false;
                    _ -> {true, Name}
                end;
            false -> false
        end;
    (_) -> false
    end, Tools),
    lists:usort(Registry ++ NewTools).

%% Check if a tool name is in the builtin registry
-spec is_builtin(binary(), [binary()]) -> boolean().
is_builtin(Name, Registry) ->
    lists:member(Name, Registry).
