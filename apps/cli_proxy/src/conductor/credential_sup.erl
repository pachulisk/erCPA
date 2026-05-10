-module(credential_sup).
-behaviour(supervisor).

%% Dynamic supervisor for credential processes
%% Each credential is started as a child (simple_one_for_one)

-export([start_link/0, start_credential/1, stop_credential/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_credential(map()) -> {ok, pid()} | {error, term()}.
start_credential(Config) ->
    supervisor:start_child(?MODULE, [Config]).

-spec stop_credential(binary()) -> ok.
stop_credential(Id) ->
    ProcName = binary_to_atom(<<"cred_", Id/binary>>, utf8),
    case whereis(ProcName) of
        undefined -> ok;
        Pid -> supervisor:terminate_child(?MODULE, Pid)
    end.

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => credential_proc,
        start => {credential_proc, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [credential_proc]
    },
    {ok, {SupFlags, [ChildSpec]}}.
