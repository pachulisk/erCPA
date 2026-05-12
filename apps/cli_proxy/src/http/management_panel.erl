-module(management_panel).

%% Management control panel asset manager
%% Downloads management.html from GitHub releases and serves it
%% Auto-updates every 3 hours in background

-export([
    start_link/0,
    get_html/0,
    ensure_latest/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-behaviour(gen_server).

-define(RELEASE_URL,
    <<"https://api.github.com/repos/router-for-me/Cli-Proxy-API-Management-Center/releases/latest">>).
-define(FALLBACK_URL, <<"https://cpamc.router-for.me/">>).
-define(UPDATE_INTERVAL, 10800000). %% 3 hours
-define(ASSET_NAME, "management.html").

-record(state, {
    static_dir :: string(),
    html_path  :: string()
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_html() -> {ok, binary()} | {error, not_found}.
get_html() ->
    gen_server:call(?MODULE, get_html, 30000).

-spec ensure_latest() -> ok.
ensure_latest() ->
    gen_server:cast(?MODULE, ensure_latest).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    AuthDir = config_loader:get(auth_dir, "~/.cli-proxy-api/"),
    Dir = expand_home(AuthDir),
    StaticDir = filename:join(Dir, "static"),
    ok = filelib:ensure_dir(filename:join(StaticDir, "dummy")),
    HtmlPath = filename:join(StaticDir, ?ASSET_NAME),
    schedule_update(),
    %% Try initial download in background
    self() ! ensure_latest,
    {ok, #state{static_dir = StaticDir, html_path = HtmlPath}}.

handle_call(get_html, _From, #state{html_path = Path} = State) ->
    case file:read_file(Path) of
        {ok, Content} -> {reply, {ok, Content}, State};
        {error, _} -> {reply, {error, not_found}, State}
    end;
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast(ensure_latest, State) ->
    _ = do_ensure_latest(State),
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(ensure_latest, State) ->
    _ = do_ensure_latest(State),
    {noreply, State};
handle_info(update_check, State) ->
    case config_loader:get(disable_control_panel, false) of
        true -> ok;
        false -> _ = do_ensure_latest(State), ok
    end,
    schedule_update(),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

%%====================================================================
%% Internal
%%====================================================================

do_ensure_latest(#state{html_path = Path, static_dir = Dir}) ->
    case config_loader:get(disable_control_panel, false) of
        true -> ok;
        false ->
            case config_loader:get(disable_auto_update_panel, false) of
                true ->
                    %% Auto-update disabled, only download if file missing
                    case filelib:is_regular(Path) of
                        true -> ok;
                        false ->
                            ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
                            do_download(Path, Dir)
                    end;
                false ->
                    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
                    do_download(Path, Dir)
            end
    end.

do_download(Path, _Dir) ->
    case download_from_release(Path) of
        ok -> ok;
        {error, _} ->
            download_from_url(?FALLBACK_URL, Path)
    end.

download_from_release(DestPath) ->
    RepoURL = case config_loader:get(panel_github_repository, <<>>) of
        <<>> -> ?RELEASE_URL;
        CustomRepo ->
            iolist_to_binary([
                <<"https://api.github.com/repos/">>,
                CustomRepo,
                <<"/releases/latest">>
            ])
    end,
    Headers = [{<<"User-Agent">>, <<"erCPA-management-updater">>}],
    case hackney:get(RepoURL, Headers, <<>>, [{recv_timeout, 15000}]) of
        {ok, 200, _, Ref} ->
            {ok, Body} = hackney:body(Ref),
            case jiffy:decode(Body, [return_maps]) of
                #{<<"assets">> := Assets} ->
                    case find_asset(Assets) of
                        {ok, URL} -> download_from_url(URL, DestPath);
                        error -> {error, asset_not_found}
                    end;
                _ -> {error, bad_response}
            end;
        _ -> {error, api_failed}
    end.

find_asset([]) -> error;
find_asset([#{<<"name">> := Name, <<"browser_download_url">> := URL} | _])
  when Name =:= <<"management.html">> ->
    {ok, URL};
find_asset([_ | Rest]) -> find_asset(Rest).

download_from_url(URL, DestPath) ->
    Headers = [{<<"User-Agent">>, <<"erCPA-management-updater">>}],
    case hackney:get(URL, Headers, <<>>, [{recv_timeout, 30000}, {follow_redirect, true}]) of
        {ok, 200, _, Ref} ->
            {ok, Content} = hackney:body(Ref),
            case byte_size(Content) > 0 of
                true -> file:write_file(DestPath, Content);
                false -> {error, empty_response}
            end;
        _ -> {error, download_failed}
    end.

schedule_update() ->
    erlang:send_after(?UPDATE_INTERVAL, self(), update_check).

expand_home("~/" ++ Rest) ->
    Home = os:getenv("HOME", "/tmp"),
    filename:join(Home, Rest);
expand_home(Path) ->
    Path.
