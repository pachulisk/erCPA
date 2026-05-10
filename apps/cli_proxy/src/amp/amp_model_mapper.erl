-module(amp_model_mapper).

%% Model mapping resolution for Amp CLI
%% Supports exact match and regex patterns

-export([resolve/1, check_mappings/1]).

-spec resolve(binary()) -> {local, atom(), binary()} | {mapped, binary(), binary()} | upstream.
resolve(Model) ->
    ForceMapping = amp_config:force_model_mappings(),
    case ForceMapping of
        true ->
            %% Mappings first, then local
            case check_mappings(Model) of
                {ok, Mapped} -> {mapped, Model, Mapped};
                nomatch -> check_local_then_upstream(Model)
            end;
        false ->
            %% Local first, then mappings, then upstream
            case check_local(Model) of
                {ok, Provider} -> {local, Provider, Model};
                nomatch ->
                    case check_mappings(Model) of
                        {ok, Mapped} -> {mapped, Model, Mapped};
                        nomatch -> upstream
                    end
            end
    end.

-spec check_mappings(binary()) -> {ok, binary()} | nomatch.
check_mappings(Model) ->
    Mappings = amp_config:get_model_mappings(),
    check_mappings(Model, Mappings).

check_mappings(_Model, []) -> nomatch;
check_mappings(Model, [#{from := Pattern, to := To} = M | Rest]) ->
    IsRegex = maps:get(regex, M, false),
    case match_pattern(Model, Pattern, IsRegex) of
        true -> {ok, To};
        false -> check_mappings(Model, Rest)
    end;
check_mappings(Model, [#{<<"from">> := Pattern, <<"to">> := To} = M | Rest]) ->
    IsRegex = maps:get(<<"regex">>, M, false),
    case match_pattern(Model, Pattern, IsRegex) of
        true -> {ok, To};
        false -> check_mappings(Model, Rest)
    end;
check_mappings(Model, [_ | Rest]) ->
    check_mappings(Model, Rest).

%%====================================================================
%% Internal
%%====================================================================

match_pattern(Model, Pattern, true) ->
    case re:run(Model, Pattern) of
        {match, _} -> true;
        nomatch -> false
    end;
match_pattern(Model, Pattern, false) ->
    Model =:= Pattern.

check_local(Model) ->
    case model_registry:is_model_available(Model) of
        true ->
            Info = model_registry:get_model_info(Model),
            case Info of
                undefined -> nomatch;
                #{<<"provider">> := P} -> {ok, binary_to_atom(P, utf8)};
                _ -> nomatch
            end;
        false -> nomatch
    end.

check_local_then_upstream(Model) ->
    case check_local(Model) of
        {ok, Provider} -> {local, Provider, Model};
        nomatch -> upstream
    end.
