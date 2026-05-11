-module(models_handler).

%% Cowboy handler for GET /v1/models
%% Returns available model list in OpenAI format

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
    Models = model_registry:get_available_models(),
    Response = #{
        <<"object">> => <<"list">>,
        <<"data">> => Models
    },
    Req = cowboy_req:reply(200, json_headers(),
        jiffy:encode(Response), Req0),
    {ok, Req, State}.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"GET, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"*">>
    }.
