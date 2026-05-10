-module(home_config).
-behaviour(gen_server).

%% Home-side config broadcaster
%% Pushes config changes to all connected satellite nodes

-export([start_link/0, broadcast/1, get_config/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec broadcast(map()) -> ok.
broadcast(Config) ->
    gen_server:cast(?MODULE, {broadcast, Config}).

-spec get_config() -> map().
get_config() ->
    gen_server:call(?MODULE, get_config).

init([]) ->
    Config = config_loader:get_all(),
    {ok, #{config => Config}}.

handle_call(get_config, _From, #{config := Config} = State) ->
    {reply, Config, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast({broadcast, NewConfig}, State) ->
    %% Notify all connected satellite nodes
    Nodes = nodes(),
    lists:foreach(fun(Node) ->
        erlang:send({home_client, Node}, {config_updated, NewConfig}, [noconnect])
    end, Nodes),
    {noreply, State#{config => NewConfig}};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.
