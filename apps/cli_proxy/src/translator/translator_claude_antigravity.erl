-module(translator_claude_antigravity).
-behaviour(translator).

%% Claude -> Antigravity
%% Antigravity is Claude-compatible; passthrough translation.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(claude, antigravity, ?MODULE).

-spec request(binary(), map(), boolean()) -> map().
request(Model, Body, Stream) ->
    Body#{<<"model">> => Model, <<"stream">> => Stream}.

init_acc() -> #{}.

-spec response_stream(map(), map()) -> {[iodata()], map()}.
response_stream(Event, Acc) ->
    {[jiffy:encode(Event)], Acc}.

-spec response_nonstream(map()) -> map().
response_nonstream(Body) ->
    Body.
