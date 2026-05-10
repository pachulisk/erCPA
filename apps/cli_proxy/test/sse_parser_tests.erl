-module(sse_parser_tests).
-include_lib("eunit/include/eunit.hrl").

parse_single_event_test() ->
    Data = <<"data: {\"type\":\"message_start\"}\n\n">>,
    [Event] = sse_parser:parse(Data),
    ?assertEqual(<<"message_start">>, maps:get(<<"type">>, Event)).

parse_multiple_events_test() ->
    Data = <<"data: {\"type\":\"a\"}\n\ndata: {\"type\":\"b\"}\n\n">>,
    Events = sse_parser:parse(Data),
    ?assertEqual(2, length(Events)),
    ?assertEqual(<<"a">>, maps:get(<<"type">>, hd(Events))).

parse_done_marker_test() ->
    Data = <<"data: {\"type\":\"text\"}\n\ndata: [DONE]\n\n">>,
    Events = sse_parser:parse(Data),
    ?assertEqual([#{<<"type">> => <<"text">>}, done], Events).

parse_keepalive_ignored_test() ->
    Data = <<": keepalive\n\ndata: {\"ok\":true}\n\n">>,
    Events = sse_parser:parse(Data),
    ?assertEqual(1, length(Events)),
    ?assertEqual(true, maps:get(<<"ok">>, hd(Events))).

parse_empty_data_ignored_test() ->
    Data = <<"data: \n\ndata: {\"x\":1}\n\n">>,
    Events = sse_parser:parse(Data),
    ?assertEqual(1, length(Events)).

format_event_test() ->
    Result = iolist_to_binary(sse_parser:format_event(#{<<"type">> => <<"test">>})),
    ?assertEqual(<<"data: {\"type\":\"test\"}\n\n">>, Result).

format_done_test() ->
    ?assertEqual(<<"data: [DONE]\n\n">>, sse_parser:format_done()).

format_keepalive_test() ->
    ?assertEqual(<<": keepalive\n\n">>, sse_parser:format_keepalive()).
