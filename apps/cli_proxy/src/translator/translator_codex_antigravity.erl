-module(translator_codex_antigravity).
-behaviour(translator).

%% Codex -> Antigravity
%% Antigravity is Claude-compatible; delegates to translator_codex_claude.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(codex, antigravity, ?MODULE).

request(Model, Body, Stream) ->
    translator_codex_claude:request(Model, Body, Stream).

init_acc() ->
    translator_codex_claude:init_acc().

response_stream(Event, Acc) ->
    translator_codex_claude:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_codex_claude:response_nonstream(Body).
