-module(cli_proxy_cli).

%% CLI argument parsing
%% Maps command-line flags to application actions

-export([parse_args/1, run_action/1]).

-spec parse_args([string()]) -> map().
parse_args(Args) ->
    parse_args(Args, #{}).

parse_args([], Acc) -> Acc;
parse_args(["--login", Provider | Rest], Acc) ->
    parse_args(Rest, Acc#{login => list_to_atom(Provider)});
parse_args(["--config", Path | Rest], Acc) ->
    parse_args(Rest, Acc#{config => Path});
parse_args(["--password", PW | Rest], Acc) ->
    parse_args(Rest, Acc#{password => list_to_binary(PW)});
parse_args(["--home", Addr | Rest], Acc) ->
    parse_args(Rest, Acc#{home => list_to_atom(Addr)});
parse_args(["--port", Port | Rest], Acc) ->
    parse_args(Rest, Acc#{port => list_to_integer(Port)});
parse_args(["--callback-port", Port | Rest], Acc) ->
    parse_args(Rest, Acc#{callback_port => list_to_integer(Port)});
parse_args(["--no-browser" | Rest], Acc) ->
    parse_args(Rest, Acc#{no_browser => true});
parse_args(["--tui" | Rest], Acc) ->
    parse_args(Rest, Acc#{tui => true});
parse_args(["--local-models" | Rest], Acc) ->
    parse_args(Rest, Acc#{local_models => true});
parse_args(["--vertex-import", File | Rest], Acc) ->
    parse_args(Rest, Acc#{vertex_import => list_to_binary(File)});
parse_args([_ | Rest], Acc) ->
    parse_args(Rest, Acc).

-spec run_action(map()) -> ok | {start, map()}.
run_action(#{login := Provider} = Args) ->
    Config = #{no_browser => maps:get(no_browser, Args, false)},
    {ok, _Pid} = oauth_session:start_link(Provider, Config),
    receive
        {oauth_url, _, URL} ->
            io:format("Open this URL to login:~n~s~n", [URL]),
            wait_for_completion();
        {oauth_device_code, _, UserCode, VerifyURL} ->
            io:format("Go to ~s and enter code: ~s~n", [VerifyURL, UserCode]),
            wait_for_completion();
        {oauth_error, _, Reason} ->
            io:format("Login failed: ~p~n", [Reason])
    after 5000 ->
        io:format("Login timeout~n")
    end,
    ok;

run_action(#{vertex_import := File}) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Data = jiffy:decode(Bin, [return_maps]),
            ProjectId = maps:get(<<"project_id">>, Data, <<>>),
            Email = maps:get(<<"client_email">>, Data, <<>>),
            TokenData = #{
                <<"type">> => <<"vertex">>,
                <<"service_account">> => Data,
                <<"project_id">> => ProjectId,
                <<"email">> => Email
            },
            ok = auth_store:save(vertex, TokenData),
            io:format("Vertex service account imported: ~s (~s)~n", [Email, ProjectId]);
        {error, Reason} ->
            io:format("Failed to read file: ~p~n", [Reason])
    end,
    ok;

run_action(Args) ->
    %% Normal server start
    {start, Args}.

wait_for_completion() ->
    receive
        {oauth_complete, _, ok} ->
            io:format("Login successful!~n");
        {oauth_error, _, Reason} ->
            io:format("Login failed: ~p~n", [Reason])
    after 300000 ->
        io:format("Login timeout (5 minutes)~n")
    end.
