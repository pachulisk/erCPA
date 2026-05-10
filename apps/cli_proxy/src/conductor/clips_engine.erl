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
            {ok, #state{port = Port, port_path = PortPath}};
        {error, Reason} ->
            {stop, Reason}
    end.

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
                          <<"template">> => to_bin(Template),
                          <<"slot">> => SlotName,
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
    jiffy:encode(#{<<"op">> => <<"assert">>,
                   <<"fact">> => [to_bin(TemplateName), Fields]});
encode_assert(Fact) when is_map(Fact) ->
    jiffy:encode(#{<<"op">> => <<"assert">>, <<"fact">> => Fact}).

to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
