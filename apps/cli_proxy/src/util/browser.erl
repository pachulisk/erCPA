-module(browser).

%% Cross-platform browser opener for OAuth flows

-export([open_url/1, is_available/0]).

-spec open_url(binary() | string()) -> ok | {error, term()}.
open_url(URL) when is_binary(URL) ->
    open_url(binary_to_list(URL));
open_url(URL) when is_list(URL) ->
    case os:type() of
        {unix, darwin} ->
            _ = os:cmd("open " ++ escape(URL)),
            ok;
        {unix, _Linux} ->
            %% Try in order: xdg-open, x-www-browser, firefox
            try_browsers(URL, ["xdg-open", "x-www-browser", "firefox",
                               "chromium", "google-chrome"]);
        {win32, _} ->
            _ = os:cmd("rundll32 url.dll,FileProtocolHandler " ++ escape(URL)),
            ok
    end.

-spec is_available() -> boolean().
is_available() ->
    case os:type() of
        {unix, darwin} -> true;
        {unix, _} ->
            os:find_executable("xdg-open") =/= false orelse
            os:find_executable("firefox") =/= false;
        {win32, _} -> true
    end.

%%====================================================================
%% Internal
%%====================================================================

try_browsers(_URL, []) ->
    {error, no_browser_found};
try_browsers(URL, [Cmd | Rest]) ->
    case os:find_executable(Cmd) of
        false -> try_browsers(URL, Rest);
        _Path ->
            _ = os:cmd(Cmd ++ " " ++ escape(URL) ++ " &"),
            ok
    end.

escape(URL) ->
    %% Simple shell escaping — wrap in single quotes
    "'" ++ URL ++ "'".
