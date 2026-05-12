-module(cloaking).

%% Request cloaking — disguise proxy requests as official Claude Code CLI
%% Uses CLIPS rules for policy decisions, Erlang for execution

-export([maybe_cloak/2, obfuscate_sensitive_words/1, generate_fake_user_id/0]).

-spec maybe_cloak(cowboy_req:req(), map()) -> {boolean(), map()}.
maybe_cloak(Req, Request) ->
    UA = cowboy_req:header(<<"user-agent">>, Req, <<>>),
    Mode = config_loader:get(cloak_mode, <<"auto">>),
    ShouldCloak = should_cloak(UA, Mode),
    case ShouldCloak of
        true ->
            Cloaked = apply_cloaking(Request),
            {true, Cloaked};
        false ->
            {false, Request}
    end.

-spec obfuscate_sensitive_words(binary()) -> binary().
obfuscate_sensitive_words(Text) ->
    Words = get_sensitive_words(),
    lists:foldl(fun(Word, Acc) ->
        obfuscate_word(Acc, Word)
    end, Text, Words).

generate_fake_user_id() ->
    HexPart = hex(crypto:strong_rand_bytes(32)),
    UUID1 = uuid(),
    UUID2 = uuid(),
    <<"user_", HexPart/binary, "_account_", UUID1/binary, "_session_", UUID2/binary>>.

%%====================================================================
%% Internal
%%====================================================================

should_cloak(UA, Mode) ->
    case whereis(clips_engine) of
        undefined -> should_cloak_fallback(UA, Mode);
        _ ->
            Id = <<"clk_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
            ModeAtom = case Mode of
                <<"always">> -> always;
                <<"never">> -> never;
                _ -> auto
            end,
            _ = clips_engine:assert({cloak_input, #{
                id => Id,
                user_agent => UA,
                mode => ModeAtom
            }}),
            _ = clips_engine:run(),
            Result = clips_engine:query(cloak_output, <<"id">>, Id),
            _ = clips_engine:retract({cloak_input, Id}),
            _ = clips_engine:retract({cloak_output, Id}),
            case Result of
                {ok, #{<<"should-cloak">> := <<"yes">>}} -> true;
                {ok, _} -> false;
                error -> should_cloak_fallback(UA, Mode)
            end
    end.

should_cloak_fallback(_UA, <<"always">>) -> true;
should_cloak_fallback(_UA, <<"never">>) -> false;
should_cloak_fallback(UA, _) ->
    case binary:match(UA, <<"claude-cli">>) of
        nomatch -> true;
        _ -> false
    end.

apply_cloaking(Request) ->
    %% Inject Claude Code system instructions if available
    Instructions = load_instructions(),
    Request1 = case Instructions of
        <<>> -> Request;
        _ ->
            System = maps:get(<<"system">>, Request, []),
            InstrBlock = #{<<"type">> => <<"text">>, <<"text">> => Instructions,
                           <<"cache_control">> => #{<<"type">> => <<"ephemeral">>}},
            NewSystem = case System of
                L when is_list(L) -> [InstrBlock | L];
                B when is_binary(B) -> [InstrBlock, #{<<"type">> => <<"text">>, <<"text">> => B}];
                _ -> [InstrBlock]
            end,
            Request#{<<"system">> => NewSystem}
    end,
    %% Obfuscate sensitive words in messages
    Messages = maps:get(<<"messages">>, Request1, []),
    ObfMessages = [obfuscate_message(M) || M <- Messages],
    Request1#{<<"messages">> => ObfMessages}.

obfuscate_message(#{<<"content">> := Content} = Msg) when is_binary(Content) ->
    Msg#{<<"content">> => obfuscate_sensitive_words(Content)};
obfuscate_message(Msg) ->
    Msg.

get_sensitive_words() ->
    case config_loader:get(sensitive_words) of
        undefined -> [<<"proxy">>, <<"mirror">>, <<"relay">>, <<"forward">>];
        Words when is_list(Words) -> Words;
        _ -> []
    end.

obfuscate_word(Text, Word) ->
    ZWS = <<16#E2, 16#80, 16#8B>>,  %% U+200B zero-width space (UTF-8)
    case byte_size(Word) > 0 of
        true ->
            <<First:1/binary, Rest/binary>> = Word,
            Replacement = <<First/binary, ZWS/binary, Rest/binary>>,
            binary:replace(Text, Word, Replacement, [global]);
        false ->
            Text
    end.

load_instructions() ->
    PrivDir = code:priv_dir(cli_proxy),
    Path = filename:join(PrivDir, "claude_code_instructions.txt"),
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, _} -> <<>>
    end.

hex(Bin) ->
    <<<<(hex_char(N))/binary>> || <<N:4>> <= Bin>>.

hex_char(N) when N < 10 -> <<($0 + N)>>;
hex_char(N) -> <<($a + N - 10)>>.

uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
                                   [A, B, C, D, E])).
