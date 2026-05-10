-module(translator).

%% Behaviour definition for protocol translators
%%
%% Each translator module converts between two API formats.
%% request/3 transforms the request body.
%% response_stream/2 handles streaming SSE events with an accumulator.
%% response_nonstream/1 handles complete response bodies.
%% init_acc/0 returns the initial accumulator for streaming.

-callback request(ModelName :: binary(), Body :: map(), Stream :: boolean()) ->
    map().

-callback response_stream(Event :: map(), Acc :: term()) ->
    {[iodata()], NewAcc :: term()}.

-callback response_nonstream(Body :: map()) ->
    map().

-callback init_acc() -> term().

%% Optional callback for Responses API event translation
-callback response_stream_responses(Event :: map()) ->
    [map()].

-optional_callbacks([response_stream_responses/1]).
