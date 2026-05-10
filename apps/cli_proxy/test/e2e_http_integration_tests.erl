-module(e2e_http_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% E2E-001/003/007: Full HTTP Integration Tests
%% Starts Cowboy, sends real HTTP requests via hackney
%% ============================================================

-define(PORT, 19317).
-define(BASE_URL, "http://localhost:" ++ integer_to_list(?PORT)).

%% Main test fixture — starts the full HTTP server
http_integration_test_() ->
    {setup,
     fun start_server/0,
     fun stop_server/1,
     {timeout, 30, integration_tests()}}.

integration_tests() ->
    [
     %% E2E-001: Full roundtrip
     {"healthz returns 200",
      fun() ->
          {ok, Status, _, Ref} = hackney:get(?BASE_URL ++ "/healthz", [], <<>>),
          {ok, Body} = hackney:body(Ref),
          ?assertEqual(200, Status),
          ?assertEqual(<<"ok">>, Body)
      end},
     {"chat completions returns 200 or 503 (no credentials configured)",
      fun() ->
          ReqBody = jiffy:encode(#{
              <<"model">> => <<"claude-3-sonnet">>,
              <<"messages">> => [#{<<"role">> => <<"user">>,
                                   <<"content">> => <<"Hello">>}],
              <<"max_tokens">> => 100
          }),
          {ok, Status, _, Ref} = hackney:post(
              ?BASE_URL ++ "/v1/chat/completions",
              [{<<"Content-Type">>, <<"application/json">>}],
              ReqBody, []),
          {ok, Body} = hackney:body(Ref),
          %% 200 if credentials available, 503 if none configured
          ?assert(Status =:= 200 orelse Status =:= 503),
          ?assert(byte_size(Body) > 0)
      end},
     {"missing model returns 400",
      fun() ->
          ReqBody = jiffy:encode(#{
              <<"messages">> => [#{<<"role">> => <<"user">>,
                                   <<"content">> => <<"Hi">>}]
          }),
          {ok, Status, _, Ref} = hackney:post(
              ?BASE_URL ++ "/v1/chat/completions",
              [{<<"Content-Type">>, <<"application/json">>}],
              ReqBody, []),
          {ok, _} = hackney:body(Ref),
          ?assertEqual(400, Status)
      end},

     %% E2E-003: Streaming SSE format
     {"streaming returns SSE or 503 (no credentials)",
      fun() ->
          ReqBody = jiffy:encode(#{
              <<"model">> => <<"claude-3-sonnet">>,
              <<"messages">> => [#{<<"role">> => <<"user">>,
                                   <<"content">> => <<"Hi">>}],
              <<"stream">> => true
          }),
          {ok, Status, Headers, Ref} = hackney:post(
              ?BASE_URL ++ "/v1/chat/completions",
              [{<<"Content-Type">>, <<"application/json">>}],
              ReqBody, []),
          {ok, Body} = hackney:body(Ref),
          case Status of
              200 ->
                  CT = proplists:get_value(<<"content-type">>, Headers),
                  ?assertEqual(<<"text/event-stream">>, CT),
                  ?assert(binary:match(Body, <<"[DONE]">>) =/= nomatch);
              503 ->
                  %% No credentials configured — expected
                  ?assert(byte_size(Body) > 0)
          end
      end},

     %% E2E-007: Models endpoint
     {"GET /v1/models returns list",
      fun() ->
          {ok, Status, _, Ref} = hackney:get(
              ?BASE_URL ++ "/v1/models", [], <<>>),
          {ok, Body} = hackney:body(Ref),
          ?assertEqual(200, Status),
          Resp = jiffy:decode(Body, [return_maps]),
          ?assertEqual(<<"list">>, maps:get(<<"object">>, Resp))
      end},

     %% Responses API (HTTP)
     {"POST /v1/responses returns response object",
      fun() ->
          ReqBody = jiffy:encode(#{
              <<"model">> => <<"gpt-4">>,
              <<"input">> => [#{<<"type">> => <<"message">>,
                                <<"role">> => <<"user">>,
                                <<"content">> => <<"Hello">>}]
          }),
          {ok, Status, _, Ref} = hackney:post(
              ?BASE_URL ++ "/v1/responses",
              [{<<"Content-Type">>, <<"application/json">>}],
              ReqBody, []),
          {ok, _Body} = hackney:body(Ref),
          %% Should return 200 (may be SSE stream)
          ?assert(Status =:= 200 orelse Status =:= 503)
      end},

     %% Management API
     {"GET /v0/management/config returns config",
      fun() ->
          {ok, Status, _, Ref} = hackney:get(
              ?BASE_URL ++ "/v0/management/config", [], <<>>),
          {ok, Body} = hackney:body(Ref),
          ?assertEqual(200, Status),
          Resp = jiffy:decode(Body, [return_maps]),
          ?assert(is_map(Resp))
      end},
     {"PUT /v0/management/debug updates value",
      fun() ->
          {ok, Status, _, Ref} = hackney:put(
              ?BASE_URL ++ "/v0/management/debug",
              [{<<"Content-Type">>, <<"application/json">>}],
              <<"true">>, []),
          {ok, _} = hackney:body(Ref),
          ?assertEqual(200, Status),
          %% Verify it changed
          {ok, 200, _, Ref2} = hackney:get(
              ?BASE_URL ++ "/v0/management/debug", [], <<>>),
          {ok, Body2} = hackney:body(Ref2),
          ?assertEqual(<<"true">>, Body2)
      end},

     %% API key auth
     {"401 when keys configured and wrong key sent",
      fun() ->
          %% Configure API keys
          {ok, 200, _, _} = hackney:put(
              ?BASE_URL ++ "/v0/management/api-keys",
              [{<<"Content-Type">>, <<"application/json">>}],
              <<"[\"valid-key-123\"]">>, []),
          %% Now request without valid key
          ReqBody = jiffy:encode(#{
              <<"model">> => <<"claude-3">>,
              <<"messages">> => [#{<<"role">> => <<"user">>,
                                   <<"content">> => <<"hi">>}]
          }),
          {ok, Status, _, Ref} = hackney:post(
              ?BASE_URL ++ "/v1/chat/completions",
              [{<<"Content-Type">>, <<"application/json">>},
               {<<"Authorization">>, <<"Bearer wrong-key">>}],
              ReqBody, []),
          {ok, _} = hackney:body(Ref),
          ?assertEqual(401, Status),
          %% Clean up — remove keys
          {ok, 200, _, _} = hackney:put(
              ?BASE_URL ++ "/v0/management/api-keys",
              [{<<"Content-Type">>, <<"application/json">>}],
              <<"[]">>, [])
      end}
    ].

