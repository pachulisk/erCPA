-module(clips_engine).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    start_link/1,
    assert/1,
    retract/1,
    retract_all/1,
    run/0,
    query/2,
    query/3,
    reset/0,
    load/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    port :: port() | undefined,
    port_path :: string()
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    start_link(default_port_path()).

start_link(PortPath) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [PortPath], []).

-spec assert(map() | tuple()) -> {ok, integer()} | {error, term()}.
assert(Fact) ->
    gen_server:call(?MODULE, {assert, Fact}).

-spec retract(term()) -> ok | {error, term()}.
retract(FactId) when is_integer(FactId) ->
    gen_server:call(?MODULE, {retract, FactId});
retract({Template, Id}) ->
    gen_server:call(?MODULE, {retract_by_key, Template, Id}).

-spec retract_all(atom() | binary()) -> ok | {error, term()}.
retract_all(TemplateName) ->
    gen_server:call(?MODULE, {retract_all, TemplateName}).

-spec run() -> {ok, integer()} | {error, term()}.
run() ->
    gen_server:call(?MODULE, run, 10000).

-spec query(atom() | binary(), binary()) -> {ok, map()} | error.
query(Template, RequestId) ->
    gen_server:call(?MODULE, {query, Template, <<"request-id">>, RequestId}).

-spec query(atom() | binary(), binary(), binary()) -> {ok, map()} | error.
query(Template, SlotName, SlotValue) ->
    gen_server:call(?MODULE, {query, Template, SlotName, SlotValue}).

-spec reset() -> ok.
reset() ->
    gen_server:call(?MODULE, reset).

-spec load(string()) -> ok | {error, term()}.
load(FilePath) ->
    gen_server:call(?MODULE, {load, FilePath}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([PortPath]) ->
    process_flag(trap_exit, true),
    case start_port(PortPath) of
        {ok, Port} ->
            State = #state{port = Port, port_path = PortPath},
            %% Load CLIPS rule files on startup
            load_rules(State),
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

load_rules(#state{port = Port}) ->
    PrivDir = code:priv_dir(cli_proxy),
    ClipsDir = filename:join(PrivDir, "clips"),
    Files = ["templates.clp", "selection.clp", "cooldown.clp",
             "thinking.clp", "quota.clp", "routing.clp",
             "status_rules.clp", "credential_policy.clp",
             "cloaking_rules.clp", "rewrite_rules.clp",
             "client_routing.clp"],
    lists:foreach(fun(File) ->
        Path = filename:join(ClipsDir, File),
        case filelib:is_file(Path) of
            true ->
                JSON = jiffy:encode(#{<<"op">> => <<"load">>,
                                      <<"file">> => list_to_binary(Path)}),
                port_command_sync(Port, JSON);
            false ->
                ok
        end
    end, Files).

handle_call({assert, Fact}, _From, #state{port = Port} = State) ->
    JSON = encode_assert(Fact),
    Reply = port_command_sync(Port, JSON),
    case Reply of
        #{<<"ok">> := true, <<"fact-id">> := FId} -> {reply, {ok, FId}, State};
        #{<<"ok">> := true} -> {reply, {ok, 0}, State};
        #{<<"error">> := Msg} -> {reply, {error, Msg}, State};
        _ -> {reply, {error, bad_response}, State}
    end;

handle_call({retract, FactId}, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"retract">>, <<"fact-id">> => FactId}),
    _Reply = port_command_sync(Port, JSON),
    {reply, ok, State};

handle_call({retract_by_key, Template, Id}, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"retract">>,
                          <<"template">> => to_bin(Template),
                          <<"id">> => Id}),
    _Reply = port_command_sync(Port, JSON),
    {reply, ok, State};

handle_call({retract_all, TemplateName}, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"retract-all">>,
                          <<"template">> => to_bin(TemplateName)}),
    _Reply = port_command_sync(Port, JSON),
    {reply, ok, State};

handle_call(run, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"run">>, <<"limit">> => -1}),
    Reply = port_command_sync(Port, JSON),
    case Reply of
        #{<<"ok">> := true, <<"fired">> := N} -> {reply, {ok, N}, State};
        #{<<"error">> := Msg} -> {reply, {error, Msg}, State};
        _ -> {reply, {ok, 0}, State}
    end;

