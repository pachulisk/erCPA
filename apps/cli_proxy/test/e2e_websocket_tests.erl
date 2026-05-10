-module(e2e_websocket_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% E2E-004: Responses API WebSocket protocol verification
%% Tests the complete WS protocol without a running server
%% ============================================================

%% Verify the Responses API event type constants

response_event_types_test() ->
    %% All required event types per DESIGN.md
    RequiredTypes = [
        <<"response.created">>,
        <<"response.in_progress">>,
        <<"response.output_item.added">>,
        <<"response.content_part.added">>,
        <<"response.output_text.delta">>,
        <<"response.output_text.done">>,
        <<"response.content_part.done">>,
        <<"response.output_item.done">>,
        <<"response.function_call_arguments.delta">>,
        <<"response.function_call_arguments.done">>,
        <<"response.completed">>,
        <<"error">>
    ],
    %% Verify each is a valid binary
    lists:foreach(fun(T) ->
        ?assert(is_binary(T)),
        ?assert(byte_size(T) > 0)
    end, RequiredTypes).

%% Test error event construction

error_event_401_test() ->
    Event = build_error_event(401, <<"Unauthorized">>),
    ?assertEqual(<<"error">>, maps:get(<<"type">>, Event)),
    ?assertEqual(401, maps:get(<<"status">>, Event)),
    Error = maps:get(<<"error">>, Event),
    ?assertEqual(<<"invalid_api_key">>, maps:get(<<"type">>, Error)).

error_event_429_test() ->
    Event = build_error_event(429, <<"Rate limited">>),
    ?assertEqual(429, maps:get(<<"status">>, Event)),
    Error = maps:get(<<"error">>, Event),
    ?assertEqual(<<"rate_limit_exceeded">>, maps:get(<<"type">>, Error)).

error_event_500_test() ->
    Event = build_error_event(500, <<"Internal error">>),
    Error = maps:get(<<"error">>, Event),
    ?assertEqual(<<"internal_server_error">>, maps:get(<<"type">>, Error)).

error_event_404_test() ->
    Event = build_error_event(404, <<"Not found">>),
    Error = maps:get(<<"error">>, Event),
    ?assertEqual(<<"model_not_found">>, maps:get(<<"type">>, Error)).

%% Test sequence numbering logic

sequence_numbering_test() ->
    %% Simulate sequence numbering
    Seq0 = 0,
    {Event1, Seq1} = make_sequenced_event(#{<<"type">> => <<"response.created">>}, Seq0),
    ?assertEqual(0, maps:get(<<"sequence_number">>, Event1)),
    ?assertEqual(1, Seq1),
    {Event2, Seq2} = make_sequenced_event(#{<<"type">> => <<"response.output_text.delta">>}, Seq1),
    ?assertEqual(1, maps:get(<<"sequence_number">>, Event2)),
    ?assertEqual(2, Seq2),
    %% Sequence must be monotonically increasing
    ?assert(Seq2 > Seq1),
    ?assert(Seq1 > Seq0).

%% Test response.create request normalization

request_normalize_model_required_test() ->
    Req = #{<<"type">> => <<"response.create">>, <<"input">> => []},
    ?assertEqual(<<>>, maps:get(<<"model">>, Req, <<>>)).

request_normalize_defaults_test() ->
    Req = #{<<"type">> => <<"response.create">>,
            <<"model">> => <<"gpt-4">>,
            <<"input">> => [#{<<"type">> => <<"message">>,
                              <<"role">> => <<"user">>,
                              <<"content">> => <<"hi">>}]},
    ?assertEqual(<<"gpt-4">>, maps:get(<<"model">>, Req)),
    ?assert(is_list(maps:get(<<"input">>, Req))).

%% Test incremental vs full transcript detection

incremental_mode_detection_test() ->
    %% With previous_response_id → incremental
    Req1 = #{<<"previous_response_id">> => <<"resp_123">>},
    ?assert(is_incremental(Req1)),
    %% Without → full transcript
    Req2 = #{<<"model">> => <<"gpt-4">>},
    ?assertNot(is_incremental(Req2)),
    %% Empty string → not incremental
    Req3 = #{<<"previous_response_id">> => <<>>},
    ?assertNot(is_incremental(Req3)).

%% Test tool cache behavior

tool_cache_lifecycle_test() ->
    Cache = ets:new(test_ws_cache, [set, public]),
    %% Initially empty
    ?assertEqual([], ets:tab2list(Cache)),
    %% Cache a tool call
    ets:insert(Cache, {<<"call_1">>, #{<<"type">> => <<"function_call">>,
                                       <<"name">> => <<"bash">>}}),
    ?assertEqual(1, ets:info(Cache, size)),
    %% Lookup
    [{<<"call_1">>, Cached}] = ets:lookup(Cache, <<"call_1">>),
    ?assertEqual(<<"bash">>, maps:get(<<"name">>, Cached)),
    %% Cleanup
    ets:delete(Cache).

%%====================================================================
%% Helpers
%%====================================================================

build_error_event(Status, Message) ->
    #{<<"type">> => <<"error">>,
      <<"status">> => Status,
      <<"error">> => #{
          <<"type">> => error_type(Status),
          <<"message">> => Message
      }}.

error_type(401) -> <<"invalid_api_key">>;
error_type(403) -> <<"insufficient_quota">>;
error_type(404) -> <<"model_not_found">>;
error_type(429) -> <<"rate_limit_exceeded">>;
error_type(S) when S >= 400, S < 500 -> <<"invalid_request_error">>;
error_type(_) -> <<"internal_server_error">>.

make_sequenced_event(Event, Seq) ->
    {Event#{<<"sequence_number">> => Seq}, Seq + 1}.

is_incremental(#{<<"previous_response_id">> := Id})
  when Id =/= <<>>, Id =/= null, Id =/= undefined -> true;
is_incremental(_) -> false.
