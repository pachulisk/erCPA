-module(auth_synthesizer).

%% Auto-generate credential processes from config API key lists
%% Scans: gemini_keys, claude_keys, codex_keys, vertex_keys, openai_compat
%% Called on startup and config reload

-export([synthesize/0]).

-spec synthesize() -> ok.
synthesize() ->
    synthesize_keys(claude, config_loader:get(claude_keys, [])),
    synthesize_keys(gemini, config_loader:get(gemini_keys, [])),
    synthesize_keys(codex, config_loader:get(codex_keys, [])),
    synthesize_keys(vertex, config_loader:get(vertex_keys, [])),
    synthesize_compat(config_loader:get(openai_compat, [])),
    ok.

%%====================================================================
%% Internal
%%====================================================================

synthesize_keys(_Provider, []) -> ok;
synthesize_keys(Provider, Keys) when is_list(Keys) ->
    lists:foreach(fun(KeyEntry) ->
        {Id, Meta} = parse_key_entry(Provider, KeyEntry),
        maybe_start_credential(Id, Provider, Meta)
    end, Keys);
synthesize_keys(_, _) -> ok.

synthesize_compat([]) -> ok;
synthesize_compat(Entries) when is_list(Entries) ->
    lists:foreach(fun(Entry) when is_map(Entry) ->
        ApiKey = maps:get(<<"api_key">>, Entry, <<>>),
        BaseURL = maps:get(<<"base_url">>, Entry, <<"http://localhost:8080">>),
        Name = maps:get(<<"name">>, Entry, <<"compat">>),
        Id = <<"synth-compat-", Name/binary>>,
        Meta = #{
            <<"type">> => <<"openai_compat">>,
            <<"api_key">> => ApiKey,
            <<"base_url">> => BaseURL,
            <<"email">> => Name,
            <<"synthesized">> => true
        },
        Models = maps:get(<<"models">>, Entry, undefined),
        Meta1 = case Models of
            undefined -> Meta;
            M when is_list(M) -> Meta#{<<"models">> => M};
            _ -> Meta
        end,
        maybe_start_credential(Id, openai_compat, Meta1);
    (_) -> ok
    end, Entries);
synthesize_compat(_) -> ok.

parse_key_entry(Provider, Key) when is_binary(Key) ->
    Id = <<"synth-", (atom_to_binary(Provider, utf8))/binary, "-",
           (integer_to_binary(erlang:phash2(Key)))/binary>>,
    Meta = #{
        <<"type">> => atom_to_binary(Provider, utf8),
        <<"api_key">> => Key,
        <<"email">> => <<"synthesized">>,
        <<"synthesized">> => true
    },
    {Id, Meta};
parse_key_entry(Provider, Entry) when is_map(Entry) ->
    Key = maps:get(<<"key">>, Entry, maps:get(<<"api_key">>, Entry, <<>>)),
    Name = maps:get(<<"name">>, Entry, <<"synthesized">>),
    BaseURL = maps:get(<<"base_url">>, Entry, <<>>),
    Priority = maps:get(<<"priority">>, Entry, 0),
    Id = <<"synth-", (atom_to_binary(Provider, utf8))/binary, "-",
           (integer_to_binary(erlang:phash2(Key)))/binary>>,
    Meta0 = #{
        <<"type">> => atom_to_binary(Provider, utf8),
        <<"api_key">> => Key,
        <<"email">> => Name,
        <<"priority">> => Priority,
        <<"synthesized">> => true
    },
    Meta1 = case BaseURL of
        <<>> -> Meta0;
        _ -> Meta0#{<<"base_url">> => BaseURL}
    end,
    Models = maps:get(<<"models">>, Entry, undefined),
    Meta2 = case Models of
        undefined -> Meta1;
        M when is_list(M) -> Meta1#{<<"models">> => M};
        _ -> Meta1
    end,
    {Id, Meta2};
parse_key_entry(Provider, _) ->
    {<<"synth-", (atom_to_binary(Provider, utf8))/binary, "-unknown">>, #{}}.

maybe_start_credential(Id, Provider, Meta) ->
    ProcName = binary_to_atom(<<"cred_", Id/binary>>, utf8),
    case whereis(ProcName) of
        undefined ->
            credential_sup:start_credential(#{
                id => Id,
                provider => Provider,
                metadata => Meta
            });
        _ ->
            ok
    end.
