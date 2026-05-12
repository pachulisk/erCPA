-module(translator_openai_gemini_cli).
-behaviour(translator).

%% OpenAI -> Gemini CLI
%% Gemini CLI uses Gemini generateContent format; delegates to translator_openai_gemini.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(openai, gemini_cli, ?MODULE).

request(Model, Body, Stream) ->
    translator_openai_gemini:request(Model, Body, Stream).

init_acc() ->
    translator_openai_gemini:init_acc().

response_stream(Event, Acc) ->
    translator_openai_gemini:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_openai_gemini:response_nonstream(Body).
