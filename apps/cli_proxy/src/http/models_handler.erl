-module(models_handler).

%% Cowboy handler for GET /v1/models
%% Routes based on User-Agent: claude-cli → Claude format, others → OpenAI format

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            handle_get(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        _ ->
            Req = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req, State}
    end.

handle_get(Req0, State) ->
    UA = cowboy_req:header(<<"user-agent">>, Req0, <<>>),
    Format = detect_format(UA),
    Models = model_registry:get_available_models(Format),
    Response = format_response(Format, Models),
    Req = cowboy_req:reply(200, json_headers(),
        jiffy:encode(Response), Req0),
    {ok, Req, State}.

detect_format(<<"claude-cli", _/binary>>) -> claude;
detect_format(<<"claude_cli", _/binary>>) -> claude;
detect_format(<<"Claude", _/binary>>) -> claude;
detect_format(_) -> openai.

format_response(claude, Models) ->
    %% Claude format: {"data": [{"id": ..., "type": "model", ...}]}
    ClaudeModels = [format_claude_model(M) || M <- Models],
    #{<<"data">> => ClaudeModels};
format_response(openai, Models) ->
    #{<<"object">> => <<"list">>, <<"data">> => Models}.

format_claude_model(#{<<"id">> := Id} = M) ->
    #{<<"id">> => Id,
      <<"type">> => <<"model">>,
      <<"display_name">> => maps:get(<<"display_name">>, M, Id),
      <<"created_at">> => maps:get(<<"created">>, M, null)};
format_claude_model(M) -> M.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"GET, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"*">>
    }.
