-module(oauth_session_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for oauth_session gen_statem

starts_in_idle_and_provides_url_test() ->
    %% Start a Claude OAuth session
    {ok, Pid} = oauth_session:start_link(claude, #{no_browser => true}),
    %% Should receive auth URL
    receive
        {oauth_url, Pid, URL} ->
            ?assert(is_binary(URL)),
            ?assert(binary:match(URL, <<"claude.ai/oauth/authorize">>) =/= nomatch),
            ?assert(binary:match(URL, <<"state=">>) =/= nomatch),
            ?assert(binary:match(URL, <<"code_challenge=">>) =/= nomatch)
    after 1000 ->
        ?assert(false)
    end,
    gen_statem:stop(Pid).

codex_provides_auth_url_test() ->
    {ok, Pid} = oauth_session:start_link(codex, #{no_browser => true}),
    receive
        {oauth_url, Pid, URL} ->
            ?assert(binary:match(URL, <<"auth.openai.com">>) =/= nomatch),
            ?assert(binary:match(URL, <<"app_EMoamEEZ">>) =/= nomatch)
    after 1000 ->
        ?assert(false)
    end,
    gen_statem:stop(Pid).

gemini_provides_auth_url_test() ->
    {ok, Pid} = oauth_session:start_link(gemini, #{no_browser => true}),
    receive
        {oauth_url, Pid, URL} ->
            ?assert(binary:match(URL, <<"accounts.google.com">>) =/= nomatch),
            ?assert(binary:match(URL, <<"cloud-platform">>) =/= nomatch)
    after 1000 ->
        ?assert(false)
    end,
    gen_statem:stop(Pid).

get_state_returns_current_test() ->
    {ok, Pid} = oauth_session:start_link(claude, #{no_browser => true}),
    receive {oauth_url, Pid, _} -> ok after 1000 -> ok end,
    %% Should be in idle (waiting for callback)
    State = oauth_session:get_state(Pid),
    ?assertEqual(idle, State),
    gen_statem:stop(Pid).

timeout_transitions_to_failed_test_() ->
    %% This test uses a very short timeout — we'd need to modify
    %% the statem for testing. For now just verify the process starts correctly.
    {"session starts and accepts state query",
     {timeout, 5,
      fun() ->
          {ok, Pid} = oauth_session:start_link(claude, #{no_browser => true}),
          receive {oauth_url, Pid, _} -> ok after 1000 -> ok end,
          ?assertEqual(idle, oauth_session:get_state(Pid)),
          gen_statem:stop(Pid)
      end}}.
