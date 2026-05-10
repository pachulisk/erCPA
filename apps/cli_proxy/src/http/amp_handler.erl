-module(amp_handler).

%% Cowboy handler for Amp CLI routing
%% Routes to local providers or upstream ampcode.com

-export([init/2]).

init(Req0, State) ->
    case amp_config:is_enabled() of
        false ->
            Req = cowboy_req:reply(404, #{}, <<"Amp module not enabled">>, Req0),
            {ok, Req, State};
        true ->
            route(Req0, State)
    end.

route(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        <<"POST">> ->
            handle_post(Req0, State);
        _ ->
            Req = cowboy_req:reply(405, #{}, <<"Method Not Allowed">>, Req0),
            {ok, Req, State}
    end.

handle_post(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Request = jiffy:decode(Body, [return_maps]),
    Model = maps:get(<<"model">>, Request, <<>>),

    case amp_model_mapper:resolve(Model) of
        {local, _Provider, ResolvedModel} ->
            %% Handle locally via conductor
            case conductor:execute(openai, ResolvedModel, Request) of
                {ok, Response} ->
                    Req = cowboy_req:reply(200, json_headers(),
                        jiffy:encode(Response), Req1),
                    {ok, Req, State};
                {error, Status, ErrBody} ->
                    Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req1),
                    {ok, Req, State}
            end;
        {mapped, OriginalModel, MappedModel} ->
            %% Local with response rewriting
            MappedReq = Request#{<<"model">> => MappedModel},
            case conductor:execute(openai, MappedModel, MappedReq) of
                {ok, Response} ->
                    %% Rewrite model name back to original
                    Rewritten = Response#{<<"model">> => OriginalModel},
                    Req = cowboy_req:reply(200, json_headers(),
                        jiffy:encode(Rewritten), Req1),
                    {ok, Req, State};
                {error, Status, ErrBody} ->
                    Req = cowboy_req:reply(Status, json_headers(), ErrBody, Req1),
                    {ok, Req, State}
            end;
        upstream ->
            %% Forward to ampcode.com
            forward_upstream(Request, Req1, State)
    end.

forward_upstream(Request, Req0, State) ->
    case amp_config:get_upstream_url() of
        undefined ->
            Req = cowboy_req:reply(502, json_headers(),
                jiffy:encode(#{<<"error">> => <<"no upstream configured">>}), Req0),
            {ok, Req, State};
        UpstreamURL ->
            ClientKey = extract_client_key(Req0),
            UpstreamKey = amp_config:resolve_upstream_key(ClientKey),
            URL = <<UpstreamURL/binary, "/v1/chat/completions">>,
            Headers = [{<<"Content-Type">>, <<"application/json">>},
                       {<<"Authorization">>, <<"Bearer ", UpstreamKey/binary>>}],
            Body = jiffy:encode(Request),
            case hackney:post(URL, Headers, Body, [{recv_timeout, 120000}]) of
                {ok, Status, _RH, Ref} ->
                    {ok, RespBody} = hackney:body(Ref),
                    Req = cowboy_req:reply(Status, json_headers(), RespBody, Req0),
                    {ok, Req, State};
                {error, _Reason} ->
                    Req = cowboy_req:reply(502, json_headers(),
                        jiffy:encode(#{<<"error">> => <<"upstream unavailable">>}), Req0),
                    {ok, Req, State}
            end
    end.

extract_client_key(Req) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Key/binary>> -> Key;
        _ -> <<>>
    end.

json_headers() ->
    maps:merge(cors_headers(), #{<<"content-type">> => <<"application/json">>}).

cors_headers() ->
    #{<<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"POST, OPTIONS">>,
      <<"access-control-allow-headers">> => <<"*">>}.
