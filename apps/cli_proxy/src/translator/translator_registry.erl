-module(translator_registry).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    register/3,
    get/2,
    get_responses/2,
    has/2,
    translate_request/5,
    translate_stream/4,
    translate_nonstream/3
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, translator_registry_tab).
-define(RESPONSES_TABLE, translator_registry_responses_tab).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(From :: atom(), To :: atom(), Module :: module()) -> ok.
register(From, To, Module) ->
    gen_server:call(?MODULE, {register, From, To, Module}).

-spec get(From :: atom(), To :: atom()) -> {ok, module()} | error.
get(From, To) ->
    case ets:lookup(?TABLE, {From, To}) of
        [{{From, To}, Mod}] -> {ok, Mod};
        [] -> error
    end.

-spec get_responses(From :: atom(), To :: atom()) -> {ok, module()} | error.
get_responses(From, To) ->
    case ets:lookup(?RESPONSES_TABLE, {From, To}) of
        [{{From, To}, Mod}] -> {ok, Mod};
        [] -> get(From, To)  %% fallback to standard translator
    end.

-spec has(From :: atom(), To :: atom()) -> boolean().
has(From, To) ->
    ets:member(?TABLE, {From, To}).

-spec translate_request(From :: atom(), To :: atom(), Model :: binary(),
                        Body :: map(), Stream :: boolean()) -> map().
translate_request(From, To, Model, Body, Stream) ->
    case get(From, To) of
        {ok, Mod} -> Mod:request(Model, Body, Stream);
        error -> Body  %% passthrough if no translator
    end.

-spec translate_stream(From :: atom(), To :: atom(), Event :: map(), Acc :: term()) ->
    {[iodata()], term()}.
translate_stream(From, To, Event, Acc) ->
    case get(From, To) of
        {ok, Mod} -> Mod:response_stream(Event, Acc);
        error -> {[], Acc}
    end.

-spec translate_nonstream(From :: atom(), To :: atom(), Body :: map()) -> map().
translate_nonstream(From, To, Body) ->
    case get(From, To) of
        {ok, Mod} -> Mod:response_nonstream(Body);
        error -> Body
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    _ = ets:new(?TABLE, [named_table, set, public, {read_concurrency, true}]),
    _ = ets:new(?RESPONSES_TABLE, [named_table, set, public, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register, From, To, Module}, _From, State) ->
    ets:insert(?TABLE, {{From, To}, Module}),
    %% Also register in responses table if module exports response_stream_responses/1
    case erlang:function_exported(Module, response_stream_responses, 1) of
        true -> ets:insert(?RESPONSES_TABLE, {{From, To}, Module});
        false -> ok
    end,
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, error, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.
