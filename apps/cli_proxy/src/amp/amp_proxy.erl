-module(amp_proxy).

%% Reverse proxy to ampcode.com for AMP CLI integration
%% Handles: /api/* routes, Gemini bridge path translation

-export([proxy_request/2]).

-spec proxy_request(cowboy_req:req(), map()) ->
    {ok, cowboy_req:req(), term()} | {error, integer(), binary()}.
proxy_request(Req0, State) ->
    UpstreamURL = amp_config:get_upstream_url(),
    Path = cowboy_req:path(Req0),
    QS = cowboy_req:qs(Req0),
    Method = cowboy_req:method(Req0),

    TargetPath = maybe_gemini_bridge(Path),
    URL = case QS of
        <<>> -> <<UpstreamURL/binary, TargetPath/binary>>;
        _ -> <<UpstreamURL/binary, TargetPath/binary, "?", QS/binary>>
    end,

    %% Read request body
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    %% Build headers: strip client auth, inject upstream key
    Headers = build_proxy_headers(Req1),

    %% Forward request
    HackneyMethod = method_atom(Method),
    case hackney:request(HackneyMethod, URL, Headers, Body,
                         [{recv_timeout, 120000}]) of
        {ok, Status, RespHeaders, Ref} ->
            {ok, RespBody} = hackney:body(Ref),
            FinalBody = maybe_decompress(RespBody, RespHeaders),
            FilteredHeaders = filter_response_headers(RespHeaders),
            Req2 = cowboy_req:reply(Status, maps:from_list(FilteredHeaders),
                                    FinalBody, Req1),
            {ok, Req2, State};
        {error, Reason} ->
            {error, 502, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%%====================================================================
%% Internal
%%====================================================================

maybe_gemini_bridge(<<"/api/provider/gemini/", Rest/binary>>) ->
    %% Convert AMP Gemini path to standard format
    %% /api/provider/gemini/publishers/google/models/X:action → /models/X:action
    case binary:match(Rest, <<"/models/">>) of
        {Pos, _} ->
            <<"/", (binary:part(Rest, Pos, byte_size(Rest) - Pos))/binary>>;
        nomatch ->
            <<"/api/provider/gemini/", Rest/binary>>
    end;
maybe_gemini_bridge(Path) ->
    Path.

build_proxy_headers(Req) ->
    %% Strip client auth headers, inject upstream API key
    UpstreamKey = amp_config:get_upstream_api_key(),
    BaseHeaders = [
        {<<"content-type">>, cowboy_req:header(<<"content-type">>, Req, <<"application/json">>)},
        {<<"accept">>, cowboy_req:header(<<"accept">>, Req, <<"*/*">>)}
    ],
    case UpstreamKey of
        <<>> -> BaseHeaders;
        Key -> [{<<"authorization">>, <<"Bearer ", Key/binary>>} | BaseHeaders]
    end.

filter_response_headers(Headers) ->
    %% Remove hop-by-hop headers
    Skip = [<<"transfer-encoding">>, <<"connection">>, <<"keep-alive">>],
    [{K, V} || {K, V} <- Headers, not lists:member(string:lowercase(K), Skip)].

maybe_decompress(Body, Headers) ->
    CE = proplists:get_value(<<"content-encoding">>, Headers, <<>>),
    case CE of
        <<"gzip">> -> zlib:gunzip(Body);
        _ ->
            %% Check for gzip magic bytes without content-encoding
            case Body of
                <<16#1f, 16#8b, _/binary>> ->
                    try zlib:gunzip(Body) catch _:_ -> Body end;
                _ -> Body
            end
    end.

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"PUT">>) -> put;
method_atom(<<"DELETE">>) -> delete;
method_atom(<<"PATCH">>) -> patch;
method_atom(<<"OPTIONS">>) -> options;
method_atom(<<"HEAD">>) -> head;
method_atom(_) -> get.
