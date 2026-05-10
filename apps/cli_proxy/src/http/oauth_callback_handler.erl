-module(oauth_callback_handler).

%% Cowboy handler for OAuth callback endpoints
%% Routes: /anthropic/callback, /codex/callback, /google/callback, etc.

-export([init/2]).

init(Req0, State) ->
    Code = cowboy_req:qs_val(<<"code">>, Req0, <<>>),
    StateToken = cowboy_req:qs_val(<<"state">>, Req0, <<>>),

    case StateToken of
        <<>> ->
            Req = cowboy_req:reply(400, #{<<"content-type">> => <<"text/html">>},
                <<"<h1>Missing state parameter</h1>">>, Req0),
            {ok, Req, State};
        _ ->
            case oauth_session_registry:find(StateToken) of
                {ok, SessionPid} ->
                    oauth_session:notify_callback(SessionPid, StateToken, Code),
                    Req = cowboy_req:reply(200, #{<<"content-type">> => <<"text/html">>},
                        <<"<h1>Login successful!</h1><p>You can close this window.</p>">>, Req0),
                    {ok, Req, State};
                error ->
                    Req = cowboy_req:reply(400, #{<<"content-type">> => <<"text/html">>},
                        <<"<h1>Unknown or expired session</h1>">>, Req0),
                    {ok, Req, State}
            end
    end.
