-module(model_registry_ext_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Model registry extended tests
%% ============================================================

ensure_registry() ->
    case whereis(model_registry) of
        undefined ->
            {ok, _} = model_registry:start_link(),
            ok;
        _ ->
            ok
    end.

model_registry_ext_test_() ->
    {foreach,
     fun() -> ensure_registry() end,
     fun(_) -> ok end,
     [
        fun(_) -> fun register_and_list_test/0 end,
        fun(_) -> fun unregister_removes_test/0 end,
        fun(_) -> fun multiple_providers_same_model_test/0 end,
        fun(_) -> fun is_model_available_test/0 end,
        fun(_) -> fun empty_models_test/0 end,
        fun(_) -> fun register_replaces_old_test/0 end
     ]}.

register_and_list_test() ->
    model_registry:register_client(<<"c1">>, <<"claude">>,
        [#{<<"id">> => <<"model-a">>, <<"provider">> => <<"claude">>}]),
    Models = model_registry:get_available_models(),
    Ids = [maps:get(<<"id">>, M) || M <- Models],
    ?assert(lists:member(<<"model-a">>, Ids)),
    model_registry:unregister_client(<<"c1">>).

unregister_removes_test() ->
    model_registry:register_client(<<"c2">>, <<"gemini">>,
        [#{<<"id">> => <<"model-b">>, <<"provider">> => <<"gemini">>}]),
    ?assert(model_registry:is_model_available(<<"model-b">>)),
    model_registry:unregister_client(<<"c2">>),
    ?assertNot(model_registry:is_model_available(<<"model-b">>)).

multiple_providers_same_model_test() ->
    model_registry:register_client(<<"c3">>, <<"claude">>,
        [#{<<"id">> => <<"shared-model">>, <<"provider">> => <<"claude">>}]),
    model_registry:register_client(<<"c4">>, <<"gemini">>,
        [#{<<"id">> => <<"shared-model">>, <<"provider">> => <<"gemini">>}]),
    ?assert(model_registry:is_model_available(<<"shared-model">>)),
    %% Remove one provider, model still available from other
    model_registry:unregister_client(<<"c3">>),
    ?assert(model_registry:is_model_available(<<"shared-model">>)),
    model_registry:unregister_client(<<"c4">>),
    ?assertNot(model_registry:is_model_available(<<"shared-model">>)).

is_model_available_test() ->
    ?assertNot(model_registry:is_model_available(<<"nonexistent">>)),
    model_registry:register_client(<<"c5">>, <<"test">>,
        [#{<<"id">> => <<"exist-model">>, <<"provider">> => <<"test">>}]),
    ?assert(model_registry:is_model_available(<<"exist-model">>)),
    model_registry:unregister_client(<<"c5">>).

empty_models_test() ->
    model_registry:register_client(<<"c6">>, <<"test">>, []),
    Models = model_registry:get_available_models(),
    %% Empty model list should not add anything
    NoC6 = [M || M <- Models, maps:get(<<"owned_by">>, M, <<>>) =:= <<"test">>],
    ?assertEqual([], NoC6),
    model_registry:unregister_client(<<"c6">>).

register_replaces_old_test() ->
    model_registry:register_client(<<"c7">>, <<"claude">>,
        [#{<<"id">> => <<"old-model">>, <<"provider">> => <<"claude">>}]),
    ?assert(model_registry:is_model_available(<<"old-model">>)),
    %% Re-register with different models
    model_registry:register_client(<<"c7">>, <<"claude">>,
        [#{<<"id">> => <<"new-model">>, <<"provider">> => <<"claude">>}]),
    ?assert(model_registry:is_model_available(<<"new-model">>)),
    ?assertNot(model_registry:is_model_available(<<"old-model">>)),
    model_registry:unregister_client(<<"c7">>).
