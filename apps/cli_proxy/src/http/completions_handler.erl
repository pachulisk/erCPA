-module(completions_handler).

%% Cowboy handler for POST /v1/completions (legacy text completions)
%% Translates to chat/completions format internally

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_post(Req0, State);
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        _ ->
            Req = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    case access_control:authenticate(Req0) of
        {error, _} ->
            Req = cowboy_req:reply(401, json_headers(),
                jiffy:encode(#{<<"error">> => #{
                    <<"message">> => <<"Invalid API key">>,
                    <<"type">> => <<"invalid_api_key">>
                }}), Req0),
            {ok, Req, State};
        {ok, _} ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case jiffy:decode(Body, [return_maps]) of
                #{<<"model">> := Model, <<"prompt">> := Prompt} = Request ->
                    %% Convert legacy completions to chat format
                    ChatReq = #{
                        <<"model">> => Model,
                        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Prompt}],
                        <<"stream">> => maps:get(<<"stream">>, Request, false)
                    },
                    case conductor:execute(openai, Model, ChatReq) of
                        {ok, Response} ->
                            %% Convert chat response to legacy format
                            LegacyResp = to_legacy_format(Response),
                            Req = cowboy_req:reply(200, json_headers(),
                                jiffy:encode(LegacyResp), Req1),
                            {ok, Req, State};
                        {error, Status, ErrBody} when is_binary(ErrBody) ->
                            Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req1),
                            {ok, Req, State};
                        {error, Status, ErrMsg} ->
                            Req = cowboy_req:reply(Status, json_headers(),
                                jiffy:encode(#{<<"error">> => #{<<"message">> => ErrMsg}}), Req1),
                            {ok, Req, State}
                    end;
                _ ->
                    Req = cowboy_req:reply(400, json_headers(),
                        jiffy:encode(#{<<"error">> => #{<<"message">> => <<"model and prompt required">>}}), Req1),
                    {ok, Req, State}
            end
    end.

to_legacy_format(#{<<"choices">> := [#{<<"message">> := Msg} | _]} = Resp) ->
    Text = maps:get(<<"content">>, Msg, <<>>),
    Resp#{<<"choices">> => [#{
        <<"text">> => Text,
        <<"index">> => 0,
        <<"finish_reason">> => <<"stop">>
    }], <<"object">> => <<"text_completion">>};
to_legacy_format(Resp) ->
    Resp.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
