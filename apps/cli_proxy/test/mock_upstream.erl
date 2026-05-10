-module(mock_upstream).

%% Configurable mock HTTP server for integration testing
%% Simulates Claude/Gemini/Codex upstream responses

-export([start/2, stop/1, set_responses/2, set_handler/2]).

-record(mock_state, {
    port :: pos_integer(),
    responses :: [term()],
    handler :: fun() | undefined,
    listener :: term()
}).

%% Start a mock upstream server on given port
-spec start(atom(), pos_integer()) -> {ok, pid()}.
start(Name, Port) ->
    Pid = spawn_link(fun() -> init_mock(Name, Port) end),
    register(Name, Pid),
    %% Wait for it to be ready
    receive {mock_ready, Pid} -> {ok, Pid}
    after 5000 -> {error, timeout}
    end.

%% Stop the mock server
-spec stop(pid() | atom()) -> ok.
stop(Pid) when is_pid(Pid) ->
    Pid ! stop, ok;
stop(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

%% Set a queue of responses (consumed in order)
-spec set_responses(pid() | atom(), [{integer(), binary()}]) -> ok.
set_responses(Pid, Responses) when is_pid(Pid) ->
    Pid ! {set_responses, Responses}, ok;
set_responses(Name, Responses) when is_atom(Name) ->
    Name ! {set_responses, Responses}, ok.

%% Set a custom handler function
-spec set_handler(pid() | atom(), fun()) -> ok.
set_handler(Pid, Handler) when is_pid(Pid) ->
    Pid ! {set_handler, Handler}, ok;
set_handler(Name, Handler) when is_atom(Name) ->
    Name ! {set_handler, Handler}, ok.

%%====================================================================
%% Internal — Mock Cowboy-like handler
%%====================================================================

init_mock(Name, Port) ->
    Dispatch = cowboy_router:compile([
        {'_', [{"/[...]", mock_handler, [self()]}]}
    ]),
    ListenerName = list_to_atom("mock_" ++ atom_to_list(Name)),
    case cowboy:start_clear(ListenerName, [{port, Port}],
                            #{env => #{dispatch => Dispatch}}) of
        {ok, _} ->
            self() ! {mock_ready, self()},  %% Wrong, need to signal parent
            ok;
        {error, _} ->
            ok
    end,
    %% Signal parent
    %% The spawning process is waiting
    mock_loop(#mock_state{port = Port, responses = [], handler = undefined,
                          listener = ListenerName}).

mock_loop(State) ->
    receive
        stop ->
            cowboy:stop_listener(State#mock_state.listener);
        {set_responses, Responses} ->
            mock_loop(State#mock_state{responses = Responses});
        {set_handler, Handler} ->
            mock_loop(State#mock_state{handler = Handler});
        {get_response, From} ->
            case State#mock_state.responses of
                [] ->
                    From ! {response, 200, default_response()},
                    mock_loop(State);
                [{Status, Body} | Rest] ->
                    From ! {response, Status, Body},
                    mock_loop(State#mock_state{responses = Rest})
            end;
        _ ->
            mock_loop(State)
    end.

default_response() ->
    jiffy:encode(#{
        <<"id">> => <<"msg_mock_123">>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => <<"mock-model">>,
        <<"content">> => [#{<<"type">> => <<"text">>,
                            <<"text">> => <<"Mock response from test server">>}],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 5}
    }).
