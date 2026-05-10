-module(responses_ws_handler).
-behaviour(cowboy_websocket).

%% Responses API WebSocket handler
%% Implements bidirectional protocol with response.create/append + event streaming
%% Each connection = one Erlang process owning all session state

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

%% Test helpers
-export([repair_tool_calls/2, maybe_unpin_auth/2]).

-record(state, {
    session_id        :: binary(),
    execution_id      :: binary(),
    pinned_auth_id    :: binary() | undefined,
    last_request      :: map() | undefined,
    last_response_output :: [map()],
    tool_call_cache   :: ets:tid(),
    tool_output_cache :: ets:tid(),
    seq               :: non_neg_integer(),
    upstream_pid      :: pid() | undefined
}).

%%====================================================================
%% Cowboy WebSocket callbacks
%%====================================================================

init(Req, State) ->
    case access_control:authenticate(Req) of
        {ok, _} ->
            {cowboy_websocket, Req, State, #{idle_timeout => 300000}};
        {error, _} ->
            Req1 = cowboy_req:reply(401, #{}, <<"Unauthorized">>, Req),
            {ok, Req1, State}
    end.

websocket_init(_State) ->
    SessionId = extract_session_id(),
    ExecId = generate_uuid(),
    ToolCallCache = ets:new(tool_calls, [set, private]),
    ToolOutputCache = ets:new(tool_outputs, [set, private]),
    {ok, #state{
        session_id = SessionId,
        execution_id = ExecId,
        pinned_auth_id = undefined,
        last_request = undefined,
        last_response_output = [],
        tool_call_cache = ToolCallCache,
        tool_output_cache = ToolOutputCache,
        seq = 0,
        upstream_pid = undefined
    }}.

websocket_handle({text, RawJSON}, State) ->
    case jiffy:decode(RawJSON, [return_maps]) of
        #{<<"type">> := <<"response.create">>} = Req ->
            handle_create(Req, State);
        #{<<"type">> := <<"response.append">>} = Req ->
            handle_create(Req, State);  %% append is structurally same as create
        _ ->
            {ok, State}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({upstream_event, Event}, State) ->
    {Frames, State1} = translate_and_sequence(Event, State),
    {Frames, State1};

websocket_info({upstream_done, ResponseOutput, _Usage}, State) ->
    State1 = update_tool_caches(ResponseOutput, State),
    State2 = State1#state{last_response_output = ResponseOutput},
    DoneFrame = {text, <<"[DONE]">>},
    {[DoneFrame], State2};

websocket_info({upstream_error, Status, Message}, State) ->
    ErrorEvent = build_error_event(Status, Message),
    Frame = {text, jiffy:encode(ErrorEvent)},
    DoneFrame = {text, <<"[DONE]">>},
    State1 = maybe_unpin_auth(Status, State),
    {[Frame, DoneFrame], State1};

websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, #state{tool_call_cache = TC, tool_output_cache = TO,
                                 upstream_pid = Upstream}) ->
    ets:delete(TC),
    ets:delete(TO),
    case Upstream of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> exit(Pid, shutdown);
                false -> ok
            end
    end,
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%%====================================================================
%% Request handling
%%====================================================================

