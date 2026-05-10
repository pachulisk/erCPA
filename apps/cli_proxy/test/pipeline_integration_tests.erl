-module(pipeline_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% Pipeline Integration Tests
%% Tests the full request pipeline without HTTP:
%%   Request → Translator → (mock executor) → Translator → Response
%% ============================================================

%% Test the translator registry + translation pipeline

openai_to_claude_pipeline_test_() ->
    {setup,
     fun() ->
         {ok, _} = translator_registry:start_link(),
         translator_openai_claude:register(),
         translator_claude_openai:register(),
         ok
     end,
     fun(_) -> gen_server:stop(translator_registry) end,
     [
      {"translate request openai → claude",
       fun() ->
           Input = #{
               <<"model">> => <<"claude-3-sonnet">>,
               <<"messages">> => [
                   #{<<"role">> => <<"system">>, <<"content">> => <<"Be brief">>},
                   #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
               ],
               <<"max_tokens">> => 100
           },
           Result = translator_registry:translate_request(openai, claude,
               <<"claude-3-sonnet">>, Input, false),
           %% Should have system extracted
           ?assertEqual(<<"Be brief">>, maps:get(<<"system">>, Result)),
           %% Should have user message
           [Msg] = maps:get(<<"messages">>, Result),
           ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg))
       end},
      {"translate response claude → openai (nonstream)",
       fun() ->
           ClaudeResp = #{
               <<"id">> => <<"msg_1">>,
               <<"model">> => <<"claude-3">>,
               <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"World">>}],
               <<"stop_reason">> => <<"end_turn">>,
               <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 3}
           },
           %% Response translator: (openai, claude) module handles Claude→OpenAI responses
           Result = translator_openai_claude:response_nonstream(ClaudeResp),
           ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Result)),
           [Choice] = maps:get(<<"choices">>, Result),
           ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice))
       end},
      {"passthrough when no translator registered",
       fun() ->
           Input = #{<<"model">> => <<"test">>, <<"data">> => <<"pass">>},
           Result = translator_registry:translate_request(unknown, unknown,
               <<"test">>, Input, false),
           ?assertEqual(Input, Result)
       end}
     ]}.

%% Test full translation chain: OpenAI → Gemini → back

openai_gemini_roundtrip_test_() ->
    {setup,
     fun() ->
         {ok, _} = translator_registry:start_link(),
         translator_openai_gemini:register(),
         translator_gemini_openai:register(),
         ok
     end,
     fun(_) -> gen_server:stop(translator_registry) end,
     [
      {"full roundtrip preserves model field",
       fun() ->
           Input = #{
               <<"model">> => <<"gemini-pro">>,
               <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"test">>}],
               <<"max_tokens">> => 200,
               <<"temperature">> => 0.5
           },
           %% OpenAI → Gemini
           Gemini = translator_registry:translate_request(openai, gemini,
               <<"gemini-pro">>, Input, false),
           ?assert(maps:is_key(<<"contents">>, Gemini)),
           GenConfig = maps:get(<<"generationConfig">>, Gemini),
           ?assertEqual(200, maps:get(<<"maxOutputTokens">>, GenConfig)),
           %% Gemini → OpenAI
           Back = translator_registry:translate_request(gemini, openai,
               <<"gpt-4">>, Gemini, false),
           ?assert(maps:is_key(<<"messages">>, Back)),
           ?assertEqual(200, maps:get(<<"max_tokens">>, Back))
       end}
     ]}.

%% Test codex → claude translation pipeline

codex_claude_pipeline_test_() ->
    {setup,
     fun() ->
         {ok, _} = translator_registry:start_link(),
         translator_codex_claude:register(),
         ok
     end,
     fun(_) -> gen_server:stop(translator_registry) end,
     [
      {"codex responses format → claude messages",
       fun() ->
           Input = #{
               <<"model">> => <<"claude-3">>,
               <<"instructions">> => <<"You are a coder">>,
               <<"input">> => [
                   #{<<"type">> => <<"message">>, <<"role">> => <<"user">>,
                     <<"content">> => <<"Write hello world">>}
               ],
               <<"max_output_tokens">> => 2048
           },
           Result = translator_registry:translate_request(codex, claude,
               <<"claude-3">>, Input, false),
           ?assertEqual(<<"You are a coder">>, maps:get(<<"system">>, Result)),
           ?assertEqual(2048, maps:get(<<"max_tokens">>, Result)),
           [Msg] = maps:get(<<"messages">>, Result),
           ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg))
       end}
     ]}.

