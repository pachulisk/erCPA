-module(translator_gemini_cli_codex).
-behaviour(translator).

%% Gemini CLI -> Codex
%% Gemini CLI is Gemini-compatible; delegates to translator_gemini_codex.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(gemini_cli, codex, ?MODULE).

request(Model, Body, Stream) ->
    translator_gemini_codex:request(Model, Body, Stream).

init_acc() ->
    translator_gemini_codex:init_acc().

response_stream(Event, Acc) ->
    translator_gemini_codex:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_gemini_codex:response_nonstream(Body).
