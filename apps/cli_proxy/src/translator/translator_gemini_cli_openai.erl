-module(translator_gemini_cli_openai).
-behaviour(translator).

%% Gemini CLI -> OpenAI
%% Gemini CLI uses Gemini generateContent format; delegates to translator_gemini_openai.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(gemini_cli, openai, ?MODULE).

request(Model, Body, Stream) ->
    translator_gemini_openai:request(Model, Body, Stream).

init_acc() ->
    translator_gemini_openai:init_acc().

response_stream(Event, Acc) ->
    translator_gemini_openai:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_gemini_openai:response_nonstream(Body).
