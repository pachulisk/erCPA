-module(management_panel_handler).

%% Cowboy handler for GET /management.html
%% Serves the management control panel SPA

-export([init/2]).

init(Req0, State) ->
    case config_loader:get(disable_control_panel, false) of
        true ->
            Req = cowboy_req:reply(403,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Control panel disabled">>, Req0),
            {ok, Req, State};
        false ->
            case management_panel:get_html() of
                {ok, Html} ->
                    Req = cowboy_req:reply(200,
                        #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                          <<"cache-control">> => <<"no-cache">>},
                        Html, Req0),
                    {ok, Req, State};
                {error, not_found} ->
                    %% Try to download now
                    management_panel:ensure_latest(),
                    Req = cowboy_req:reply(503,
                        #{<<"content-type">> => <<"text/plain">>},
                        <<"Management panel not yet available, downloading...">>, Req0),
                    {ok, Req, State}
            end
    end.