handle_create(Req, State) ->
    Model = maps:get(<<"model">>, Req, <<>>),
    Input = maps:get(<<"input">>, Req, []),

    %% Merge with previous state (unless incremental mode)
    MergedInput = case should_use_incremental(Req, State) of
        true -> Input;
        false -> merge_transcript(State#state.last_response_output, Input)
    end,

    %% Repair orphaned tool outputs
    RepairedInput = repair_tool_calls(MergedInput, State#state.tool_call_cache),

    %% Build normalized request
    NormReq = Req#{<<"input">> => RepairedInput, <<"stream">> => true},

    %% Execute via conductor
    case conductor:execute(openai_response, Model, NormReq) of
        {ok, Response} ->
            %% Non-stream response — wrap as events
            Events = response_to_events(Response, State#state.seq),
            Frames = [{text, jiffy:encode(E)} || E <- Events] ++ [{text, <<"[DONE]">>}],
            OutputItems = maps:get(<<"output">>, Response, []),
            State1 = update_tool_caches(OutputItems, State),
            {Frames, State1#state{
                last_request = NormReq,
                last_response_output = OutputItems,
                pinned_auth_id = undefined,
                seq = State#state.seq + length(Events)
            }};
        {error, Status, ErrBody} ->
            ErrorEvent = build_error_event(Status, ErrBody),
            Frames = [{text, jiffy:encode(ErrorEvent)}, {text, <<"[DONE]">>}],
            State1 = maybe_unpin_auth(Status, State),
            {Frames, State1}
    end.

%%====================================================================
%% Tool call cache repair
%%====================================================================

-spec repair_tool_calls([map()], ets:tid()) -> [map()].
repair_tool_calls(Input, ToolCallCache) ->
    lists:flatmap(fun
        (#{<<"type">> := <<"function_call_output">>, <<"call_id">> := CallId} = Item) ->
            case ets:lookup(ToolCallCache, CallId) of
                [{CallId, CachedCall}] ->
                    [CachedCall, Item];
                [] ->
                    [Item]
            end;
        (Item) ->
            [Item]
    end, Input).

update_tool_caches(ResponseOutput, State) ->
    lists:foreach(fun
        (#{<<"type">> := <<"function_call">>, <<"call_id">> := CallId} = Item) ->
            ets:insert(State#state.tool_call_cache, {CallId, Item});
        (_) -> ok
    end, ResponseOutput),
    State.

%%====================================================================
%% Credential pinning
%%====================================================================

-spec maybe_unpin_auth(integer(), #state{}) -> #state{}.
maybe_unpin_auth(Status, State) when Status =:= 401;
                                      Status =:= 402;
                                      Status =:= 403;
                                      Status =:= 429 ->
    State#state{pinned_auth_id = undefined};
maybe_unpin_auth(_Status, State) ->
    State.

%%====================================================================
%% Event translation and sequencing
%%====================================================================

translate_and_sequence(Event, #state{seq = Seq} = State) ->
    Sequenced = Event#{<<"sequence_number">> => Seq},
    Frame = {text, jiffy:encode(Sequenced)},
    {[Frame], State#state{seq = Seq + 1}}.

response_to_events(Response, StartSeq) ->
    Id = maps:get(<<"id">>, Response, <<>>),
    Model = maps:get(<<"model">>, Response, <<>>),
    [
        #{<<"type">> => <<"response.created">>,
          <<"sequence_number">> => StartSeq,
          <<"response">> => #{<<"id">> => Id, <<"status">> => <<"in_progress">>,
                              <<"model">> => Model}},
        #{<<"type">> => <<"response.completed">>,
          <<"sequence_number">> => StartSeq + 1,
          <<"response">> => Response}
    ].

%%====================================================================
%% Error mapping
%%====================================================================

build_error_event(Status, Message) ->
    #{
        <<"type">> => <<"error">>,
        <<"status">> => Status,
        <<"error">> => #{
            <<"type">> => error_type(Status),
            <<"message">> => Message
        }
    }.

error_type(401) -> <<"invalid_api_key">>;
error_type(402) -> <<"insufficient_quota">>;
error_type(403) -> <<"insufficient_quota">>;
error_type(404) -> <<"model_not_found">>;
error_type(408) -> <<"request_timeout">>;
error_type(429) -> <<"rate_limit_exceeded">>;
error_type(S) when S >= 400, S < 500 -> <<"invalid_request_error">>;
error_type(_) -> <<"internal_server_error">>.

%%====================================================================
%% Helpers
%%====================================================================

should_use_incremental(#{<<"previous_response_id">> := PrevId}, _State)
  when PrevId =/= <<>>, PrevId =/= null, PrevId =/= undefined ->
    true;
should_use_incremental(_, _) ->
    false.

merge_transcript([], Input) -> Input;
merge_transcript(PrevOutput, Input) ->
    %% Prepend previous output as input items
    PrevAsInput = [output_to_input(O) || O <- PrevOutput],
    PrevAsInput ++ Input.

output_to_input(#{<<"type">> := <<"message">>, <<"content">> := Content} = Item) ->
    Role = maps:get(<<"role">>, Item, <<"assistant">>),
    #{<<"type">> => <<"message">>, <<"role">> => Role, <<"content">> => Content};
output_to_input(#{<<"type">> := <<"function_call">>} = Item) ->
    Item;
output_to_input(Item) ->
    Item.

extract_session_id() ->
    <<"sess_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

generate_uuid() ->
    <<"exec_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
