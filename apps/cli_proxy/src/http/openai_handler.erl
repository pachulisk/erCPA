-module(openai_handler).

%% Cowboy handler for POST /v1/chat/completions
%% Handles both streaming (SSE) and non-streaming responses

-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"POST">> ->
            handle_post(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        _ ->
            Req = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    %% Auth check
    case access_control:authenticate(Req0) of
        {error, _Reason} ->
            Req = cowboy_req:reply(401, json_headers(),
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"Invalid API key">>,
                    <<"type">> => <<"invalid_api_key">>
                }}), Req0),
            {ok, Req, State};
        {ok, _Principal} ->
            handle_authenticated(Req0, State)
    end.

handle_authenticated(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case jiffy:decode(Body, [return_maps]) of
        Request when is_map(Request) ->
            Model = maps:get(<<"model">>, Request, <<>>),
            Stream = maps:get(<<"stream">>, Request, false),
            case Stream of
                true -> handle_stream(Model, Request, Req1, State);
                false -> handle_nonstream(Model, Request, Req1, State)
            end;
        _ ->
            Req = cowboy_req:reply(400, json_headers(),
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"Invalid JSON body">>,
                    <<"type">> => <<"invalid_request_error">>
                }}), Req1),
            {ok, Req, State}
    end.

handle_nonstream(Model, _Request, Req0, State) ->
    %% TODO: Wire to conductor for credential selection + executor
    %% For now, return a placeholder that validates the pipeline
    case Model of
        <<>> ->
            Req = cowboy_req:reply(400, json_headers(),
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"model is required">>,
                    <<"type">> => <<"invalid_request_error">>
                }}), Req0),
            {ok, Req, State};
        _ ->
            %% Placeholder response — will be replaced with conductor call
            Response = #{
                <<"id">> => generate_id(),
                <<"object">> => <<"chat.completion">>,
                <<"created">> => erlang:system_time(second),
                <<"model">> => Model,
                <<"choices">> => [#{
                    <<"index">> => 0,
                    <<"message">> => #{
                        <<"role">> => <<"assistant">>,
                        <<"content">> => <<"[erCPA proxy: not yet connected to upstream]">>
                    },
                    <<"finish_reason">> => <<"stop">>
                }],
                <<"usage">> => #{
                    <<"prompt_tokens">> => 0,
                    <<"completion_tokens">> => 0,
                    <<"total_tokens">> => 0
                }
            },
            Req = cowboy_req:reply(200, json_headers(),
                jiffy:encode(Response), Req0),
            {ok, Req, State}
    end.

handle_stream(Model, _Request, Req0, State) ->
    case Model of
        <<>> ->
            Req = cowboy_req:reply(400, json_headers(),
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"model is required">>,
                    <<"type">> => <<"invalid_request_error">>
                }}), Req0),
            {ok, Req, State};
        _ ->
            %% Start SSE stream
            Headers = maps:merge(cors_headers(), #{
                <<"content-type">> => <<"text/event-stream">>,
                <<"cache-control">> => <<"no-cache">>,
                <<"connection">> => <<"keep-alive">>
            }),
            Req1 = cowboy_req:stream_reply(200, Headers, Req0),
            %% Send a placeholder chunk — will be replaced with real streaming
            Chunk = #{
                <<"id">> => generate_id(),
                <<"object">> => <<"chat.completion.chunk">>,
                <<"created">> => erlang:system_time(second),
                <<"model">> => Model,
                <<"choices">> => [#{
                    <<"index">> => 0,
                    <<"delta">> => #{<<"role">> => <<"assistant">>,
                                     <<"content">> => <<"[erCPA: streaming placeholder]">>},
                    <<"finish_reason">> => <<"stop">>
                }]
            },
            cowboy_req:stream_body(
                iolist_to_binary(sse_parser:format_event(Chunk)), nofin, Req1),
            cowboy_req:stream_body(sse_parser:format_done(), fin, Req1),
            {ok, Req1, State}
    end.

%%====================================================================
%% Internal
%%====================================================================

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"GET, POST, PUT, PATCH, DELETE, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"*">>
    }.

generate_id() ->
    <<"chatcmpl-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
