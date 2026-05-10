-module(signature_cache).
-behaviour(gen_server).

%% ETS-based signature cache with TTL sweep
%% Caches Claude thinking block signatures for reuse in multi-turn conversations

-export([
    start_link/0,
    cache/3,
    get/2,
    clear/0,
    clear/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, signature_cache_tab).
-define(TTL_SECONDS, 10800).          %% 3 hours
-define(CLEANUP_INTERVAL, 600000).    %% 10 minutes

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec cache(binary(), binary(), binary()) -> ok.
cache(ModelName, ThinkingText, Signature) ->
    case byte_size(Signature) >= 50 of
        true ->
            Group = model_group(ModelName),
            Hash = text_hash(ThinkingText),
            Now = erlang:system_time(second),
            ets:insert(?TABLE, {{Group, Hash}, Signature, Now}),
            ok;
        false ->
            ok
    end.

-spec get(binary(), binary()) -> {ok, binary()} | miss.
get(ModelName, ThinkingText) ->
    Group = model_group(ModelName),
    Hash = text_hash(ThinkingText),
    case ets:lookup(?TABLE, {Group, Hash}) of
        [{{_, _}, Sig, Ts}] ->
            Now = erlang:system_time(second),
            case Now - Ts =< ?TTL_SECONDS of
                true ->
                    %% Sliding TTL
                    ets:update_element(?TABLE, {Group, Hash}, {3, Now}),
                    {ok, Sig};
                false ->
                    ets:delete(?TABLE, {Group, Hash}),
                    miss
            end;
        [] ->
            miss
    end.

-spec clear() -> ok.
clear() ->
    ets:delete_all_objects(?TABLE),
    ok.

-spec clear(binary()) -> ok.
clear(ModelName) ->
    Group = model_group(ModelName),
    %% Delete all entries for this model group
    ets:match_delete(?TABLE, {{Group, '_'}, '_', '_'}),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?TABLE, [named_table, set, public, {read_concurrency, true}]),
    schedule_cleanup(),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    Now = erlang:system_time(second),
    Cutoff = Now - ?TTL_SECONDS,
    %% Select and delete expired entries
    Expired = ets:select(?TABLE, [
        {{'$1', '_', '$2'}, [{'<', '$2', Cutoff}], ['$1']}
    ]),
    lists:foreach(fun(Key) -> ets:delete(?TABLE, Key) end, Expired),
    schedule_cleanup(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).

model_group(<<"claude", _/binary>>) -> <<"claude">>;
model_group(<<"gpt", _/binary>>) -> <<"gpt">>;
model_group(<<"gemini", _/binary>>) -> <<"gemini">>;
model_group(Other) -> Other.

text_hash(Text) ->
    <<Hash:128, _/binary>> = crypto:hash(sha256, Text),
    integer_to_binary(Hash, 16).