handle_call({query, Template, SlotName, SlotValue}, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"query">>,
                          <<"template">> => to_clips_template(to_bin(Template)),
                          <<"slot">> => to_clips_slot(SlotName),
                          <<"value">> => SlotValue}),
    Reply = port_command_sync(Port, JSON),
    case Reply of
        #{<<"ok">> := true, <<"result">> := null} -> {reply, error, State};
        #{<<"ok">> := true, <<"result">> := Result} -> {reply, {ok, Result}, State};
        #{<<"error">> := _Msg} -> {reply, error, State};
        _ -> {reply, error, State}
    end;

handle_call(reset, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"reset">>}),
    _Reply = port_command_sync(Port, JSON),
    %% Reload rules after reset (reset clears everything in CLIPS)
    load_rules(State),
    {reply, ok, State};

handle_call({load, FilePath}, _From, #state{port = Port} = State) ->
    JSON = jiffy:encode(#{<<"op">> => <<"load">>, <<"file">> => list_to_binary(FilePath)}),
    Reply = port_command_sync(Port, JSON),
    case Reply of
        #{<<"ok">> := true} -> {reply, ok, State};
        #{<<"error">> := Msg} -> {reply, {error, Msg}, State};
        _ -> {reply, {error, unknown}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Port, Reason}, #state{port = Port, port_path = Path} = State) ->
    %% Port crashed — restart it
    case start_port(Path) of
        {ok, NewPort} ->
            {noreply, State#state{port = NewPort}};
        {error, _} ->
            {stop, {port_crashed, Reason}, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port}) ->
    catch port_close(Port),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

default_port_path() ->
    PrivDir = code:priv_dir(cli_proxy),
    filename:join(PrivDir, "clips_port").

start_port(PortPath) ->
    case filelib:is_file(PortPath) of
        true ->
            Port = open_port({spawn_executable, PortPath},
                           [use_stdio, {line, 1048576}, exit_status, binary]),
            {ok, Port};
        false ->
            {error, {port_not_found, PortPath}}
    end.

port_command_sync(Port, JSON) ->
    Line = <<JSON/binary, "\n">>,
    port_command(Port, Line),
    receive
        {Port, {data, {eol, ResponseLine}}} ->
            jiffy:decode(ResponseLine, [return_maps]);
        {Port, {data, {noeol, _Partial}}} ->
            #{<<"error">> => <<"response too long">>}
    after 5000 ->
        #{<<"error">> => <<"timeout">>}
    end.

encode_assert({TemplateName, Fields}) when is_map(Fields) ->
    %% Convert to CLIPS fact syntax: (template (slot1 val1) (slot2 val2) ...)
    ClipsTemplate = to_clips_template(to_bin(TemplateName)),
    ClipsFact = map_to_clips_fact(ClipsTemplate, Fields),
    jiffy:encode(#{<<"op">> => <<"assert">>, <<"fact">> => ClipsFact});
encode_assert(Fact) when is_map(Fact) ->
    jiffy:encode(#{<<"op">> => <<"assert">>, <<"fact">> => Fact}).

to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

%% Convert Erlang map to CLIPS fact syntax string
%% #{id => <<"c1">>, status => active} → (template (id "c1") (status active))
map_to_clips_fact(Template, Fields) ->
    Slots = maps:fold(fun(K, V, Acc) ->
        SlotName = to_bin(K),
        %% Convert slot name from camelCase/underscore to CLIPS hyphen convention
        ClipsSlotName = to_clips_slot(SlotName),
        SlotVal = format_clips_value(V),
        [<<" (", ClipsSlotName/binary, " ", SlotVal/binary, ")">> | Acc]
    end, [], Fields),
    SlotsStr = iolist_to_binary(lists:reverse(Slots)),
    <<"(", Template/binary, SlotsStr/binary, ")">>.

%% Template name conversion (Erlang atoms use _ but CLIPS uses -)
to_clips_template(<<"select_request">>) -> <<"select-request">>;
to_clips_template(<<"selection_result">>) -> <<"selection-result">>;
to_clips_template(<<"model_state">>) -> <<"model-state">>;
to_clips_template(<<"session_binding">>) -> <<"session-binding">>;
to_clips_template(<<"model_capability">>) -> <<"model-capability">>;
to_clips_template(<<"thinking_input">>) -> <<"thinking-input">>;
to_clips_template(<<"thinking_output">>) -> <<"thinking-output">>;
to_clips_template(<<"quota_state">>) -> <<"quota-state">>;
to_clips_template(<<"config_flag">>) -> <<"config-flag">>;
to_clips_template(<<"status_input">>) -> <<"status-input">>;
to_clips_template(<<"status_output">>) -> <<"status-output">>;
to_clips_template(<<"refresh_schedule">>) -> <<"refresh-schedule">>;
to_clips_template(<<"cooldown_policy">>) -> <<"cooldown-policy">>;
to_clips_template(<<"cloak_input">>) -> <<"cloak-input">>;
to_clips_template(<<"cloak_output">>) -> <<"cloak-output">>;
to_clips_template(<<"sensitive_word">>) -> <<"sensitive-word">>;
to_clips_template(<<"rewrite_tool_name">>) -> <<"rewrite-tool-name">>;
to_clips_template(<<"client_key_mapping">>) -> <<"client-key-mapping">>;
to_clips_template(<<"client_route_query">>) -> <<"client-route-query">>;
to_clips_template(<<"client_route_result">>) -> <<"client-route-result">>;
to_clips_template(<<"cooldown_query">>) -> <<"cooldown-query">>;
to_clips_template(<<"cooldown_result">>) -> <<"cooldown-result">>;
to_clips_template(Other) -> Other.

to_clips_slot(<<"cooldown_seconds">>) -> <<"cooldown-seconds">>;
to_clips_slot(<<"quota_fallback">>) -> <<"quota-fallback">>;
to_clips_slot(<<"interval_ms">>) -> <<"interval-ms">>;
to_clips_slot(<<"new_backoff_level">>) -> <<"new-backoff-level">>;
to_clips_slot(<<"user_agent">>) -> <<"user-agent">>;
to_clips_slot(<<"should_cloak">>) -> <<"should-cloak">>;
to_clips_slot(<<"client_key">>) -> <<"client-key">>;
to_clips_slot(<<"upstream_key">>) -> <<"upstream-key">>;
to_clips_slot(<<"session_id">>) -> <<"session-id">>;
to_clips_slot(<<"credential_id">>) -> <<"credential-id">>;
to_clips_slot(<<"request_id">>) -> <<"request-id">>;
to_clips_slot(<<"cooldown_until">>) -> <<"cooldown-until">>;
to_clips_slot(<<"backoff_level">>) -> <<"backoff-level">>;
to_clips_slot(<<"has_websocket">>) -> <<"has-websocket">>;
to_clips_slot(<<"need_websocket">>) -> <<"need-websocket">>;
to_clips_slot(<<"bound_at">>) -> <<"bound-at">>;
to_clips_slot(<<"status_code">>) -> <<"status-code">>;
to_clips_slot(<<"source_format">>) -> <<"source-format">>;
to_clips_slot(<<"target_format">>) -> <<"target-format">>;
to_clips_slot(<<"thinking_min">>) -> <<"thinking-min">>;
to_clips_slot(<<"thinking_max">>) -> <<"thinking-max">>;
to_clips_slot(<<"thinking_levels">>) -> <<"thinking-levels">>;
to_clips_slot(<<"thinking_mode">>) -> <<"thinking-mode">>;
to_clips_slot(<<"suffix_override">>) -> <<"suffix-override">>;
to_clips_slot(<<"recover_at">>) -> <<"recover-at">>;
to_clips_slot(Other) -> Other.

format_clips_value(V) when is_binary(V) -> <<"\"", V/binary, "\"">>;
format_clips_value(V) when is_integer(V) -> integer_to_binary(V);
format_clips_value(V) when is_float(V) -> float_to_binary(V, [{decimals, 6}]);
format_clips_value(true) -> <<"yes">>;
format_clips_value(false) -> <<"no">>;
format_clips_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
format_clips_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).
