-module(sse_parser).

%% Server-Sent Events (SSE) parser and formatter
%% Handles the "data: {...}\n\n" format used by streaming APIs

-export([
    parse/1,
    format_event/1,
    format_done/0,
    format_keepalive/0
]).

%% Parse a chunk of SSE data into individual events
%% Input: raw binary potentially containing multiple "data: ...\n\n" segments
%% Output: list of decoded JSON maps
-spec parse(binary()) -> [map() | binary()].
parse(Data) ->
    Lines = binary:split(Data, <<"\n">>, [global, trim_all]),
    parse_lines(Lines, []).

parse_lines([], Acc) ->
    lists:reverse(Acc);
parse_lines([<<"data: [DONE]">> | Rest], Acc) ->
    parse_lines(Rest, [done | Acc]);
parse_lines([<<"data:", RawJSON/binary>> | Rest], Acc) ->
    JSON = string:trim(RawJSON),
    case JSON of
        <<>> -> parse_lines(Rest, Acc);
        _ ->
            Event = try jiffy:decode(JSON, [return_maps])
                    catch _:_ -> {raw, JSON}
                    end,
            parse_lines(Rest, [Event | Acc])
    end;
parse_lines([<<": ", _/binary>> | Rest], Acc) ->
    %% Comment line (keepalive)
    parse_lines(Rest, Acc);
parse_lines([<<>> | Rest], Acc) ->
    parse_lines(Rest, Acc);
parse_lines([_Line | Rest], Acc) ->
    %% Skip non-data lines
    parse_lines(Rest, Acc).

%% Format a map as an SSE data line
-spec format_event(map() | iodata()) -> [iodata()].
format_event(Event) when is_map(Event) ->
    [<<"data: ">>, jiffy:encode(Event), <<"\n\n">>];
format_event(JSON) when is_binary(JSON) ->
    [<<"data: ">>, JSON, <<"\n\n">>];
format_event(IOData) ->
    [<<"data: ">>, IOData, <<"\n\n">>].

%% Format the SSE termination marker
format_done() ->
    <<"data: [DONE]\n\n">>.

%% Format a keepalive comment
format_keepalive() ->
    <<": keepalive\n\n">>.
