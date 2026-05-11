-module(log_rotator).

%% Size-based log rotation

-export([rotate_if_needed/1, cleanup_error_logs/2]).

-spec rotate_if_needed(string()) -> ok.
rotate_if_needed(LogDir) ->
    MaxMB = config_loader:get(logs_max_total_size_mb, 0),
    case MaxMB of
        0 -> ok;  %% Rotation disabled
        _ ->
            Files = filelib:wildcard(filename:join(LogDir, "*.log")),
            TotalSize = lists:sum([filelib:file_size(F) || F <- Files]),
            case TotalSize > MaxMB * 1024 * 1024 of
                true -> prune_oldest(Files, TotalSize, MaxMB * 1024 * 1024);
                false -> ok
            end
    end.

-spec cleanup_error_logs(string(), pos_integer()) -> ok.
cleanup_error_logs(Dir, MaxFiles) ->
    Files = filelib:wildcard(filename:join(Dir, "error-*.log")),
    case length(Files) > MaxFiles of
        true ->
            Sorted = lists:sort(fun(A, B) ->
                filelib:last_modified(A) < filelib:last_modified(B)
            end, Files),
            ToDelete = lists:sublist(Sorted, length(Files) - MaxFiles),
            lists:foreach(fun file:delete/1, ToDelete);
        false ->
            ok
    end.

%%====================================================================
%% Internal
%%====================================================================

prune_oldest(Files, CurrentSize, MaxSize) ->
    Sorted = lists:sort(fun(A, B) ->
        filelib:last_modified(A) < filelib:last_modified(B)
    end, Files),
    prune_loop(Sorted, CurrentSize, MaxSize).

prune_loop([], _Current, _Max) -> ok;
prune_loop(_Files, Current, Max) when Current =< Max -> ok;
prune_loop([File | Rest], Current, Max) ->
    Size = filelib:file_size(File),
    _ = file:delete(File),
    prune_loop(Rest, Current - Size, Max).