%% Test thinking module integration

thinking_suffix_integration_test() ->
    {BaseModel, Suffix} = thinking:parse_suffix(<<"claude-budget-model(8192)">>),
    ?assertEqual(<<"claude-budget-model">>, BaseModel),
    ?assertEqual(<<"8192">>, Suffix),
    ModelDef = thinking_test_models:get(BaseModel),
    ?assert(ModelDef =/= undefined),
    Body = #{<<"model">> => BaseModel},
    Result = thinking:apply_thinking(Body, BaseModel, Suffix, ModelDef, claude),
    ?assert(maps:is_key(<<"thinking">>, Result)),
    Thinking = maps:get(<<"thinking">>, Result),
    ?assertEqual(8192, maps:get(<<"budget_tokens">>, Thinking)).

thinking_level_suffix_integration_test() ->
    {BaseModel, Suffix} = thinking:parse_suffix(<<"level-model(high)">>),
    ModelDef = thinking_test_models:get(BaseModel),
    Body = #{<<"model">> => BaseModel},
    Result = thinking:apply_thinking(Body, BaseModel, Suffix, ModelDef, claude),
    ?assertEqual(<<"high">>, maps:get(<<"reasoning_effort">>, Result)).

%% Test credential_proc → conductor integration shape

credential_proc_integration_test_() ->
    {"credential process lifecycle integrates with selection",
     {timeout, 5,
      fun() ->
          {ok, Pid} = credential_proc:start_link(#{
              id => <<"int-test-cred">>,
              provider => claude,
              metadata => #{<<"access_token">> => <<"test">>}
          }),
          %% Available
          ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
          %% Mark 429
          credential_proc:mark_result(Pid, <<"claude-3">>, 429),
          ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>)),
          %% Mark success clears
          credential_proc:mark_result(Pid, <<"claude-3">>, 200),
          ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
          credential_proc:stop(Pid)
      end}}.

%% Test config_loader → payload_rules integration

config_payload_integration_test_() ->
    {setup,
     fun() ->
         {ok, _} = config_loader:start_link(#{
             payload => #{
                 override => [#{
                     models => [#{name => <<"*">>, protocol => <<>>}],
                     params => #{<<"user">> => <<"proxy">>}
                 }]
             }
         }),
         ok
     end,
     fun(_) -> gen_server:stop(config_loader) end,
     [
      {"payload rules applied from config",
       fun() ->
           PayloadConfig = config_loader:get(payload, #{}),
           Body = #{<<"model">> => <<"gpt-4">>, <<"messages">> => []},
           Result = payload_rules:apply_rules(Body, <<"gpt-4">>, openai, PayloadConfig),
           ?assertEqual(<<"proxy">>, maps:get(<<"user">>, Result))
       end}
     ]}.

%% Signature cache integration

signature_roundtrip_test_() ->
    {setup,
     fun() -> {ok, _} = signature_cache:start_link(), ok end,
     fun(_) -> gen_server:stop(signature_cache) end,
     [
      {"cache → get roundtrip across model variants",
       fun() ->
           Sig = binary:copy(<<"X">>, 64),
           Text = <<"Let me think about this carefully...">>,
           signature_cache:cache(<<"claude-3-sonnet">>, Text, Sig),
           %% Same model group, different variant
           ?assertEqual({ok, Sig}, signature_cache:get(<<"claude-3-opus">>, Text)),
           %% Different group
           ?assertEqual(miss, signature_cache:get(<<"gpt-4">>, Text))
       end}
     ]}.