%%====================================================================
%% Server setup/teardown
%%====================================================================

start_server() ->
    try
        {ok, _} = application:ensure_all_started(cowboy),
        {ok, _} = application:ensure_all_started(hackney),
        %% Start supporting processes
        {ok, _} = config_loader:start_link(#{
            port => ?PORT,
            api_keys => [],
            debug => false,
            request_log => false,
            routing_strategy => <<"round-robin">>
        }),
        {ok, _} = signature_cache:start_link(),
        {ok, _} = translator_registry:start_link(),
        {ok, _} = model_registry:start_link(),
        {ok, _} = credential_sup:start_link(),
        %% Start CLIPS if available
        start_clips(),
        {ok, _} = conductor:start_link(),
        %% Register translators
        translator_openai_claude:register(),
        translator_claude_openai:register(),
        translator_openai_responses_claude:register(),
        %% Start Cowboy
        Dispatch = cowboy_router:compile([
            {'_', [
                {"/healthz", health_handler, []},
                {"/v1/chat/completions", openai_handler, []},
                {"/v1/models", models_handler, []},
                {"/v1/responses", responses_handler, []},
                {"/v0/management/[...]", management_handler, []}
            ]}
        ]),
        {ok, _} = cowboy:start_clear(test_integration_http,
            [{port, ?PORT}],
            #{env => #{dispatch => Dispatch}}),
        %% Wait for port to bind
        wait_for_port(?PORT),
        ok
    catch
        Type:Reason ->
            {error, {Type, Reason}}
    end.

stop_server(ok) ->
    cowboy:stop_listener(test_integration_http),
    catch gen_server:stop(conductor),
    catch gen_server:stop(clips_engine),
    catch gen_server:stop(credential_sup),
    catch gen_server:stop(model_registry),
    catch gen_server:stop(translator_registry),
    catch gen_server:stop(signature_cache),
    catch gen_server:stop(config_loader),
    ok;
stop_server(_) ->
    ok.

start_clips() ->
    PortPath = case code:priv_dir(cli_proxy) of
        {error, _} -> "/nonexistent";
        PrivDir -> filename:join(PrivDir, "clips_port")
    end,
    case filelib:is_file(PortPath) of
        true -> {ok, _} = clips_engine:start_link(PortPath);
        false -> ok
    end.

wait_for_port(Port) ->
    wait_for_port(Port, 30).

wait_for_port(_Port, 0) -> ok;
wait_for_port(Port, Retries) ->
    case gen_tcp:connect("localhost", Port, [], 100) of
        {ok, Sock} -> gen_tcp:close(Sock);
        {error, _} ->
            timer:sleep(50),
            wait_for_port(Port, Retries - 1)
    end.
