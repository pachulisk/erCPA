-module(translator_antigravity_gemini_cli).
-behaviour(translator).

%% Antigravity -> Gemini CLI
%% Antigravity is Claude-compatible; delegates to translator_claude_gemini_cli.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(antigravity, gemini_cli, ?MODULE).

request(Model, Body, Stream) ->
    translator_claude_gemini_cli:request(Model, Body, Stream).

init_acc() ->
    translator_claude_gemini_cli:init_acc().

response_stream(Event, Acc) ->
    translator_claude_gemini_cli:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_claude_gemini_cli:response_nonstream(Body).
