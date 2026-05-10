-module(module_coverage_tests).
-include_lib("eunit/include/eunit.hrl").

%% ============================================================
%% E2E-010: Module export coverage verification
%% Ensures all key modules export expected functions
%% ============================================================

%% Conductor exports

conductor_exports_test() ->
    ?assert(erlang:function_exported(conductor, start_link, 0)),
    ?assert(erlang:function_exported(conductor, execute, 3)),
    ?assert(erlang:function_exported(conductor, execute, 4)),
    ?assert(erlang:function_exported(conductor, select_credential, 2)).

%% Credential process exports

credential_proc_exports_test() ->
    ?assert(erlang:function_exported(credential_proc, start_link, 1)),
    ?assert(erlang:function_exported(credential_proc, get_status, 2)),
    ?assert(erlang:function_exported(credential_proc, mark_result, 3)),
    ?assert(erlang:function_exported(credential_proc, disable, 1)),
    ?assert(erlang:function_exported(credential_proc, enable, 1)),
    ?assert(erlang:function_exported(credential_proc, get_metadata, 2)).

%% CLIPS engine exports

clips_engine_exports_test() ->
    ?assert(erlang:function_exported(clips_engine, start_link, 0)),
    ?assert(erlang:function_exported(clips_engine, assert, 1)),
    ?assert(erlang:function_exported(clips_engine, retract, 1)),
    ?assert(erlang:function_exported(clips_engine, run, 0)),
    ?assert(erlang:function_exported(clips_engine, query, 2)),
    ?assert(erlang:function_exported(clips_engine, reset, 0)),
    ?assert(erlang:function_exported(clips_engine, load, 1)).

%% Translator exports

translator_exports_test() ->
    Translators = [
        translator_openai_claude,
        translator_claude_openai,
        translator_openai_gemini,
        translator_gemini_openai,
        translator_gemini_claude,
        translator_claude_gemini,
        translator_codex_claude,
        translator_codex_openai,
        translator_openai_responses_claude
    ],
    lists:foreach(fun(Mod) ->
        ?assert(erlang:function_exported(Mod, request, 3),
            io_lib:format("~s missing request/3", [Mod])),
        ?assert(erlang:function_exported(Mod, response_stream, 2),
            io_lib:format("~s missing response_stream/2", [Mod])),
        ?assert(erlang:function_exported(Mod, response_nonstream, 1),
            io_lib:format("~s missing response_nonstream/1", [Mod])),
        ?assert(erlang:function_exported(Mod, init_acc, 0),
            io_lib:format("~s missing init_acc/0", [Mod])),
        ?assert(erlang:function_exported(Mod, register, 0),
            io_lib:format("~s missing register/0", [Mod]))
    end, Translators).

%% Executor exports

executor_exports_test() ->
    Executors = [
        claude_executor,
        codex_executor,
        gemini_executor,
        vertex_executor,
        antigravity_executor,
        kimi_executor,
        openai_compat_executor,
        aistudio_executor
    ],
    lists:foreach(fun(Mod) ->
        ?assert(erlang:function_exported(Mod, start_link, 1),
            io_lib:format("~s missing start_link/1", [Mod])),
        ?assert(erlang:function_exported(Mod, execute, 4),
            io_lib:format("~s missing execute/4", [Mod])),
        ?assert(erlang:function_exported(Mod, execute_stream, 4),
            io_lib:format("~s missing execute_stream/4", [Mod]))
    end, Executors).

%% OAuth exports

oauth_exports_test() ->
    OAuthModules = [oauth_claude, oauth_codex, oauth_gemini],
    lists:foreach(fun(Mod) ->
        ?assert(erlang:function_exported(Mod, auth_url, 2),
            io_lib:format("~s missing auth_url/2", [Mod])),
        ?assert(erlang:function_exported(Mod, exchange, 3),
            io_lib:format("~s missing exchange/3", [Mod])),
        ?assert(erlang:function_exported(Mod, refresh, 1),
            io_lib:format("~s missing refresh/1", [Mod]))
    end, OAuthModules).

%% Config/storage exports

config_exports_test() ->
    ?assert(erlang:function_exported(config_loader, get, 1)),
    ?assert(erlang:function_exported(config_loader, get, 2)),
    ?assert(erlang:function_exported(config_loader, get_all, 0)),
    ?assert(erlang:function_exported(config_loader, apply_config, 1)),
    ?assert(erlang:function_exported(config_loader, update_api_keys, 1)).

storage_exports_test() ->
    ?assert(erlang:function_exported(auth_store, load_all, 0)),
    ?assert(erlang:function_exported(auth_store, save, 2)),
    ?assert(erlang:function_exported(auth_store, update, 2)),
    ?assert(erlang:function_exported(auth_store, delete, 1)),
    ?assert(erlang:function_exported(file_store, load_all, 0)),
    ?assert(erlang:function_exported(file_store, save, 2)).

%% Utility exports

utility_exports_test() ->
    ?assert(erlang:function_exported(sse_parser, parse, 1)),
    ?assert(erlang:function_exported(sse_parser, format_event, 1)),
    ?assert(erlang:function_exported(sse_parser, format_done, 0)),
    ?assert(erlang:function_exported(signature_cache, cache, 3)),
    ?assert(erlang:function_exported(signature_cache, get, 2)),
    ?assert(erlang:function_exported(thinking, parse_suffix, 1)),
    ?assert(erlang:function_exported(thinking, clamp_budget, 4)),
    ?assert(erlang:function_exported(payload_rules, apply_rules, 4)),
    ?assert(erlang:function_exported(access_control, authenticate, 1)),
    ?assert(erlang:function_exported(browser, open_url, 1)),
    ?assert(erlang:function_exported(stream_keepalive, start, 1)).

%% Handler exports

handler_exports_test() ->
    Handlers = [
        openai_handler,
        health_handler,
        models_handler,
        responses_handler,
        responses_compact_handler,
        responses_ws_handler,
        management_handler,
        oauth_callback_handler,
        amp_handler
    ],
    lists:foreach(fun(Mod) ->
        ?assert(erlang:function_exported(Mod, init, 2),
            io_lib:format("~s missing init/2", [Mod]))
    end, Handlers).

%% Model registry exports

model_registry_exports_test() ->
    ?assert(erlang:function_exported(model_registry, start_link, 0)),
    ?assert(erlang:function_exported(model_registry, register_client, 3)),
    ?assert(erlang:function_exported(model_registry, unregister_client, 1)),
    ?assert(erlang:function_exported(model_registry, get_available_models, 0)),
    ?assert(erlang:function_exported(model_registry, is_model_available, 1)),
    ?assert(erlang:function_exported(model_registry, get_model_info, 1)).
