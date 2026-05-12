-module(translator_antigravity_codex).
-behaviour(translator).

%% Antigravity -> Codex
%% Antigravity is Claude-compatible; delegates to translator_claude_codex.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(antigravity, codex, ?MODULE).

request(Model, Body, Stream) ->
    translator_claude_codex:request(Model, Body, Stream).

init_acc() ->
    translator_claude_codex:init_acc().

response_stream(Event, Acc) ->
    translator_claude_codex:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_claude_codex:response_nonstream(Body).
