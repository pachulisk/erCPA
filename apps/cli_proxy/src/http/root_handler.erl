-module(root_handler).

%% Cowboy handler for GET / — returns available API endpoints

-export([init/2]).

init(Req0, State) ->
    Endpoints = #{
        <<"endpoints">> => [
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/chat/completions">>,
              <<"description">> => <<"OpenAI-compatible chat completions">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/completions">>,
              <<"description">> => <<"Legacy text completions">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/messages">>,
              <<"description">> => <<"Claude Messages API (native format)">>},
            #{<<"method">> => <<"GET">>,  <<"path">> => <<"/v1/models">>,
              <<"description">> => <<"List available models">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/messages/count_tokens">>,
              <<"description">> => <<"Count tokens for messages">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/images/generations">>,
              <<"description">> => <<"Image generation">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/images/edits">>,
              <<"description">> => <<"Image editing">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/responses">>,
              <<"description">> => <<"Responses API (streaming & non-streaming)">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1/responses/compact">>,
              <<"description">> => <<"Compact response format">>},
            #{<<"method">> => <<"GET">>,  <<"path">> => <<"/v1/ws/responses">>,
              <<"description">> => <<"WebSocket streaming responses">>},
            #{<<"method">> => <<"GET">>,  <<"path">> => <<"/v1/ws">>,
              <<"description">> => <<"WebSocket relay (provider proxy)">>},
            #{<<"method">> => <<"GET">>,  <<"path">> => <<"/v1beta/models">>,
              <<"description">> => <<"Gemini native model listing">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1beta/models/:model:generateContent">>,
              <<"description">> => <<"Gemini native generate">>},
            #{<<"method">> => <<"*">>,    <<"path">> => <<"/v0/management/*">>,
              <<"description">> => <<"Management API">>},
            #{<<"method">> => <<"POST">>, <<"path">> => <<"/v1internal:method">>,
              <<"description">> => <<"Gemini CLI internal protocol">>},
            #{<<"method">> => <<"GET">>,  <<"path">> => <<"/keep-alive">>,
              <<"description">> => <<"Keep-alive heartbeat">>},
            #{<<"method">> => <<"GET">>,  <<"path">> => <<"/healthz">>,
              <<"description">> => <<"Health check">>}
        ]
    },
    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>,
          <<"access-control-allow-origin">> => <<"*">>},
        jiffy:encode(Endpoints), Req0),
    {ok, Req, State}.
