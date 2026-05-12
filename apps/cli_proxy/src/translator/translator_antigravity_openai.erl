-module(translator_antigravity_openai).
-behaviour(translator).

%% Antigravity -> OpenAI
%% Antigravity is Claude-compatible; delegates to translator_claude_openai.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

-dialyzer({nowarn_function, [request/3, response_stream/2]}).

register() ->
    translator_registry:register(antigravity, openai, ?MODULE).

request(Model, Body, Stream) ->
    translator_claude_openai:request(Model, Body, Stream).

init_acc() ->
    translator_claude_openai:init_acc().

response_stream(Event, Acc) ->
    translator_claude_openai:response_stream(Event, Acc).

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    translator_claude_openai:response_nonstream(Body).
