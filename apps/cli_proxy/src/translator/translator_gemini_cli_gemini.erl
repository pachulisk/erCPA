-module(translator_gemini_cli_gemini).
-behaviour(translator).

%% Gemini CLI -> Gemini
%% Gemini CLI uses Gemini generateContent format; passthrough translation.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(gemini_cli, gemini, ?MODULE).

-spec request(binary(), map(), boolean()) -> map().
request(_Model, Body, _Stream) ->
    Body.

init_acc() -> #{}.

-spec response_stream(map(), map()) -> {[iodata()], map()}.
response_stream(Event, Acc) ->
    {[jiffy:encode(Event)], Acc}.

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    Body.
