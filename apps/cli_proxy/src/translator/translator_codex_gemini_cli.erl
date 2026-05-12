-module(translator_codex_gemini_cli).
-behaviour(translator).

%% Codex -> Gemini CLI
%% Gemini CLI is Gemini-compatible; delegates to translator_codex_gemini.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(codex, gemini_cli, ?MODULE).

request(Model, Body, Stream) ->
    translator_codex_gemini:request(Model, Body, Stream).

init_acc() ->
    translator_codex_gemini:init_acc().

response_stream(Event, Acc) ->
    translator_codex_gemini:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_codex_gemini:response_nonstream(Body).
