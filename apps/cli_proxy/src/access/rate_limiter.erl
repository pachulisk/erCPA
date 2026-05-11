-module(rate_limiter).
-behaviour(gen_server).

%% Per-IP sliding window rate limiter using ETS
%% Configurable via config_loader: rate_limit_rpm (requests per minute)

-export([
    start_link/0,
    check/1,
    get_config/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, rate_limiter_tab).
-define(CLEANUP_INTERVAL, 60000). %% 60s

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Check if a request from IP is allowed
-spec check(inet:ip_address()) -> ok | {error, rate_limited}.
check(IP) ->
    case get_limit() of
        0 -> ok; %% 0 = disabled
        Limit ->
            Key = ip_to_key(IP),
            Now = erlang:system_time(second),
            WindowStart = Now - 60,
            %% Count requests in last 60 seconds
            case ets:lookup(?TAB, Key) of
                [{Key, Timestamps}] ->
                    Recent = [T || T <- Timestamps, T > WindowStart],
                    case length(Recent) >= Limit of
                        true ->
                            {error, rate_limited};
                        false ->
                            ets:insert(?TAB, {Key, [Now | Recent]}),
                            ok
                    end;
                [] ->
                    ets:insert(?TAB, {Key, [Now]}),
                    ok
            end
    end.

-spec get_config() -> map().
get_config() ->
    #{rpm => get_limit()}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?TAB, [named_table, public, set, {write_concurrency, true}]),
    schedule_cleanup(),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    cleanup_expired(),
    schedule_cleanup(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

get_limit() ->
    case config_loader:get(rate_limit_rpm) of
        undefined -> 0;
        V when is_integer(V) -> V;
        _ -> 0
    end.

ip_to_key(IP) when is_tuple(IP) ->
    list_to_binary(inet:ntoa(IP));
ip_to_key(IP) when is_binary(IP) ->
    IP.

cleanup_expired() ->
    Now = erlang:system_time(second),
    WindowStart = Now - 60,
    ets:foldl(fun({Key, Timestamps}, _Acc) ->
        Recent = [T || T <- Timestamps, T > WindowStart],
        case Recent of
            [] -> ets:delete(?TAB, Key);
            _ -> ets:insert(?TAB, {Key, Recent})
        end,
        ok
    end, ok, ?TAB).

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).
