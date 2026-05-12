-module(translator_gemini_antigravity).
-behaviour(translator).

%% Gemini -> Antigravity
%% Antigravity is Claude-compatible; delegates to translator_gemini_claude.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(gemini, antigravity, ?MODULE).

request(Model, Body, Stream) ->
    translator_gemini_claude:request(Model, Body, Stream).

init_acc() ->
    translator_gemini_claude:init_acc().

response_stream(Event, Acc) ->
    translator_gemini_claude:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_gemini_claude:response_nonstream(Body).
