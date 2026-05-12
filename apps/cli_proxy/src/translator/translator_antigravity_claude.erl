-module(translator_antigravity_claude).
-behaviour(translator).

%% Antigravity -> Claude
%% Antigravity uses Claude-like format; mostly passthrough with minor adjustments.

-export([request/3, response_stream/2, response_nonstream/1, init_acc/0]).
-export([register/0]).

register() ->
    translator_registry:register(antigravity, claude, ?MODULE).

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
