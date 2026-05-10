-module(payload_rules_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Payload Rules Tests
%% ============================================================

%% --- Defaults: set only if missing ---

default_sets_missing_field_test() ->
    Body = #{<<"model">> => <<"gpt-4">>},
    Rules = #{default => [#{
        models => [#{name => <<"*">>, protocol => <<>>}],
        params => #{<<"temperature">> => 0.7}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Result)).

default_does_not_override_existing_test() ->
    Body = #{<<"model">> => <<"gpt-4">>, <<"temperature">> => 0.9},
    Rules = #{default => [#{
        models => [#{name => <<"*">>, protocol => <<>>}],
        params => #{<<"temperature">> => 0.7}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    ?assertEqual(0.9, maps:get(<<"temperature">>, Result)).

%% --- Overrides: always set ---

override_replaces_existing_test() ->
    Body = #{<<"model">> => <<"gpt-4">>, <<"user">> => <<"old">>},
    Rules = #{override => [#{
        models => [#{name => <<"*">>, protocol => <<>>}],
        params => #{<<"user">> => <<"system">>}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    ?assertEqual(<<"system">>, maps:get(<<"user">>, Result)).

%% --- Filters: remove paths ---

filter_removes_field_test() ->
    Body = #{<<"model">> => <<"gpt-4">>, <<"top_p">> => 0.9, <<"temperature">> => 0.7},
    Rules = #{filter => [#{
        models => [#{name => <<"gpt-*">>, protocol => <<>>}],
        params => [<<"top_p">>]
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    ?assertNot(maps:is_key(<<"top_p">>, Result)),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Result)).

%% --- Wildcard matching ---

wildcard_star_matches_all_test() ->
    Body = #{<<"model">> => <<"anything">>},
    Rules = #{override => [#{
        models => [#{name => <<"*">>, protocol => <<>>}],
        params => #{<<"extra">> => true}
    }]},
    Result = payload_rules:apply_rules(Body, <<"anything">>, claude, Rules),
    ?assertEqual(true, maps:get(<<"extra">>, Result)).

wildcard_prefix_matches_test() ->
    Body = #{<<"model">> => <<"gpt-4-turbo">>},
    Rules = #{override => [#{
        models => [#{name => <<"gpt-*">>, protocol => <<>>}],
        params => #{<<"matched">> => true}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4-turbo">>, openai, Rules),
    ?assertEqual(true, maps:get(<<"matched">>, Result)).

wildcard_no_match_skips_test() ->
    Body = #{<<"model">> => <<"claude-3">>},
    Rules = #{override => [#{
        models => [#{name => <<"gpt-*">>, protocol => <<>>}],
        params => #{<<"matched">> => true}
    }]},
    Result = payload_rules:apply_rules(Body, <<"claude-3">>, claude, Rules),
    ?assertNot(maps:is_key(<<"matched">>, Result)).

%% --- Protocol filtering ---

protocol_match_test() ->
    Body = #{<<"model">> => <<"gpt-4">>},
    Rules = #{override => [#{
        models => [#{name => <<"*">>, protocol => <<"openai">>}],
        params => #{<<"proto_matched">> => true}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    ?assertEqual(true, maps:get(<<"proto_matched">>, Result)).

protocol_mismatch_skips_test() ->
    Body = #{<<"model">> => <<"gpt-4">>},
    Rules = #{override => [#{
        models => [#{name => <<"*">>, protocol => <<"claude">>}],
        params => #{<<"proto_matched">> => true}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    ?assertNot(maps:is_key(<<"proto_matched">>, Result)).

%% --- Nested path operations ---

nested_set_path_test() ->
    Body = #{<<"model">> => <<"gpt-4">>},
    Rules = #{override => [#{
        models => [#{name => <<"*">>, protocol => <<>>}],
        params => #{<<"thinking.budget_tokens">> => 10000}
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertEqual(10000, maps:get(<<"budget_tokens">>, Thinking)).

nested_remove_path_test() ->
    Body = #{<<"model">> => <<"gpt-4">>,
             <<"thinking">> => #{<<"budget_tokens">> => 5000, <<"type">> => <<"enabled">>}},
    Rules = #{filter => [#{
        models => [#{name => <<"*">>, protocol => <<>>}],
        params => [<<"thinking.budget_tokens">>]
    }]},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, Rules),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertNot(maps:is_key(<<"budget_tokens">>, Thinking)),
    ?assertEqual(<<"enabled">>, maps:get(<<"type">>, Thinking)).

%% --- Empty config does nothing ---

empty_rules_passthrough_test() ->
    Body = #{<<"model">> => <<"gpt-4">>, <<"temperature">> => 0.5},
    Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, #{}),
    ?assertEqual(Body, Result).
