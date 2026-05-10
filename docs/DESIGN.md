# Erlang + CLIPS Redesign

A design document for reimplementing CLIProxyAPI using Erlang/OTP for concurrency and fault tolerance, and CLIPS for rule-based decision making.

## Why Erlang + CLIPS

The current Go implementation has two areas where the language fights the problem:

**The Auth Conductor is a rule engine written as imperative code.** `conductor.go` is 4000+ lines of interleaved if/else chains that decide which credential to pick, when to retry, how long to cool down, whether to fall back. This logic is inherently declarative — a set of rules operating on facts (credential states, cooldown timers, quota levels, session bindings). CLIPS makes the rule-based nature explicit, turning 4000 lines of Go into ~200 rules that are independently testable and auditable.

**The concurrency model is hand-rolled.** Go channels and goroutines work, but CLIProxyAPI constantly reinvents patterns that Erlang provides natively:
- `wsrelay/` reimplements lightweight per-connection processes
- `watcher/` reimplements hot-reload with debouncing and hash comparison
- `auto_refresh_loop.go` reimplements a min-heap scheduler with concurrent workers
- `home/` speaks Redis protocol to get what Erlang distribution gives for free
- Every executor needs manual goroutine lifecycle management

Erlang/OTP eliminates these with supervised processes, hot code swapping, built-in distribution, and "let it crash" fault isolation.

## CLIPS Integration Pattern

CLIPS runs as an **Erlang Port** (external OS process), not a NIF.

A NIF would be faster but carries crash risk — a segfault in CLIPS' C runtime would take down the BEAM VM, violating Erlang's fault isolation guarantees. A Port runs in a separate OS process, communicating via stdin/stdout. If the CLIPS process crashes, the supervising `gen_server` restarts it and rebuilds state from the Erlang-side source of truth.

```
┌──────────────────────────────────────────┐
│              BEAM VM                     │
│                                          │
│  ┌──────────────────────┐                │
│  │  clips_engine        │   stdin/stdout │
│  │  (gen_server)        │◄══════════════►│ CLIPS Port Process
│  │                      │   JSON msgs    │ (C runtime)
│  │  - serializes facts  │                │
│  │  - deserializes      │                │
│  │    rule firings      │                │
│  │  - holds fact mirror │                │
│  └──────────────────────┘                │
│                                          │
└──────────────────────────────────────────┘
```

**One CLIPS engine per conductor instance**, not per request. The engine maintains persistent working memory (credential states, cooldowns, session bindings). Requests assert temporary facts, trigger rule evaluation, read the selection result, then retract the request fact.

The `clips_engine` gen_server serializes all interactions with the CLIPS port. The protocol is line-delimited JSON:

```
→ {"op":"assert","fact":["credential",{"id":"c1","provider":"claude","status":"active"}]}
→ {"op":"run"}
← {"fired":"select-credential","bindings":{"request-id":"r1","credential-id":"c1"}}
→ {"op":"retract","fact-id":42}
```

## OTP Supervision Tree

```
                        cli_proxy_app (application)
                               │
                     cli_proxy_root_sup (one_for_one)
                    ┌──────────┼──────────────┐
                    │          │              │
              http_sup    provider_sup    config_sup
           (one_for_one) (one_for_one)  (rest_for_one)
                │          ┌──┼──┐          ├── config_watcher
                │          │  │  │          ├── model_registry
           cowboy_listener │  │  │          └── clips_engine
                          │  │  │
              claude_executor │  gemini_executor
                    codex_executor
                     ... (one gen_server per provider type)

        Per-connection processes (dynamic, not in tree):
        ── ws_session_1    (WebSocket connection process)
        ── ws_session_2
        ── ...
```

### Key process roles

| Process | Type | State | Crash policy |
|---------|------|-------|-------------|
| `http_sup` | supervisor | — | Restart Cowboy if it dies |
| `cowboy_listener` | cowboy acceptor pool | TCP connections | Let it crash, supervisor restarts |
| `provider_sup` | supervisor | — | Restart individual executors |
| `*_executor` | gen_server | Provider config, HTTP client | Restart with fresh state |
| `config_sup` | supervisor (rest_for_one) | — | If config_watcher dies, restart it + downstream |
| `config_watcher` | gen_server | File hashes, fs subscription | Restart, re-scan on init |
| `model_registry` | gen_server + ETS | Model catalog, per-credential models | Restart, reload from embedded catalog |
| `clips_engine` | gen_server + Port | CLIPS working memory mirror | Restart Port, rebuild facts from mirror |
| `ws_session_*` | raw process | Connection state | Die with connection, conductor notified via monitor |

### Why `rest_for_one` for config_sup

`config_watcher` → `model_registry` → `clips_engine` is a dependency chain. If the watcher restarts, the registry should reload, and the CLIPS engine should rebuild its model-capability facts. `rest_for_one` guarantees this ordering.

## CLIPS Fact Model

### Fact templates

```clips
;;; --- Credential state ---
(deftemplate credential
  (slot id (type STRING))
  (slot provider (type STRING))          ; "claude" | "gemini" | "codex" | ...
  (slot priority (type INTEGER) (default 0))
  (slot status (type SYMBOL)             ; active | disabled | cooldown
    (allowed-symbols active disabled cooldown))
  (slot cooldown-until (type INTEGER) (default 0))  ; unix timestamp
  (slot backoff-level (type INTEGER) (default 0))
  (slot prefix (type STRING) (default ""))
  (slot has-websocket (type SYMBOL) (default no)))

;;; --- Per-model state on a credential ---
(deftemplate model-state
  (slot credential-id (type STRING))
  (slot model (type STRING))
  (slot available (type SYMBOL) (default yes))
  (slot cooldown-until (type INTEGER) (default 0))
  (slot backoff-level (type INTEGER) (default 0)))

;;; --- Session affinity bindings ---
(deftemplate session-binding
  (slot session-id (type STRING))
  (slot credential-id (type STRING))
  (slot bound-at (type INTEGER))         ; unix timestamp
  (slot ttl (type INTEGER)))             ; seconds

;;; --- Model capability (from registry) ---
(deftemplate model-capability
  (slot model (type STRING))
  (slot provider (type STRING))
  (slot thinking-min (type INTEGER) (default 0))
  (slot thinking-max (type INTEGER) (default 0))
  (slot thinking-levels (type STRING) (default ""))  ; comma-separated
  (slot thinking-mode (type SYMBOL)      ; budget | level | hybrid | none
    (allowed-symbols budget level hybrid none)))

;;; --- Per-request facts (transient) ---
(deftemplate select-request
  (slot id (type STRING))
  (slot model (type STRING))
  (slot session-id (type STRING) (default ""))
  (slot need-websocket (type SYMBOL) (default no))
  (slot now (type INTEGER)))             ; current unix timestamp

(deftemplate candidate
  (slot request-id (type STRING))
  (slot credential-id (type STRING))
  (slot score (type INTEGER) (default 0))
  (slot reason (type STRING) (default "")))

(deftemplate selection-result
  (slot request-id (type STRING))
  (slot credential-id (type STRING))
  (slot reason (type STRING)))

;;; --- Thinking normalization (transient) ---
(deftemplate thinking-input
  (slot id (type STRING))
  (slot source-format (type STRING))     ; "openai" | "claude" | "gemini"
  (slot target-format (type STRING))
  (slot model (type STRING))
  (slot mode (type SYMBOL))              ; budget | level | none | auto
  (slot budget (type INTEGER) (default -1))
  (slot level (type STRING) (default ""))
  (slot suffix-override (type SYMBOL) (default no)))

(deftemplate thinking-output
  (slot id (type STRING))
  (slot mode (type SYMBOL))
  (slot budget (type INTEGER))
  (slot level (type STRING)))
```

### Credential selection rules

The imperative Go logic in `conductor.go` lines 371-428 (`isAuthBlockedForModel`) and `selector.go` (round-robin/fill-first filtering) becomes a set of independent rules:

```clips
;;; --- Exclusion rules (high salience, run first) ---

(defrule exclude-disabled
  "Credential is globally disabled"
  (declare (salience 100))
  (select-request (id ?rid))
  (credential (id ?cid) (status disabled))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?cid) (score -1)
                      (reason "disabled"))))

(defrule exclude-global-cooldown
  "Credential is in global cooldown"
  (declare (salience 100))
  (select-request (id ?rid) (now ?now))
  (credential (id ?cid) (status cooldown) (cooldown-until ?t))
  (test (> ?t ?now))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?cid) (score -1)
                      (reason "global-cooldown"))))

(defrule exclude-model-cooldown
  "Credential is in per-model cooldown"
  (declare (salience 100))
  (select-request (id ?rid) (model ?m) (now ?now))
  (model-state (credential-id ?cid) (model ?m)
               (available no) (cooldown-until ?t))
  (test (> ?t ?now))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?cid) (score -1)
                      (reason "model-cooldown"))))

(defrule exclude-no-websocket
  "Request needs websocket but credential doesn't support it"
  (declare (salience 100))
  (select-request (id ?rid) (need-websocket yes))
  (credential (id ?cid) (has-websocket no))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?cid) (score -1)
                      (reason "no-websocket"))))

;;; --- Scoring rules (medium salience) ---

(defrule score-by-priority
  "Higher priority credentials score higher"
  (declare (salience 50))
  (select-request (id ?rid))
  (credential (id ?cid) (status active) (priority ?p))
  (not (candidate (request-id ?rid) (credential-id ?cid)))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?cid)
                      (score ?p) (reason "priority"))))

;;; --- Session affinity rules (highest salience among positive rules) ---

(defrule prefer-session-bound
  "If session has a bound credential that's available, use it"
  (declare (salience 80))
  (select-request (id ?rid) (session-id ?sid&~"") (now ?now))
  (session-binding (session-id ?sid) (credential-id ?cid)
                   (bound-at ?b) (ttl ?ttl))
  (test (< (- ?now ?b) ?ttl))
  (credential (id ?cid) (status active))
  (not (candidate (request-id ?rid) (credential-id ?cid) (score -1)))
  =>
  (assert (selection-result (request-id ?rid) (credential-id ?cid)
                            (reason "session-affinity"))))

;;; --- Final selection (lowest salience, runs after scoring) ---

(defrule select-best-candidate
  "Pick highest-scoring candidate when no session affinity match"
  (declare (salience 10))
  (select-request (id ?rid))
  (not (selection-result (request-id ?rid)))
  (candidate (request-id ?rid) (credential-id ?cid) (score ?s))
  (not (candidate (request-id ?rid) (score ?s2&:(> ?s2 ?s))
                  (credential-id ?other&~?cid)))
  (test (> ?s -1))
  =>
  (assert (selection-result (request-id ?rid) (credential-id ?cid)
                            (reason "best-score"))))
```

Compare this to the Go implementation: the same logic spans `isAuthBlockedForModel` (60 lines), `getAvailableAuths` (80 lines), `Pick` (60 lines), and `SessionAffinitySelector` (140 lines). The rules are independently readable and testable. Adding a new exclusion criterion is one rule, not a new branch woven into existing control flow.

### MarkResult as fact mutation

The Go `MarkResult()` function (150+ lines of state updates) becomes fact retraction and assertion:

```clips
(defrule mark-success
  "Clear cooldown on successful response"
  (declare (salience 100))
  (result (credential-id ?cid) (model ?m) (status-code ?s))
  (test (and (>= ?s 200) (< ?s 300)))
  ?ms <- (model-state (credential-id ?cid) (model ?m))
  =>
  (retract ?ms)
  (assert (model-state (credential-id ?cid) (model ?m)
                        (available yes) (cooldown-until 0) (backoff-level 0))))

(defrule mark-rate-limited
  "Exponential backoff on 429"
  (declare (salience 100))
  (result (credential-id ?cid) (model ?m) (status-code 429) (now ?now))
  ?ms <- (model-state (credential-id ?cid) (model ?m) (backoff-level ?bl))
  =>
  (retract ?ms)
  (bind ?cooldown (min (* (** 2 ?bl) 1) 1800))  ; 2^level seconds, cap 30min
  (assert (model-state (credential-id ?cid) (model ?m)
                        (available no)
                        (cooldown-until (+ ?now ?cooldown))
                        (backoff-level (+ ?bl 1)))))

(defrule mark-unauthorized
  "30-minute hold on auth failure"
  (declare (salience 100))
  (result (credential-id ?cid) (model ?m) (status-code ?s) (now ?now))
  (test (or (= ?s 401) (= ?s 402) (= ?s 403)))
  ?ms <- (model-state (credential-id ?cid) (model ?m))
  =>
  (retract ?ms)
  (assert (model-state (credential-id ?cid) (model ?m)
                        (available no)
                        (cooldown-until (+ ?now 1800))
                        (backoff-level 0))))
```

### Thinking normalization rules

The thinking pipeline (`internal/thinking/`) maps naturally to CLIPS. Validation, clamping, and format conversion are all rule-based decisions:

```clips
(defrule clamp-budget-to-max
  "Budget exceeds model maximum"
  (declare (salience 80))
  ?ti <- (thinking-input (id ?id) (mode budget) (budget ?b) (model ?m))
  (model-capability (model ?m) (thinking-max ?max))
  (test (> ?b ?max))
  =>
  (modify ?ti (budget ?max)))

(defrule convert-level-to-budget
  "Target model only supports budget, convert level"
  (declare (salience 70))
  ?ti <- (thinking-input (id ?id) (mode level) (level ?l) (model ?m))
  (model-capability (model ?m) (thinking-mode budget))
  =>
  (bind ?budget (level-to-budget ?l))  ; user-defined function
  (modify ?ti (mode budget) (budget ?budget) (level "")))

(defrule convert-budget-to-level
  "Target model only supports levels, convert budget"
  (declare (salience 70))
  ?ti <- (thinking-input (id ?id) (mode budget) (budget ?b) (model ?m))
  (model-capability (model ?m) (thinking-mode level))
  =>
  (bind ?lvl (budget-to-level ?b))     ; user-defined function
  (modify ?ti (mode level) (level ?lvl) (budget -1)))

(defrule emit-thinking-output
  "Normalization complete, emit result"
  (declare (salience 10))
  (thinking-input (id ?id) (mode ?mode) (budget ?b) (level ?l))
  (not (thinking-output (id ?id)))
  =>
  (assert (thinking-output (id ?id) (mode ?mode) (budget ?b) (level ?l))))
```

### Model catalog refresh

In Go, model catalog changes trigger a callback chain: detect change → iterate credentials → re-register → clear cooldowns. In CLIPS, this is simply fact retraction and re-assertion:

```erlang
%% In model_registry gen_server, on catalog update:
handle_info({catalog_updated, NewModels}, State) ->
    %% Retract old model-capability facts
    clips_engine:retract_all(model_capability),
    %% Assert new ones — rules depending on model-capability auto-re-evaluate
    [clips_engine:assert({model_capability, M}) || M <- NewModels],
    %% Retract stale cooldowns for models that no longer exist
    clips_engine:run(),
    {noreply, State}.
```

Any rules that referenced the old `model-capability` facts simply stop matching. No explicit callback chain needed.

## Subsystem Mapping

### What stays in Erlang (not CLIPS)

**Protocol translation.** Erlang's pattern matching on maps and binaries is superior to CLIPS for structural data transformation. The translator becomes a set of pure Erlang modules:

```erlang
-module(translator_openai_to_claude).
-export([request/3, response/4]).

request(Model, #{<<"messages">> := Messages} = Body, Stream) ->
    #{
        <<"model">> => Model,
        <<"messages">> => [translate_message(M) || M <- Messages],
        <<"max_tokens">> => maps:get(<<"max_tokens">>, Body, 4096),
        <<"stream">> => Stream
    };
request(Model, Body, Stream) ->
    %% Fallback: pass through with model update
    Body#{<<"model">> => Model, <<"stream">> => Stream}.

translate_message(#{<<"role">> := <<"system">>, <<"content">> := C}) ->
    #{<<"role">> => <<"user">>, <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => C}]};
translate_message(#{<<"role">> := Role, <<"content">> := C}) ->
    #{<<"role">> => Role, <<"content">> => translate_content(C)}.
```

**HTTP routing and middleware.** Cowboy handles this natively:

```erlang
Routes = cowboy_router:compile([
    {'_', [
        {"/v1/chat/completions", openai_handler, []},
        {"/v1/messages",         claude_handler, []},
        {"/v1beta/models/:action", gemini_handler, []},
        {"/v1/responses",        responses_handler, []},
        {"/v1/ws",               ws_handler, []},
        {"/v0/management/[...]", management_handler, []}
    ]}
]).
```

**Retry and circuit-breaking.** OTP supervisor restart strategies and process monitors replace the manual retry loop. When an executor process crashes, the supervisor restarts it. The conductor asks the CLIPS engine for the next credential — no manual loop management.

**WebSocket connections.** Each connection is a raw Erlang process. No `wsrelay` package needed — this is what Erlang processes are:

```erlang
%% Each WebSocket connection is a process
-module(ws_handler).
-behaviour(cowboy_websocket).

websocket_init(State) ->
    %% Register runtime credential with conductor
    AuthId = generate_auth_id(),
    clips_engine:assert({credential, AuthId, <<"aistudio">>, active}),
    {ok, State#{auth_id => AuthId}}.

websocket_terminate(_Reason, _Req, #{auth_id := AuthId}) ->
    %% Process dies → credential auto-removed
    clips_engine:retract({credential, AuthId}),
    ok.
```

**Home control plane → Erlang distribution.** The current implementation speaks Redis protocol to a central node. Erlang distribution replaces this entirely:

```erlang
%% Home mode: connect to central node
net_adm:ping('home@control-plane.local'),

%% Subscribe to config updates (Erlang message passing)
home_node:subscribe(config, self()),

%% Receive config pushes
receive
    {config_update, NewConfig} ->
        config_watcher:apply(NewConfig)
end.

%% Credential selection delegation
Result = rpc:call('home@control-plane.local', conductor, pick, [Request]).
```

No Redis client, no RESP protocol parser, no pubsub implementation. Erlang distribution provides authenticated, encrypted, multiplexed channels natively.

### What CLIPS handles

| Domain | Why CLIPS | Replaces |
|--------|-----------|----------|
| Credential selection | Multi-factor decision with exclusion rules, scoring, affinity | `conductor.go` (4000 lines), `selector.go` (900 lines) |
| Cooldown/quota state | State transitions triggered by response status codes | `MarkResult()` in conductor.go (150 lines) |
| Thinking normalization | Validate, clamp, convert between budget/level with model constraints | `internal/thinking/` (7 files, ~1500 lines) |
| Model routing | Which providers can serve which models, with exclusion patterns | Model registration and filtering in conductor |
| Retry decisions | Whether to retry, which credential next, how long to wait | Retry loop in `Execute`/`ExecuteStream` |

### What neither CLIPS nor custom code handles (OTP does it)

| Current Go code | Erlang replacement |
|-----------------|-------------------|
| `auto_refresh_loop.go` (min-heap scheduler + worker pool) | `timer:send_interval/2` per credential process |
| `internal/watcher/` (fsnotify + debounce + hash compare) | `fs` library + gen_server state + hot code loading |
| Manual goroutine lifecycle in executors | Supervised gen_server processes |
| Channel-based auth update dispatch | Process mailboxes + monitors |
| `sync.RWMutex` throughout conductor | Per-process state isolation (no shared mutable state) |
| `atomic.Value` for config | ETS table with `read_concurrency` |

## Executor Architecture

Each provider executor is a `gen_server` holding provider-specific configuration and an HTTP client (via `hackney` or `gun`):

```erlang
-module(claude_executor).
-behaviour(gen_server).

-record(state, {
    config :: map(),
    http_pool :: pid()
}).

init([Config]) ->
    {ok, Pool} = hackney_pool:start_pool(claude_pool, [{max_connections, 50}]),
    {ok, #state{config = Config, http_pool = Pool}}.

handle_call({execute, Auth, Request, Opts}, From, State) ->
    %% Spawn a process for this request (non-blocking)
    spawn_link(fun() ->
        Result = do_execute(Auth, Request, Opts, State),
        gen_server:reply(From, Result)
    end),
    {noreply, State};

handle_call({execute_stream, Auth, Request, Opts}, From, State) ->
    %% Return a process that streams chunks to caller
    Caller = element(1, From),
    spawn_link(fun() ->
        StreamPid = do_execute_stream(Auth, Request, Opts, State, Caller),
        gen_server:reply(From, {ok, StreamPid})
    end),
    {noreply, State}.
```

Streaming responses are an Erlang process that sends messages to the caller:

```erlang
do_execute_stream(Auth, Request, Opts, State, Caller) ->
    {ok, ConnRef} = gun:open(Host, Port),
    StreamRef = gun:post(ConnRef, Path, Headers, Body),
    stream_loop(ConnRef, StreamRef, Caller).

stream_loop(ConnRef, StreamRef, Caller) ->
    receive
        {gun_data, ConnRef, StreamRef, nofin, Data} ->
            Caller ! {stream_chunk, Data},
            stream_loop(ConnRef, StreamRef, Caller);
        {gun_data, ConnRef, StreamRef, fin, Data} ->
            Caller ! {stream_chunk, Data},
            Caller ! stream_done;
        {gun_error, ConnRef, StreamRef, Reason} ->
            Caller ! {stream_error, Reason}
    end.
```

## Request Flow (Erlang + CLIPS)

```
1. Cowboy receives POST /v1/chat/completions
       │
2. openai_handler:handle/2
   ├── Parse JSON body, extract model + stream flag
   └── Call conductor:execute(openai, Model, Body, Opts)
       │
3. conductor (gen_server):
   ├── Assert (select-request ...) into CLIPS
   ├── clips_engine:run()
   ├── Read (selection-result ...) → {CredentialId, Provider}
   ├── Retract transient facts
   │
4. ├── Call translator:request(openai, Provider, Model, Body)
   │   └── Pure Erlang pattern matching → translated body
   │
5. ├── Assert (thinking-input ...) into CLIPS
   │   clips_engine:run()
   │   Read (thinking-output ...) → normalized thinking config
   │   Apply to translated body
   │
6. ├── Call executor:execute(Provider, Auth, TranslatedBody, Opts)
   │   └── gen_server call → spawned process → HTTP request
   │
7. ├── On response:
   │   ├── Assert (result ...) into CLIPS → state transitions fire
   │   ├── Call translator:response(Provider, openai, ...)
   │   └── Return to handler
   │
8. └── On retryable error:
       ├── CLIPS already updated credential state
       ├── Re-assert (select-request ...) → get next credential
       └── Loop to step 4
```

## Config and Hot-Reload

Erlang's hot code loading simplifies the current watcher significantly:

```erlang
-module(config_watcher).
-behaviour(gen_server).

init([ConfigPath]) ->
    %% Watch config file
    {ok, _} = fs:subscribe(ConfigPath),
    Config = load_config(ConfigPath),
    {ok, #{path => ConfigPath, config => Config, hash => crypto:hash(sha256, Config)}}.

handle_info({_Pid, {fs, file_event}, {Path, [modified]}}, State) ->
    NewHash = crypto:hash(sha256, file:read_file(Path)),
    case NewHash =:= maps:get(hash, State) of
        true  -> {noreply, State};  % No actual change
        false ->
            NewConfig = load_config(Path),
            %% Notify all interested processes
            config_event:notify({config_updated, NewConfig}),
            %% Update CLIPS facts for affected credentials
            clips_engine:update_credentials(NewConfig),
            {noreply, State#{config => NewConfig, hash => NewHash}}
    end.
```

Auth directory changes are similarly simplified — each auth file change becomes a process message, no debounce channel infrastructure needed:

```erlang
handle_info({_Pid, {fs, file_event}, {AuthFile, Events}}, State) ->
    case lists:member(modified, Events) orelse lists:member(created, Events) of
        true ->
            Auth = synthesize_auth(AuthFile),
            clips_engine:assert({credential, Auth}),
            model_registry:register_client(Auth);
        false -> ok
    end,
    case lists:member(removed, Events) of
        true ->
            clips_engine:retract({credential, auth_id(AuthFile)});
        false -> ok
    end,
    {noreply, State}.
```

## Trade-offs

### Wins

| Area | Improvement |
|------|-------------|
| **Conductor complexity** | 4000 lines of imperative Go → ~200 CLIPS rules, independently testable |
| **Concurrency model** | No manual goroutine/channel management; supervised processes with built-in fault isolation |
| **Hot-reload** | Native BEAM capability replaces custom watcher + hash comparison + debounce infrastructure |
| **Home control plane** | Erlang distribution replaces Redis protocol implementation entirely |
| **WebSocket connections** | One Erlang process per connection, natural lifecycle management via monitors |
| **Shared mutable state** | Eliminated. Each process owns its state. ETS for read-heavy shared data (model registry) |
| **Rule auditability** | Credential selection logic is declarative, with built-in rule trace/watch for debugging |
| **Model catalog refresh** | Fact retraction + re-assertion triggers automatic rule re-evaluation; no callback chains |
| **Token refresh scheduling** | `timer:send_interval/2` per credential process replaces min-heap + worker pool |

### Costs

| Area | Challenge |
|------|-----------|
| **CLIPS debugging** | Rule firing traces under load are hard to read. Need good tooling around `(watch facts)` and `(watch rules)` |
| **Deployment** | No single binary. Need Erlang release (via relx/rebar3) + CLIPS shared library. Docker mitigates this but adds complexity vs current `go build` |
| **Talent pool** | Erlang + CLIPS is a niche combination. Onboarding is harder than Go |
| **JSON performance** | Erlang's JSON handling (jiffy/jason) is adequate but not as fast as Go's gjson/sjson for surgical JSON manipulation. May matter for high-throughput translation |
| **Ecosystem** | Go has richer HTTP middleware ecosystem (Gin). Cowboy is solid but less "batteries included" |
| **Port overhead** | CLIPS Port process adds IPC latency (~0.1ms per round-trip). Acceptable for conductor decisions (one per request), problematic if overused |
| **Rule ordering** | CLIPS salience-based conflict resolution can produce surprising behavior when rules interact. Need comprehensive rule tests |

### When NOT to use CLIPS

The boundary is clear: if the logic can be expressed as a `case` expression or pattern match in Erlang, it doesn't need CLIPS. Specifically:

- **Protocol translation** — Structural data transformation. Pure Erlang.
- **HTTP routing** — Pattern matching on paths. Cowboy.
- **Config parsing** — YAML/JSON deserialization. Erlang libraries.
- **Token refresh** — Timer-based scheduling. OTP timers.

CLIPS adds value only where you have **multi-factor decisions with interacting state**: credential selection, thinking normalization, quota management, retry decisions.

## Module Structure

```
cli_proxy/
├── apps/
│   ├── cli_proxy/              # Main application
│   │   ├── src/
│   │   │   ├── cli_proxy_app.erl
│   │   │   ├── cli_proxy_sup.erl         # Root supervisor
│   │   │   │
│   │   │   ├── http/                     # Cowboy handlers
│   │   │   │   ├── openai_handler.erl
│   │   │   │   ├── claude_handler.erl
│   │   │   │   ├── gemini_handler.erl
│   │   │   │   ├── responses_handler.erl
│   │   │   │   ├── ws_handler.erl
│   │   │   │   ├── management_handler.erl
│   │   │   │   └── auth_middleware.erl
│   │   │   │
│   │   │   ├── conductor/               # Auth orchestration
│   │   │   │   ├── conductor.erl         # gen_server, CLIPS interaction
│   │   │   │   └── clips_engine.erl      # CLIPS Port wrapper
│   │   │   │
│   │   │   ├── executor/                # Provider executors
│   │   │   │   ├── claude_executor.erl
│   │   │   │   ├── codex_executor.erl
│   │   │   │   ├── gemini_executor.erl
│   │   │   │   ├── vertex_executor.erl
│   │   │   │   ├── antigravity_executor.erl
│   │   │   │   └── openai_compat_executor.erl
│   │   │   │
│   │   │   ├── translator/              # Protocol translation
│   │   │   │   ├── translator.erl        # Registry + dispatch
│   │   │   │   ├── translator_openai_claude.erl
│   │   │   │   ├── translator_claude_gemini.erl
│   │   │   │   ├── translator_openai_gemini.erl
│   │   │   │   └── ...
│   │   │   │
│   │   │   ├── config/                  # Configuration
│   │   │   │   ├── config_watcher.erl
│   │   │   │   ├── config_loader.erl
│   │   │   │   └── config_types.erl
│   │   │   │
│   │   │   ├── registry/                # Model registry
│   │   │   │   ├── model_registry.erl    # gen_server + ETS
│   │   │   │   └── model_updater.erl     # Periodic remote fetch
│   │   │   │
│   │   │   └── store/                   # Storage backends
│   │   │       ├── file_store.erl
│   │   │       ├── pg_store.erl
│   │   │       └── s3_store.erl
│   │   │
│   │   └── priv/
│   │       ├── clips/                   # CLIPS rule files
│   │       │   ├── templates.clp        # Fact templates
│   │       │   ├── selection.clp        # Credential selection rules
│   │       │   ├── cooldown.clp         # Cooldown/quota rules
│   │       │   ├── thinking.clp         # Thinking normalization rules
│   │       │   └── routing.clp          # Model routing rules
│   │       │
│   │       └── models.json              # Embedded model catalog
│   │
│   └── clips_port/                      # CLIPS C port program
│       ├── src/
│       │   ├── main.c                   # stdin/stdout JSON protocol
│       │   └── clips_bridge.c           # CLIPS API wrapper
│       └── Makefile
│
├── config/
│   ├── sys.config                       # Erlang application config
│   ├── vm.args                          # BEAM VM flags
│   └── config.example.yaml             # User config template
│
├── rebar.config                         # Build configuration
└── Dockerfile
```

## Summary

The redesign maps each architectural concern to the paradigm best suited for it:

| Concern | Paradigm | Tool |
|---------|----------|------|
| Concurrency, fault tolerance, distribution | Actor model | Erlang/OTP |
| Multi-factor decisions with state | Rule-based reasoning | CLIPS |
| Structural data transformation | Pattern matching | Erlang |
| HTTP serving | Acceptor pool | Cowboy |
| State isolation | Process per entity | BEAM processes |
| Hot configuration reload | Hot code loading | BEAM native |
| Inter-node communication | Distributed Erlang | BEAM native |

The key insight: the current Go codebase's most complex component (the Auth Conductor at ~5000 lines) is a rule engine fighting to exist inside an imperative language. Making it an actual rule engine doesn't just reduce code — it makes the decision logic auditable, independently testable, and extensible without touching existing rules.

## Testing Strategy (Tests First)

The Erlang reimplementation follows strict TDD: **all tests from the Go codebase are ported and passing BEFORE implementation is considered complete.** The Go test suite contains 142 test files, ~500+ test functions, and 41,668 lines of test code. These are the acceptance criteria for functional equivalence.

### Test framework

| Layer | Framework | Purpose |
|-------|-----------|---------|
| Unit | EUnit | Pure function tests, module-level |
| Integration | Common Test | Multi-process, stateful, HTTP |
| Property | PropEr | Format translation invariants |
| CLIPS rules | EUnit + clips_engine | Rule firing verification |

### Test priority ordering

Tests are implemented in dependency order — lower layers first:

```
Phase 1: CLIPS rules (credential selection, thinking, cooldown)
Phase 2: Translators (format conversion correctness)
Phase 3: Conductor & credential lifecycle (process coordination)
Phase 4: Executors (HTTP integration)
Phase 5: HTTP handlers (end-to-end)
Phase 6: WebSocket (Responses API bidirectional)
Phase 7: Management API, Home, Amp
```

### Phase 1: CLIPS Rule Tests

The CLIPS rules are the system's decision core. Every rule must be testable in isolation.

#### Credential selection tests (ported from `sdk/cliproxy/auth/selector_test.go`, 1455 lines)

```erlang
-module(clips_selection_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Fill-first strategy ---

fill_first_deterministic_test() ->
    %% Always picks alphabetically first active credential
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"a">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({credential, #{id => <<"b">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({credential, #{id => <<"c">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({select_request, #{id => <<"r1">>, model => <<"claude-3">>,
                                           session_id => <<>>, now => now_ts()}}),
    clips_engine:run(),
    ?assertMatch({ok, #{credential_id := <<"a">>}},
                 clips_engine:query(selection_result, <<"r1">>)).

fill_first_priority_fallback_cooldown_test() ->
    %% Falls back to lower priority when high-priority is in cooldown
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"high">>, provider => <<"claude">>,
                                       status => cooldown, priority => 10,
                                       cooldown_until => now_ts() + 3600}}),
    clips_engine:assert({credential, #{id => <<"low">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({select_request, #{id => <<"r1">>, model => <<"claude-3">>,
                                           session_id => <<>>, now => now_ts()}}),
    clips_engine:run(),
    ?assertMatch({ok, #{credential_id := <<"low">>}},
                 clips_engine:query(selection_result, <<"r1">>)).

%% --- Round-robin strategy ---

round_robin_cycles_test() ->
    %% Cycles through credentials: a→b→c→a→b
    clips_engine:reset(),
    [clips_engine:assert({credential, #{id => Id, provider => <<"claude">>,
                                        status => active, priority => 0}})
     || Id <- [<<"a">>, <<"b">>, <<"c">>]],
    Results = [begin
        clips_engine:assert({select_request, #{id => integer_to_binary(I),
                                               model => <<"claude-3">>,
                                               session_id => <<>>, now => now_ts()}}),
        clips_engine:run(),
        {ok, R} = clips_engine:query(selection_result, integer_to_binary(I)),
        clips_engine:retract_transients(integer_to_binary(I)),
        maps:get(credential_id, R)
    end || I <- lists:seq(1, 5)],
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>, <<"a">>, <<"b">>], Results).

%% --- Session affinity ---

session_affinity_prefers_bound_credential_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({credential, #{id => <<"c2">>, provider => <<"claude">>,
                                       status => active, priority => 10}}),
    clips_engine:assert({session_binding, #{session_id => <<"sess1">>,
                                            credential_id => <<"c1">>,
                                            bound_at => now_ts() - 60,
                                            ttl => 3600}}),
    clips_engine:assert({select_request, #{id => <<"r1">>, model => <<"claude-3">>,
                                           session_id => <<"sess1">>, now => now_ts()}}),
    clips_engine:run(),
    %% Should pick c1 (session-bound) despite c2 having higher priority
    ?assertMatch({ok, #{credential_id := <<"c1">>, reason := <<"session-affinity">>}},
                 clips_engine:query(selection_result, <<"r1">>)).

%% --- Exclusion rules ---

exclude_disabled_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                       status => disabled, priority => 10}}),
    clips_engine:assert({credential, #{id => <<"c2">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({select_request, #{id => <<"r1">>, model => <<"claude-3">>,
                                           session_id => <<>>, now => now_ts()}}),
    clips_engine:run(),
    ?assertMatch({ok, #{credential_id := <<"c2">>}},
                 clips_engine:query(selection_result, <<"r1">>)).

exclude_no_websocket_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"codex">>,
                                       status => active, has_websocket => no}}),
    clips_engine:assert({credential, #{id => <<"c2">>, provider => <<"codex">>,
                                       status => active, has_websocket => yes}}),
    clips_engine:assert({select_request, #{id => <<"r1">>, model => <<"gpt-4">>,
                                           need_websocket => yes, now => now_ts()}}),
    clips_engine:run(),
    ?assertMatch({ok, #{credential_id := <<"c2">>}},
                 clips_engine:query(selection_result, <<"r1">>)).

all_cooldown_returns_error_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                       status => cooldown, priority => 0,
                                       cooldown_until => now_ts() + 600}}),
    clips_engine:assert({select_request, #{id => <<"r1">>, model => <<"claude-3">>,
                                           session_id => <<>>, now => now_ts()}}),
    clips_engine:run(),
    ?assertEqual(error, clips_engine:query(selection_result, <<"r1">>)).
```

#### Thinking normalization tests (ported from `test/thinking_conversion_test.go`, 2934 lines, 95 cases)

The thinking test matrix is the largest single test in the Go codebase. It validates budget/level clamping, cross-format conversion, and model-specific constraints.

**Test model definitions:**

```erlang
-module(thinking_test_models).

models() ->
    #{
        <<"level-model">> => #{
            thinking => #{levels => [<<"minimal">>, <<"low">>, <<"medium">>, <<"high">>],
                          zero_allowed => false, dynamic_allowed => false}
        },
        <<"level-subset-model">> => #{
            thinking => #{levels => [<<"low">>, <<"high">>],
                          zero_allowed => false, dynamic_allowed => false}
        },
        <<"gemini-budget-model">> => #{
            thinking => #{min => 128, max => 20000,
                          zero_allowed => false, dynamic_allowed => true}
        },
        <<"gemini-mixed-model">> => #{
            thinking => #{min => 128, max => 32768,
                          levels => [<<"low">>, <<"high">>],
                          zero_allowed => false, dynamic_allowed => true}
        },
        <<"claude-budget-model">> => #{
            thinking => #{min => 1024, max => 128000,
                          zero_allowed => true, dynamic_allowed => false}
        },
        <<"claude-sonnet-4-6-model">> => #{
            thinking => #{min => 1024, max => 128000,
                          levels => [<<"low">>, <<"medium">>, <<"high">>],
                          zero_allowed => false, dynamic_allowed => false}
        },
        <<"claude-opus-4-6-model">> => #{
            thinking => #{min => 1024, max => 128000,
                          levels => [<<"low">>, <<"medium">>, <<"high">>, <<"max">>],
                          zero_allowed => false, dynamic_allowed => false}
        },
        <<"antigravity-budget-model">> => #{
            thinking => #{min => 128, max => 20000,
                          zero_allowed => true, dynamic_allowed => true}
        },
        <<"no-thinking-model">> => #{thinking => undefined},
        <<"user-defined-model">> => #{thinking => undefined, user_defined => true}
    }.
```

**Test case table (complete 95-case matrix):**

```erlang
-module(thinking_conversion_tests).
-include_lib("eunit/include/eunit.hrl").

%% Each case: {From, To, Model, InputJSON, ExpectField, ExpectValue}
%% ExpectValue = {integer, N} | {string, S} | {boolean, B} | absent | error

thinking_matrix_test_() ->
    Cases = [
        %% === Suffix-based tests (model name encodes thinking) ===

        %% Case 1: Level model, valid level suffix
        {openai, claude, <<"level-model(high)">>,
         #{<<"model">> => <<"level-model(high)">>, <<"messages">> => []},
         <<"thinking.budget_tokens">>, absent,  %% Claude uses level, not budget
         <<"reasoning_effort">>, {string, <<"high">>}},

        %% Case 2: Level model, "none" → clamp to "minimal" (ZeroAllowed=false)
        {openai, claude, <<"level-model(none)">>,
         #{<<"model">> => <<"level-model(none)">>, <<"messages">> => []},
         <<"reasoning_effort">>, {string, <<"minimal">>}},

        %% Case 3: Level model, out-of-range → clamp to "high"
        {openai, claude, <<"level-model(xhigh)">>,
         #{<<"model">> => <<"level-model(xhigh)">>, <<"messages">> => []},
         <<"reasoning_effort">>, {string, <<"high">>}},

        %% Case 4: Budget model, numeric suffix
        {openai, gemini, <<"gemini-budget-model(8192)">>,
         #{<<"model">> => <<"gemini-budget-model(8192)">>, <<"messages">> => []},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 8192}},

        %% Case 5: Budget model, exceeds max → clamp to 20000
        {openai, gemini, <<"gemini-budget-model(99999)">>,
         #{<<"model">> => <<"gemini-budget-model(99999)">>, <<"messages">> => []},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 20000}},

        %% Case 6: Budget model, below min → clamp to 128
        {openai, gemini, <<"gemini-budget-model(50)">>,
         #{<<"model">> => <<"gemini-budget-model(50)">>, <<"messages">> => []},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 128}},

        %% Case 7: Budget model with ZeroAllowed=true, 0 stays 0
        {openai, claude, <<"claude-budget-model(0)">>,
         #{<<"model">> => <<"claude-budget-model(0)">>, <<"messages">> => []},
         <<"thinking.budget_tokens">>, {integer, 0}},

        %% Case 8: Budget model with ZeroAllowed=false, 0 → min
        {openai, gemini, <<"gemini-budget-model(0)">>,
         #{<<"model">> => <<"gemini-budget-model(0)">>, <<"messages">> => []},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 128}},

        %% Case 9: DynamicAllowed=true, -1 → -1 (provider decides)
        {openai, gemini, <<"gemini-budget-model(-1)">>,
         #{<<"model">> => <<"gemini-budget-model(-1)">>, <<"messages">> => []},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, -1}},

        %% Case 10: DynamicAllowed=false, -1 → mid-range
        {openai, claude, <<"claude-budget-model(-1)">>,
         #{<<"model">> => <<"claude-budget-model(-1)">>, <<"messages">> => []},
         <<"thinking.budget_tokens">>, {integer, 64512}},  %% (1024+128000)/2

        %% Case 11: No-thinking model, suffix stripped silently
        {openai, claude, <<"no-thinking-model(high)">>,
         #{<<"model">> => <<"no-thinking-model(high)">>, <<"messages">> => []},
         <<"thinking">>, absent},

        %% Case 12: User-defined model, suffix → standard effort passthrough
        {openai, claude, <<"user-defined-model(high)">>,
         #{<<"model">> => <<"user-defined-model(high)">>, <<"messages">> => []},
         <<"reasoning_effort">>, {string, <<"high">>}},

        %% === Body parameter tests ===

        %% Case 13: OpenAI reasoning_effort → Claude thinking
        {openai, claude, <<"claude-sonnet-4-6-model">>,
         #{<<"model">> => <<"claude-sonnet-4-6-model">>,
           <<"messages">> => [], <<"reasoning_effort">> => <<"high">>},
         <<"reasoning_effort">>, {string, <<"high">>}},

        %% Case 14: OpenAI reasoning.effort (Codex format) → Gemini
        {codex, gemini, <<"gemini-budget-model">>,
         #{<<"model">> => <<"gemini-budget-model">>,
           <<"input">> => [], <<"reasoning">> => #{<<"effort">> => <<"high">>}},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 20000}},

        %% Case 15: Claude thinking.budget_tokens → Gemini budget
        {claude, gemini, <<"gemini-budget-model">>,
         #{<<"model">> => <<"gemini-budget-model">>,
           <<"messages">> => [],
           <<"thinking">> => #{<<"type">> => <<"enabled">>, <<"budget_tokens">> => 5000}},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 5000}},

        %% Case 16: Gemini thinkingBudget → Claude budget_tokens
        {gemini, claude, <<"claude-budget-model">>,
         #{<<"model">> => <<"claude-budget-model">>,
           <<"contents">> => [],
           <<"generationConfig">> => #{<<"thinkingConfig">> =>
               #{<<"thinkingBudget">> => 10000}}},
         <<"thinking.budget_tokens">>, {integer, 10000}},

        %% Case 17: Gemini thinkingLevel → Claude effort
        {gemini, claude, <<"claude-sonnet-4-6-model">>,
         #{<<"model">> => <<"claude-sonnet-4-6-model">>,
           <<"contents">> => [],
           <<"generationConfig">> => #{<<"thinkingConfig">> =>
               #{<<"thinkingLevel">> => <<"THINKING_LEVEL_HIGH">>}}},
         <<"reasoning_effort">>, {string, <<"high">>}},

        %% Case 18: includeThoughts=true for Gemini when thinking enabled
        {openai, gemini, <<"gemini-budget-model(8192)">>,
         #{<<"model">> => <<"gemini-budget-model(8192)">>, <<"messages">> => []},
         <<"generationConfig.thinkingConfig.includeThoughts">>, {boolean, true}},

        %% Case 19: includeThoughts=false when budget=0 and ZeroAllowed
        {openai, antigravity, <<"antigravity-budget-model(0)">>,
         #{<<"model">> => <<"antigravity-budget-model(0)">>, <<"messages">> => []},
         <<"request.generationConfig.thinkingConfig.includeThoughts">>, {boolean, false}},

        %% Case 20: Level conversion: "high" → budget for budget-only models
        {openai, gemini, <<"gemini-budget-model">>,
         #{<<"model">> => <<"gemini-budget-model">>,
           <<"messages">> => [], <<"reasoning_effort">> => <<"high">>},
         <<"generationConfig.thinkingConfig.thinkingBudget">>, {integer, 20000}},

        %% Case 21: Budget conversion: 5000 → level for level-only models
        {gemini, claude, <<"level-model">>,
         #{<<"model">> => <<"level-model">>, <<"contents">> => [],
           <<"generationConfig">> => #{<<"thinkingConfig">> =>
               #{<<"thinkingBudget">> => 5000}}},
         <<"reasoning_effort">>, {string, <<"medium">>}},

        %% ... (remaining 74 cases follow same pattern)
        %% Full matrix covers all provider pairs × all model types × edge cases
        placeholder_remaining_cases
    ],
    [build_test(C) || C <- Cases, C =/= placeholder_remaining_cases].

build_test({From, To, Model, Input, Field, Expected}) ->
    Name = io_lib:format("~s→~s ~s", [From, To, Model]),
    {lists:flatten(Name), fun() ->
        %% 1. Parse suffix from model name
        {BaseModel, Suffix} = thinking:parse_suffix(Model),
        %% 2. Register test model in registry
        ModelInfo = maps:get(BaseModel, thinking_test_models:models()),
        %% 3. Translate request
        Translated = translator_registry:translate_request(From, To, Model, Input, true),
        %% 4. Apply thinking normalization via CLIPS
        Final = thinking:apply(Translated, BaseModel, Suffix, ModelInfo, From, To),
        %% 5. Assert field value
        case Expected of
            absent ->
                ?assertEqual(undefined, json_path:get(Final, Field));
            {integer, N} ->
                ?assertEqual(N, json_path:get(Final, Field));
            {string, S} ->
                ?assertEqual(S, json_path:get(Final, Field));
            {boolean, B} ->
                ?assertEqual(B, json_path:get(Final, Field));
            error ->
                ?assertMatch({error, _}, Final)
        end
    end};
build_test({From, To, Model, Input, Field1, Expected1, Field2, Expected2}) ->
    Name = io_lib:format("~s→~s ~s (2 fields)", [From, To, Model]),
    {lists:flatten(Name), fun() ->
        {BaseModel, Suffix} = thinking:parse_suffix(Model),
        ModelInfo = maps:get(BaseModel, thinking_test_models:models()),
        Translated = translator_registry:translate_request(From, To, Model, Input, true),
        Final = thinking:apply(Translated, BaseModel, Suffix, ModelInfo, From, To),
        assert_field(Final, Field1, Expected1),
        assert_field(Final, Field2, Expected2)
    end}.
```

#### MarkResult / cooldown state transition tests

```erlang
-module(clips_cooldown_tests).
-include_lib("eunit/include/eunit.hrl").

mark_success_clears_cooldown_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({model_state, #{credential_id => <<"c1">>,
                                        model => <<"claude-3">>,
                                        available => no,
                                        cooldown_until => now_ts() + 600,
                                        backoff_level => 2}}),
    clips_engine:assert({result, #{credential_id => <<"c1">>,
                                   model => <<"claude-3">>,
                                   status_code => 200, now => now_ts()}}),
    clips_engine:run(),
    %% Model state should be cleared
    ?assertMatch({ok, #{available := yes, backoff_level := 0}},
                 clips_engine:query(model_state, <<"c1">>, <<"claude-3">>)).

mark_429_exponential_backoff_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({model_state, #{credential_id => <<"c1">>,
                                        model => <<"claude-3">>,
                                        available => yes,
                                        cooldown_until => 0,
                                        backoff_level => 0}}),
    Now = now_ts(),
    clips_engine:assert({result, #{credential_id => <<"c1">>,
                                   model => <<"claude-3">>,
                                   status_code => 429, now => Now}}),
    clips_engine:run(),
    {ok, State} = clips_engine:query(model_state, <<"c1">>, <<"claude-3">>),
    ?assertEqual(no, maps:get(available, State)),
    ?assertEqual(1, maps:get(backoff_level, State)),
    %% Cooldown = 2^0 * 1 = 1 second
    ?assert(maps:get(cooldown_until, State) >= Now + 1).

mark_401_30min_hold_test() ->
    clips_engine:reset(),
    clips_engine:assert({credential, #{id => <<"c1">>, provider => <<"claude">>,
                                       status => active, priority => 0}}),
    clips_engine:assert({model_state, #{credential_id => <<"c1">>,
                                        model => <<"claude-3">>,
                                        available => yes,
                                        cooldown_until => 0,
                                        backoff_level => 0}}),
    Now = now_ts(),
    clips_engine:assert({result, #{credential_id => <<"c1">>,
                                   model => <<"claude-3">>,
                                   status_code => 401, now => Now}}),
    clips_engine:run(),
    {ok, State} = clips_engine:query(model_state, <<"c1">>, <<"claude-3">>),
    ?assertEqual(no, maps:get(available, State)),
    %% 30-minute hold
    ?assert(maps:get(cooldown_until, State) >= Now + 1800).
```

### Phase 2: Translator Tests

#### Format conversion correctness (ported from 24+ translator test files)

```erlang
-module(translator_openai_claude_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Request translation ---

basic_messages_test() ->
    Input = #{
        <<"model">> => <<"claude-3-sonnet">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
        ],
        <<"max_tokens">> => 1024,
        <<"stream">> => true
    },
    Result = translator_openai_claude:request(<<"claude-3-sonnet">>, Input, true),
    %% System message extracted to top-level
    ?assertEqual(<<"You are helpful">>, maps:get(<<"system">>, Result)),
    %% Messages only contain user message
    [Msg] = maps:get(<<"messages">>, Result),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)).

tool_calls_translation_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"assistant">>,
              <<"tool_calls">> => [
                  #{<<"id">> => <<"call_1">>,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => <<"search">>,
                        <<"arguments">> => <<"{\"q\":\"test\"}">>
                    }}
              ]}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    [Content] = maps:get(<<"content">>, Msg),
    %% OpenAI tool_calls → Claude tool_use content block
    ?assertEqual(<<"tool_use">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"call_1">>, maps:get(<<"id">>, Content)),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Content)),
    ?assertEqual(#{<<"q">> => <<"test">>}, maps:get(<<"input">>, Content)).

image_url_to_base64_test() ->
    Input = #{
        <<"model">> => <<"claude-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => [
                  #{<<"type">> => <<"image_url">>,
                    <<"image_url">> => #{
                        <<"url">> => <<"data:image/jpeg;base64,/9j/4AAQ...">>
                    }}
              ]}
        ]
    },
    Result = translator_openai_claude:request(<<"claude-3">>, Input, false),
    [Msg] = maps:get(<<"messages">>, Result),
    [Content] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"image">>, maps:get(<<"type">>, Content)),
    Source = maps:get(<<"source">>, Content),
    ?assertEqual(<<"base64">>, maps:get(<<"type">>, Source)),
    ?assertEqual(<<"image/jpeg">>, maps:get(<<"media_type">>, Source)).

%% --- Response translation (streaming) ---

streaming_text_delta_test() ->
    Event = #{<<"type">> => <<"content_block_delta">>,
              <<"index">> => 0,
              <<"delta">> => #{<<"type">> => <<"text_delta">>,
                              <<"text">> => <<"Hello">>}},
    Acc0 = translator_claude_openai:init_acc(),
    {Chunks, _Acc1} = translator_claude_openai:response_stream(Event, Acc0),
    ?assertEqual(1, length(Chunks)),
    [Chunk] = Chunks,
    Decoded = jiffy:decode(Chunk, [return_maps]),
    Delta = hd(maps:get(<<"choices">>, Decoded)),
    ?assertEqual(<<"Hello">>, maps:get(<<"content">>,
                                       maps:get(<<"delta">>, Delta))).

streaming_tool_call_accumulation_test() ->
    Events = [
        #{<<"type">> => <<"content_block_start">>,
          <<"index">> => 0,
          <<"content_block">> => #{<<"type">> => <<"tool_use">>,
                                   <<"id">> => <<"toolu_1">>,
                                   <<"name">> => <<"search">>}},
        #{<<"type">> => <<"content_block_delta">>,
          <<"index">> => 0,
          <<"delta">> => #{<<"type">> => <<"input_json_delta">>,
                          <<"partial_json">> => <<"{\"q\":">>}},
        #{<<"type">> => <<"content_block_delta">>,
          <<"index">> => 0,
          <<"delta">> => #{<<"type">> => <<"input_json_delta">>,
                          <<"partial_json">> => <<"\"test\"}">>}},
        #{<<"type">> => <<"content_block_stop">>, <<"index">> => 0}
    ],
    {AllChunks, _FinalAcc} = lists:foldl(fun(E, {Cs, Acc}) ->
        {NewCs, NewAcc} = translator_claude_openai:response_stream(E, Acc),
        {Cs ++ NewCs, NewAcc}
    end, {[], translator_claude_openai:init_acc()}, Events),
    %% Should produce tool call chunks
    ?assert(length(AllChunks) >= 3).

%% --- Non-streaming response ---

nonstream_full_response_test() ->
    ClaudeResp = #{
        <<"id">> => <<"msg_123">>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"Hello world">>}
        ],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{
            <<"input_tokens">> => 10,
            <<"output_tokens">> => 5
        }
    },
    Result = translator_claude_openai:response_nonstream(ClaudeResp),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Result)),
    [Choice] = maps:get(<<"choices">>, Result),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"Hello world">>, maps:get(<<"content">>, Msg)),
    Usage = maps:get(<<"usage">>, Result),
    ?assertEqual(10, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(5, maps:get(<<"completion_tokens">>, Usage)).
```

#### Built-in tools preservation (ported from `test/builtin_tools_translation_test.go`)

```erlang
-module(builtin_tools_tests).
-include_lib("eunit/include/eunit.hrl").

openai_to_codex_preserves_web_search_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"input">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"search web">>}],
        <<"tools">> => [
            #{<<"type">> => <<"web_search">>,
              <<"search_context_size">> => <<"high">>}
        ],
        <<"tool_choice">> => #{<<"type">> => <<"web_search">>}
    },
    Result = translator_openai_codex:request(<<"gpt-4">>, Input, true),
    Tools = maps:get(<<"tools">>, Result),
    ?assertEqual(1, length(Tools)),
    [Tool] = Tools,
    ?assertEqual(<<"web_search">>, maps:get(<<"type">>, Tool)),
    ?assertEqual(<<"high">>, maps:get(<<"search_context_size">>, Tool)).

openai_responses_to_chat_completions_strips_builtin_tools_test() ->
    Input = #{
        <<"model">> => <<"gpt-4">>,
        <<"input">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
        <<"tools">> => [
            #{<<"type">> => <<"web_search">>},
            #{<<"type">> => <<"function">>, <<"name">> => <<"my_tool">>}
        ]
    },
    Result = translator_openai_responses_openai:request(<<"gpt-4">>, Input, true),
    Tools = maps:get(<<"tools">>, Result, []),
    %% Only function tools preserved in chat-completions format
    ?assertEqual(1, length(Tools)),
    [Tool] = Tools,
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Tool)).
```

#### Claude Code compatibility sentinels (ported from `test/claude_code_compatibility_sentinel_test.go`)

```erlang
-module(claude_code_compat_tests).
-include_lib("eunit/include/eunit.hrl").

tool_progress_shape_test() ->
    {ok, JSON} = file:read_file("test/fixtures/claude_code_sentinels/tool_progress.json"),
    Msg = jiffy:decode(JSON, [return_maps]),
    %% Required fields
    ?assert(maps:is_key(<<"type">>, Msg)),
    ?assert(maps:is_key(<<"tool_use_id">>, Msg)),
    ?assert(maps:is_key(<<"tool_name">>, Msg)),
    ?assert(maps:is_key(<<"session_id">>, Msg)),
    ?assert(maps:is_key(<<"elapsed_time_seconds">>, Msg)),
    ?assertEqual(<<"tool_progress">>, maps:get(<<"type">>, Msg)).

session_state_shape_test() ->
    {ok, JSON} = file:read_file("test/fixtures/claude_code_sentinels/session_state_changed.json"),
    Msg = jiffy:decode(JSON, [return_maps]),
    ?assertEqual(<<"system">>, maps:get(<<"type">>, Msg)),
    ?assertEqual(<<"session_state_changed">>, maps:get(<<"subtype">>, Msg)),
    State = maps:get(<<"state">>, Msg),
    ?assert(lists:member(State, [<<"idle">>, <<"running">>, <<"requires_action">>])).

tool_use_summary_shape_test() ->
    {ok, JSON} = file:read_file("test/fixtures/claude_code_sentinels/tool_use_summary.json"),
    Msg = jiffy:decode(JSON, [return_maps]),
    ?assert(maps:is_key(<<"type">>, Msg)),
    ?assert(maps:is_key(<<"summary">>, Msg)),
    ?assert(is_list(maps:get(<<"preceding_tool_use_ids">>, Msg))).

control_request_can_use_tool_shape_test() ->
    {ok, JSON} = file:read_file(
        "test/fixtures/claude_code_sentinels/control_request_can_use_tool.json"),
    Msg = jiffy:decode(JSON, [return_maps]),
    ?assertEqual(<<"control_request">>, maps:get(<<"type">>, Msg)),
    ?assert(maps:is_key(<<"request_id">>, Msg)),
    Request = maps:get(<<"request">>, Msg),
    ?assert(maps:is_key(<<"subtype">>, Request)),
    ?assert(maps:is_key(<<"tool_name">>, Request)),
    ?assert(maps:is_key(<<"tool_use_id">>, Request)),
    ?assert(maps:is_key(<<"input">>, Request)).
```

### Phase 3: Credential Process Tests

```erlang
-module(credential_proc_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for the gen_statem credential lifecycle

ready_to_cooldown_on_429_test() ->
    {ok, Pid} = credential_proc:start_link(#{
        id => <<"test-cred">>,
        provider => claude,
        metadata => #{<<"access_token">> => <<"sk-test">>}
    }),
    ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
    ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
    ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>)),
    credential_proc:stop(Pid).

cooldown_expires_returns_to_ready_test() ->
    {ok, Pid} = credential_proc:start_link(#{
        id => <<"test-cred">>,
        provider => claude,
        metadata => #{<<"access_token">> => <<"sk-test">>},
        %% Override backoff for fast test
        backoff_base_ms => 50
    }),
    ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
    ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>)),
    %% Wait for backoff to expire (50ms)
    timer:sleep(100),
    ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
    credential_proc:stop(Pid).

success_clears_model_cooldown_test() ->
    {ok, Pid} = credential_proc:start_link(#{
        id => <<"test-cred">>,
        provider => claude,
        metadata => #{<<"access_token">> => <<"sk-test">>}
    }),
    ok = credential_proc:mark_result(Pid, <<"claude-3">>, 429),
    ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"claude-3">>)),
    ok = credential_proc:mark_result(Pid, <<"claude-3">>, 200),
    ?assertEqual(available, credential_proc:get_status(Pid, <<"claude-3">>)),
    credential_proc:stop(Pid).

disabled_is_terminal_test() ->
    {ok, Pid} = credential_proc:start_link(#{
        id => <<"test-cred">>,
        provider => claude,
        metadata => #{<<"access_token">> => <<"sk-test">>}
    }),
    ok = credential_proc:disable(Pid),
    ?assertEqual(disabled, credential_proc:get_status(Pid, <<"claude-3">>)),
    %% Can't transition out of disabled via mark_result
    ok = credential_proc:mark_result(Pid, <<"claude-3">>, 200),
    ?assertEqual(disabled, credential_proc:get_status(Pid, <<"claude-3">>)),
    credential_proc:stop(Pid).

thinking_suffix_shares_model_state_test() ->
    %% "test-model(high)" checks state of "test-model"
    {ok, Pid} = credential_proc:start_link(#{
        id => <<"test-cred">>,
        provider => claude,
        metadata => #{<<"access_token">> => <<"sk-test">>}
    }),
    ok = credential_proc:mark_result(Pid, <<"test-model">>, 429),
    %% Suffixed variant should also be unavailable
    ?assertEqual(unavailable, credential_proc:get_status(Pid, <<"test-model(high)">>)),
    credential_proc:stop(Pid).
```

### Phase 4: Integration Tests (Common Test)

```erlang
-module(proxy_integration_SUITE).
-include_lib("common_test/include/ct.hrl").

all() -> [
    chat_completions_roundtrip,
    streaming_sse_format,
    retry_on_502,
    credential_rotation_on_failure,
    thinking_suffix_e2e,
    responses_api_websocket,
    management_config_crud
].

init_per_suite(Config) ->
    %% Start the full application
    {ok, _} = application:ensure_all_started(cli_proxy),
    %% Start mock upstream servers
    {ok, ClaudeMock} = mock_upstream:start(claude, 9100),
    {ok, GeminiMock} = mock_upstream:start(gemini, 9101),
    {ok, CodexMock} = mock_upstream:start(codex, 9102),
    [{claude_mock, ClaudeMock},
     {gemini_mock, GeminiMock},
     {codex_mock, CodexMock} | Config].

end_per_suite(Config) ->
    mock_upstream:stop(?config(claude_mock, Config)),
    mock_upstream:stop(?config(gemini_mock, Config)),
    mock_upstream:stop(?config(codex_mock, Config)),
    application:stop(cli_proxy),
    Config.

chat_completions_roundtrip(Config) ->
    %% Send OpenAI-format request, verify Claude-format upstream call
    Body = jiffy:encode(#{
        <<"model">> => <<"claude-3-sonnet">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
        <<"max_tokens">> => 100
    }),
    {ok, Status, _Headers, RespBody} =
        hackney:post(<<"http://localhost:8317/v1/chat/completions">>,
                     [{<<"Authorization">>, <<"Bearer test-key">>},
                      {<<"Content-Type">>, <<"application/json">>}],
                     Body, []),
    ?assertEqual(200, Status),
    Resp = jiffy:decode(RespBody, [return_maps]),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Resp)),
    ?assert(length(maps:get(<<"choices">>, Resp)) > 0).

streaming_sse_format(Config) ->
    %% Verify SSE streaming format
    Body = jiffy:encode(#{
        <<"model">> => <<"claude-3-sonnet">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
        <<"stream">> => true
    }),
    {ok, Status, _Headers, ClientRef} =
        hackney:post(<<"http://localhost:8317/v1/chat/completions">>,
                     [{<<"Authorization">>, <<"Bearer test-key">>},
                      {<<"Content-Type">>, <<"application/json">>}],
                     Body, [{recv_timeout, 30000}]),
    ?assertEqual(200, Status),
    %% Read streaming chunks
    Chunks = read_sse_chunks(ClientRef, []),
    ?assert(length(Chunks) > 0),
    %% Last chunk should be [DONE]
    ?assertEqual(<<"[DONE]">>, lists:last(Chunks)).

retry_on_502(Config) ->
    %% First request fails with 502, second succeeds
    mock_upstream:set_responses(?config(claude_mock, Config), [
        {502, <<"Bad Gateway">>},
        {200, mock_claude_response()}
    ]),
    Body = jiffy:encode(#{
        <<"model">> => <<"claude-3-sonnet">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}]
    }),
    {ok, Status, _, _} =
        hackney:post(<<"http://localhost:8317/v1/chat/completions">>,
                     [{<<"Authorization">>, <<"Bearer test-key">>},
                      {<<"Content-Type">>, <<"application/json">>}],
                     Body, []),
    %% Should succeed after retry
    ?assertEqual(200, Status).

responses_api_websocket(Config) ->
    %% Test Responses API WebSocket protocol
    {ok, ConnPid} = gun:open("localhost", 8317),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:ws_upgrade(ConnPid, "/v1/responses",
                               [{<<"authorization">>, <<"Bearer test-key">>}]),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} -> ok
    after 5000 -> ct:fail(ws_upgrade_timeout)
    end,
    %% Send response.create
    Req = jiffy:encode(#{
        <<"type">> => <<"response.create">>,
        <<"model">> => <<"gpt-4">>,
        <<"input">> => [#{<<"type">> => <<"message">>,
                          <<"role">> => <<"user">>,
                          <<"content">> => <<"Hello">>}]
    }),
    gun:ws_send(ConnPid, StreamRef, {text, Req}),
    %% Receive events
    Events = receive_ws_events(ConnPid, StreamRef, []),
    %% Verify event sequence
    Types = [maps:get(<<"type">>, E) || E <- Events, is_map(E)],
    ?assert(lists:member(<<"response.created">>, Types)),
    ?assert(lists:member(<<"response.completed">>, Types)),
    gun:close(ConnPid).
```

### Phase 5: Property-Based Tests (PropEr)

For format translation invariants that must hold across ALL inputs:

```erlang
-module(translator_properties).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Property: translating A→B→A preserves message content
roundtrip_preserves_content_prop() ->
    ?FORALL({Messages, Model},
            {list(message_gen()), model_gen()},
        begin
            Input = #{<<"model">> => Model, <<"messages">> => Messages,
                      <<"max_tokens">> => 1024, <<"stream">> => false},
            %% OpenAI → Claude → OpenAI
            Claude = translator_openai_claude:request(Model, Input, false),
            Back = translator_claude_openai:request(Model, Claude, false),
            %% Core content should be preserved
            extract_texts(Input) =:= extract_texts(Back)
        end).

%% Property: token usage is never negative
usage_non_negative_prop() ->
    ?FORALL(Response, claude_response_gen(),
        begin
            Result = translator_claude_openai:response_nonstream(Response),
            Usage = maps:get(<<"usage">>, Result, #{}),
            maps:get(<<"prompt_tokens">>, Usage, 0) >= 0 andalso
            maps:get(<<"completion_tokens">>, Usage, 0) >= 0
        end).

%% Property: thinking budget always within model bounds after normalization
thinking_clamped_prop() ->
    ?FORALL({Budget, ModelKey},
            {integer(-1, 999999), oneof(maps:keys(thinking_test_models:models()))},
        begin
            Model = maps:get(ModelKey, thinking_test_models:models()),
            case maps:get(thinking, Model) of
                undefined -> true;  %% No thinking = always valid
                #{min := Min, max := Max} ->
                    Result = thinking:clamp_budget(Budget, Min, Max, Model),
                    (Result =:= -1 andalso maps:get(dynamic_allowed, Model, false))
                    orelse (Result =:= 0 andalso maps:get(zero_allowed, Model, false))
                    orelse (Result >= Min andalso Result =< Max)
            end
        end).

%% Generators
message_gen() ->
    oneof([
        #{<<"role">> => <<"user">>, <<"content">> => binary()},
        #{<<"role">> => <<"assistant">>, <<"content">> => binary()}
    ]).

model_gen() ->
    oneof([<<"claude-3-sonnet">>, <<"gpt-4">>, <<"gemini-pro">>]).
```

### Phase 6: WebSocket Protocol Tests

```erlang
-module(responses_ws_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

%% Sequence numbering monotonic
sequence_numbers_monotonic_test() ->
    Events = simulate_response_stream(),
    SeqNums = [maps:get(<<"sequence_number">>, E) || E <- Events,
               maps:is_key(<<"sequence_number">>, E)],
    ?assertEqual(SeqNums, lists:sort(SeqNums)),
    %% Starts at 0
    ?assertEqual(0, hd(SeqNums)).

%% Tool cache repair
tool_cache_repairs_orphaned_output_test() ->
    State0 = responses_ws_handler:init_test_state(),
    %% First request: response includes function_call
    {_Frames1, State1} = responses_ws_handler:handle_response_output(
        [#{<<"type">> => <<"function_call">>,
           <<"call_id">> => <<"call_1">>,
           <<"name">> => <<"search">>,
           <<"arguments">> => <<"{}">>}],
        State0),
    %% Second request: client sends only function_call_output (no matching call)
    Input = [#{<<"type">> => <<"function_call_output">>,
               <<"call_id">> => <<"call_1">>,
               <<"output">> => <<"result">>}],
    Repaired = responses_ws_handler:repair_tool_calls(Input, State1),
    %% Should inject cached function_call before the output
    ?assertEqual(2, length(Repaired)),
    ?assertEqual(<<"function_call">>, maps:get(<<"type">>, hd(Repaired))).

%% Credential unpin on auth error
credential_unpin_on_401_test() ->
    State0 = responses_ws_handler:init_test_state(),
    State1 = State0#state{pinned_auth_id = <<"cred-1">>},
    State2 = responses_ws_handler:maybe_unpin_auth(401, State1),
    ?assertEqual(undefined, State2#state.pinned_auth_id).

credential_stays_pinned_on_200_test() ->
    State0 = responses_ws_handler:init_test_state(),
    State1 = State0#state{pinned_auth_id = <<"cred-1">>},
    State2 = responses_ws_handler:maybe_unpin_auth(200, State1),
    ?assertEqual(<<"cred-1">>, State2#state.pinned_auth_id).
```

### Phase 7: Management & Config Tests

```erlang
-module(management_api_tests).
-include_lib("common_test/include/ct.hrl").

all() -> [
    get_config, put_config, patch_config,
    get_auth_files, upload_auth_file, delete_auth_file,
    toggle_debug, toggle_request_log,
    get_api_keys, put_api_keys,
    routing_strategy_switch,
    quota_exceeded_config,
    amp_model_mappings_crud
].

get_config(Config) ->
    {ok, 200, _, Body} = request(get, "/v0/management/config", Config),
    Resp = jiffy:decode(Body, [return_maps]),
    ?assert(maps:is_key(<<"port">>, Resp)).

routing_strategy_switch(Config) ->
    %% Set to fill-first
    {ok, 200, _, _} = request(put, "/v0/management/routing/strategy",
                              jiffy:encode(<<"fill-first">>), Config),
    %% Verify
    {ok, 200, _, Body} = request(get, "/v0/management/routing/strategy", Config),
    ?assertEqual(<<"\"fill-first\"">>, Body).

amp_model_mappings_crud(Config) ->
    Mappings = [#{<<"from">> => <<"gpt-.*">>,
                  <<"to">> => <<"gpt-4-turbo">>,
                  <<"regex">> => true}],
    {ok, 200, _, _} = request(put, "/v0/management/ampcode/model-mappings",
                              jiffy:encode(Mappings), Config),
    {ok, 200, _, Body} = request(get, "/v0/management/ampcode/model-mappings", Config),
    Result = jiffy:decode(Body, [return_maps]),
    ?assertEqual(1, length(Result)),
    [M] = Result,
    ?assertEqual(<<"gpt-.*">>, maps:get(<<"from">>, M)).
```

### Test execution commands

```bash
## Run all EUnit tests
rebar3 eunit

## Run specific test module
rebar3 eunit --module=clips_selection_tests

## Run Common Test suites
rebar3 ct

## Run specific suite
rebar3 ct --suite=proxy_integration_SUITE

## Run PropEr tests
rebar3 proper

## Run with coverage
rebar3 cover

## Generate coverage report
rebar3 cover --verbose
```

### Coverage targets

| Module group | Target | Rationale |
|--------------|--------|-----------|
| CLIPS rules | 100% | Core decision logic, every rule must fire |
| Translators | 95% | Format conversion correctness is critical |
| Credential proc | 90% | State machine transitions must be complete |
| Conductors | 85% | Orchestration + retry paths |
| HTTP handlers | 80% | Happy path + error paths |
| Config/watcher | 75% | File I/O has edge cases |
| Management API | 70% | CRUD is repetitive |

### CI integration

```yaml
# In .github/workflows/test.yml or equivalent
steps:
  - name: Compile
    run: rebar3 compile

  - name: CLIPS port
    run: cd apps/clips_port && make && make test

  - name: EUnit (fast, no external deps)
    run: rebar3 eunit

  - name: Common Test (integration, needs mock servers)
    run: rebar3 ct

  - name: PropEr (property-based, may find edge cases)
    run: rebar3 proper --numtests 1000

  - name: Coverage check
    run: |
      rebar3 cover
      # Fail if below 80% overall
      rebar3 cover --min_coverage 80

  - name: Dialyzer (type checking)
    run: rebar3 dialyzer
```

### Test fixtures directory

```
test/
├── fixtures/
│   ├── claude_code_sentinels/
│   │   ├── tool_progress.json
│   │   ├── session_state_changed.json
│   │   ├── tool_use_summary.json
│   │   └── control_request_can_use_tool.json
│   │
│   ├── requests/                    # Sample request payloads
│   │   ├── openai_chat_basic.json
│   │   ├── openai_chat_tools.json
│   │   ├── openai_chat_vision.json
│   │   ├── claude_messages_basic.json
│   │   ├── gemini_generate_basic.json
│   │   ├── responses_create.json
│   │   └── responses_append_with_tool.json
│   │
│   ├── responses/                   # Expected response payloads
│   │   ├── claude_stream_events.jsonl
│   │   ├── openai_stream_chunks.jsonl
│   │   ├── gemini_stream_chunks.jsonl
│   │   └── responses_ws_events.jsonl
│   │
│   ├── configs/                     # Test configuration files
│   │   ├── minimal.yaml
│   │   ├── full.yaml
│   │   ├── home_mode.yaml
│   │   └── amp_enabled.yaml
│   │
│   └── auth_files/                  # Mock auth credential files
│       ├── claude_test.json
│       ├── codex_test.json
│       ├── gemini_test.json
│       └── kimi_test.json
│
├── mock_upstream.erl                # Configurable mock HTTP/WS server
├── test_helpers.erl                 # Common assertion helpers
└── thinking_test_models.erl         # Model definitions for thinking tests
```

---

## Protocol Translation Architecture

### The Go problem

The Go translator is a 107-file matrix of hand-written `init()` registrations, one file per (source, target, variant) triple. Each translator manipulates raw JSON via gjson/sjson — fast, but the code is repetitive and has no shared structure. Streaming translation carries state through a `param *any` pointer cast to a per-translator struct, requiring every translator to manage its own accumulator lifecycle.

The full translation matrix covers 6 provider formats and 2 API variants:

| From \ To | Claude | Gemini | GeminiCLI | Codex | OpenAI (chat) | OpenAI (responses) |
|-----------|--------|--------|-----------|-------|---------------|-------------------|
| **Claude** | — | ✓ | ✓ | — | ✓ | ✓ |
| **Gemini** | ✓ | ✓ | ✓ | — | ✓ | ✓ |
| **GeminiCLI** | ✓ | ✓ | — | — | ✓ | ✓ |
| **Codex** | ✓ | ✓ | ✓ | — | ✓ | ✓ |
| **OpenAI** | ✓ | ✓ | ✓ | — | ✓ | ✓ |
| **Antigravity** | ✓ | ✓ | — | — | ✓ | ✓ |

Each cell is two functions (request + response), with response further split into streaming and non-streaming variants. That's ~28 translator pairs × 3 functions = ~84 translation functions.

### Erlang redesign

Translators become Erlang callback modules implementing a `translator` behaviour. The behaviour enforces a common interface; each module is a pure-function transformer with no state:

```erlang
-module(translator).

%% Behaviour callbacks
-callback request(ModelName :: binary(), Body :: map(), Stream :: boolean()) ->
    map().

-callback response_stream(Event :: map(), Acc :: term()) ->
    {[iodata()], NewAcc :: term()}.

-callback response_nonstream(Body :: map()) ->
    map().

-callback init_acc() -> term().
```

**Registration** happens at application startup via a registry `gen_server` backed by an ETS table:

```erlang
-module(translator_registry).
-behaviour(gen_server).

%% Called from each translator module's module_info or app startup
-spec register(From :: atom(), To :: atom(), Module :: module()) -> ok.
register(From, To, Module) ->
    ets:insert(?TABLE, {{From, To}, Module}).

%% Runtime dispatch
-spec get(From :: atom(), To :: atom()) -> {ok, module()} | error.
get(From, To) ->
    case ets:lookup(?TABLE, {From, To}) of
        [{{From, To}, Mod}] -> {ok, Mod};
        [] -> error
    end.
```

**Startup registration** in the application supervisor:

```erlang
init([]) ->
    translator_registry:start_link(),
    %% Each module registers itself
    translator_openai_claude:register(),
    translator_claude_openai:register(),
    translator_claude_openai_responses:register(),
    %% ... all pairs
    {ok, {#{strategy => one_for_one}, []}}.
```

Where a concrete translator module looks like:

```erlang
-module(translator_openai_claude).
-behaviour(translator).

register() ->
    translator_registry:register(openai, claude, ?MODULE),
    translator_registry:register(openai_response, claude, ?MODULE).

request(Model, #{<<"messages">> := Messages} = Body, Stream) ->
    #{
        <<"model">> => Model,
        <<"messages">> => [translate_message(M) || M <- Messages],
        <<"max_tokens">> => maps:get(<<"max_tokens">>, Body, 4096),
        <<"stream">> => Stream
    }.

init_acc() ->
    #{tool_calls => #{}, usage => #{}, response_id => <<>>}.

response_stream(#{<<"type">> := <<"message_start">>} = Event, Acc) ->
    Id = maps:get(<<"id">>, maps:get(<<"message">>, Event, #{}), <<>>),
    Chunk = build_openai_chunk(Id, <<>>, <<>>),
    {[Chunk], Acc#{response_id => Id}};

response_stream(#{<<"type">> := <<"content_block_delta">>,
                   <<"delta">> := #{<<"text">> := Text}}, Acc) ->
    Chunk = build_openai_chunk(maps:get(response_id, Acc), Text, <<>>),
    {[Chunk], Acc};

response_stream(#{<<"type">> := <<"message_delta">>} = Event, Acc) ->
    %% Final chunk with usage and finish_reason
    {[build_final_chunk(Event, Acc)], Acc};

response_stream(_Event, Acc) ->
    {[], Acc}.  %% Ignore unknown events

response_nonstream(#{<<"content">> := Content} = Body) ->
    %% Full response transformation — pure function, no accumulator
    #{
        <<"id">> => maps:get(<<"id">>, Body, <<>>),
        <<"object">> => <<"chat.completion">>,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => extract_text(Content)
            },
            <<"finish_reason">> => translate_stop_reason(Body)
        }],
        <<"usage">> => translate_usage(Body)
    }.
```

### Streaming: process mailbox replaces `param *any`

In Go, streaming state is a void pointer cast to a per-translator struct, threaded through every chunk call. In Erlang, the streaming translation runs inside the request-handling process. The accumulator is just a local variable in a `receive` loop — no casting, no shared mutable pointer:

```erlang
%% In the request handler process
stream_translate(From, To, ConnRef, StreamRef, Caller) ->
    {ok, Mod} = translator_registry:get(From, To),
    Acc0 = Mod:init_acc(),
    stream_loop(Mod, ConnRef, StreamRef, Caller, Acc0).

stream_loop(Mod, ConnRef, StreamRef, Caller, Acc) ->
    receive
        {gun_data, ConnRef, StreamRef, nofin, Data} ->
            Events = parse_sse(Data),
            {Chunks, Acc1} = lists:foldl(
                fun(Event, {ChunksAcc, AccIn}) ->
                    {NewChunks, AccOut} = Mod:response_stream(Event, AccIn),
                    {ChunksAcc ++ NewChunks, AccOut}
                end, {[], Acc}, Events),
            [Caller ! {stream_chunk, C} || C <- Chunks],
            stream_loop(Mod, ConnRef, StreamRef, Caller, Acc1);
        {gun_data, ConnRef, StreamRef, fin, Data} ->
            Events = parse_sse(Data),
            {Chunks, _} = lists:foldl(
                fun(Event, {ChunksAcc, AccIn}) ->
                    {NewChunks, AccOut} = Mod:response_stream(Event, AccIn),
                    {ChunksAcc ++ NewChunks, AccOut}
                end, {[], Acc}, Events),
            [Caller ! {stream_chunk, C} || C <- Chunks],
            Caller ! stream_done;
        {gun_error, ConnRef, StreamRef, Reason} ->
            Caller ! {stream_error, Reason}
    end.
```

### Translation concerns

Each translator module handles these cross-cutting concerns:

| Concern | Pattern |
|---------|---------|
| **Tool/function calls** | Claude `tool_use` blocks ↔ OpenAI `tool_calls` array ↔ Gemini `functionCall` parts. ID mapping maintained in accumulator. |
| **Thinking blocks** | Claude `thinking` content ↔ OpenAI `reasoning_content` ↔ Gemini `thinkingConfig`. Signature validation delegated to `signature_cache` module. |
| **Vision/images** | Claude `{type: image, source: {type: base64}}` ↔ OpenAI `{type: image_url, image_url: {url: "data:..."}}` ↔ Gemini `{inline_data: {mime_type, data}}`. |
| **System messages** | Claude separates `system` from `messages`. OpenAI/Gemini embed in message array. |
| **Stop reasons** | `end_turn` ↔ `stop` ↔ `STOP`, `max_tokens` ↔ `length` ↔ `MAX_TOKENS`, etc. |
| **Token usage** | Field name mapping: `input_tokens` ↔ `prompt_tokens`, `output_tokens` ↔ `completion_tokens`, cache fields. |

### Responses API translation

The OpenAI Responses API (`/v1/responses`) is a distinct format from chat-completions. It uses `instructions` + `input` array instead of `messages`, and tool calls are `function_call` / `function_call_output` items rather than message-embedded blocks.

Translation to/from Responses format is handled by dedicated translator modules (e.g., `translator_openai_responses_claude`) that convert between the two structural paradigms:

```erlang
-module(translator_openai_responses_claude).
-behaviour(translator).

request(Model, #{<<"instructions">> := Inst, <<"input">> := Input} = Body, Stream) ->
    %% instructions → system parameter
    %% input array → messages array
    SystemMsg = Inst,
    Messages = [convert_responses_input(I) || I <- Input],
    #{
        <<"model">> => Model,
        <<"system">> => SystemMsg,
        <<"messages">> => Messages,
        <<"stream">> => Stream
    };
request(Model, Body, Stream) ->
    %% Fallback: treat as regular openai → claude
    translator_openai_claude:request(Model, Body, Stream).
```

## OAuth & Login Flows

### The Go problem

Each provider has its own OAuth package (`internal/auth/{claude,codex,gemini,antigravity,kimi}/`) with independent HTTP server startup, callback handling, and state management. The flows are structurally similar (start local server → open browser → wait for callback → exchange code → persist token) but share no code. The Codex device-code flow adds polling logic. There's no unified state machine — each flow is a linear function with error returns.

### Provider OAuth parameters

| Provider | Flow type | Client ID | Callback port | Scopes | Refresh lead |
|----------|-----------|-----------|---------------|--------|-------------|
| **Claude** | Authorization Code + PKCE | `9d1c250a-...` | 54545 | (implicit) | 4 hours |
| **Codex** | Authorization Code + PKCE | `app_EMoamEEZ...` | 1455 | openid email profile offline_access | 5 days |
| **Codex** (alt) | Device Code (RFC 8628) | same | — | same | 5 days |
| **Gemini** | Authorization Code (golang.org/x/oauth2) | `681255809395-...` | 8085 | cloud-platform, userinfo.email, userinfo.profile | token-internal |
| **Antigravity** | Authorization Code | (constants) | configurable | (implicit) | 5 minutes |
| **Kimi** | Device Code (RFC 8628) | `17e5f671-...` | — | (implicit) | 5 minutes |
| **Vertex** | Service Account Import | — | — | — | N/A |

### Erlang redesign: `gen_statem` per login session

Each login attempt is a `gen_statem` process with well-defined states. This replaces the linear Go functions with a supervised, crash-recoverable state machine:

```
                          ┌─────────────────────────────────┐
                          │        oauth_session            │
                          │       (gen_statem)              │
                          │                                 │
    start_link(Provider,  │   idle ──► awaiting_callback    │
      Config)             │            │         │          │
         │                │            │    timeout (5min)  │
         ▼                │            ▼         ▼          │
    ┌─────────┐           │   exchanging    failed          │
    │  idle    │           │      │                          │
    │         │           │      ▼                          │
    │ Opens   │           │   persisting ──► done           │
    │ browser │           │                                 │
    └─────────┘           └─────────────────────────────────┘
```

```erlang
-module(oauth_session).
-behaviour(gen_statem).

-record(data, {
    provider    :: atom(),           %% claude | codex | gemini | antigravity | kimi
    config      :: map(),
    state_token :: binary(),         %% CSRF state parameter
    code_verifier :: binary(),       %% PKCE (when applicable)
    caller      :: pid()             %% Process waiting for result
}).

%% States
-type state() :: idle | awaiting_callback | awaiting_device_poll
               | exchanging | persisting | done | failed.

callback_mode() -> [state_functions, state_enter].

%% --- idle ---
idle(enter, _OldState, Data) ->
    {AuthURL, StateToken, Verifier} = build_auth_url(Data#data.provider, Data#data.config),
    maybe_open_browser(AuthURL, Data#data.config),
    {keep_state, Data#data{state_token = StateToken, code_verifier = Verifier},
     [{state_timeout, 300_000, login_timeout}]};  %% 5 min timeout

idle(state_timeout, login_timeout, Data) ->
    {next_state, failed, Data}.

%% Cowboy callback handler sends this message
idle(info, {oauth_callback, StateToken, Code}, #data{state_token = StateToken} = Data) ->
    {next_state, exchanging, Data#{code => Code}};

%% Device code flow: poll instead of wait for callback
idle(info, start_device_poll, Data) ->
    {next_state, awaiting_device_poll, Data}.

%% --- awaiting_device_poll (Codex device code, Kimi) ---
awaiting_device_poll(enter, _OldState, Data) ->
    {keep_state, Data, [{state_timeout, 5_000, poll}]};

awaiting_device_poll(state_timeout, poll, Data) ->
    case poll_device_token(Data#data.provider, Data#data.config) of
        {ok, TokenData} ->
            {next_state, persisting, Data#{token_data => TokenData}};
        {error, authorization_pending} ->
            {keep_state, Data, [{state_timeout, 5_000, poll}]};
        {error, slow_down} ->
            {keep_state, Data, [{state_timeout, 10_000, poll}]};
        {error, expired_token} ->
            {next_state, failed, Data};
        {error, _Reason} ->
            {next_state, failed, Data}
    end.

%% --- exchanging (authorization code → tokens) ---
exchanging(enter, _OldState, #{code := Code} = Data) ->
    case exchange_code(Data#data.provider, Code, Data#data.code_verifier, Data#data.config) of
        {ok, TokenData} ->
            {next_state, persisting, Data#{token_data => TokenData}};
        {error, _Reason} ->
            {next_state, failed, Data}
    end.

%% --- persisting (write token to storage) ---
persisting(enter, _OldState, #{token_data := TokenData} = Data) ->
    ok = auth_store:save(Data#data.provider, TokenData),
    %% Notify conductor to register new credential
    clips_engine:assert({credential, token_to_credential(Data#data.provider, TokenData)}),
    {next_state, done, Data}.

%% --- done ---
done(enter, _OldState, Data) ->
    Data#data.caller ! {oauth_complete, self(), ok},
    {stop, normal}.

%% --- failed ---
failed(enter, _OldState, Data) ->
    Data#data.caller ! {oauth_complete, self(), error},
    {stop, normal}.
```

The callback handler in Cowboy routes the OAuth redirect to the waiting `gen_statem`:

```erlang
-module(oauth_callback_handler).

init(Req, State) ->
    Provider = cowboy_req:binding(provider, Req),
    Code = cowboy_req:qs_val(<<"code">>, Req),
    StateToken = cowboy_req:qs_val(<<"state">>, Req),
    %% Find the waiting session by state token
    case oauth_session_registry:find(StateToken) of
        {ok, Pid} ->
            Pid ! {oauth_callback, StateToken, Code},
            {ok, reply_success(Req), State};
        error ->
            {ok, reply_error(Req, <<"Unknown state token">>), State}
    end.
```

### Per-provider exchange functions

Provider-specific logic lives in pure modules (no processes), called by the `gen_statem`:

```erlang
-module(oauth_claude).
-export([auth_url/1, exchange/3, refresh/1]).

auth_url(Config) ->
    Verifier = crypto:strong_rand_bytes(96),
    Challenge = base64url:encode(crypto:hash(sha256, Verifier)),
    State = base64url:encode(crypto:strong_rand_bytes(32)),
    URL = iolist_to_binary([
        <<"https://claude.ai/oauth/authorize">>,
        <<"?client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e">>,
        <<"&redirect_uri=http://localhost:54545/callback">>,
        <<"&response_type=code">>,
        <<"&code_challenge=">>, Challenge,
        <<"&code_challenge_method=S256">>,
        <<"&state=">>, State
    ]),
    {URL, State, Verifier}.

exchange(Code, Verifier, _Config) ->
    Body = #{
        <<"grant_type">> => <<"authorization_code">>,
        <<"client_id">> => <<"9d1c250a-e61b-44d9-88ed-5944d1962f5e">>,
        <<"code">> => Code,
        <<"code_verifier">> => Verifier,
        <<"redirect_uri">> => <<"http://localhost:54545/callback">>
    },
    case hackney:post(<<"https://api.anthropic.com/v1/oauth/token">>,
                      [{<<"Content-Type">>, <<"application/json">>}],
                      jiffy:encode(Body), []) of
        {ok, 200, _, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            {ok, jiffy:decode(RespBody, [return_maps])};
        {ok, Status, _, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            {error, {Status, RespBody}}
    end.
```

### Auth file storage structure

Each provider persists tokens as a JSON file. The common wrapper in Erlang:

```erlang
-record(auth_file, {
    id          :: binary(),         %% unique identifier
    provider    :: atom(),           %% claude | codex | gemini | ...
    filename    :: binary(),         %% path to backing file
    disabled    :: boolean(),
    metadata    :: map(),            %% provider-specific token data
    attributes  :: map(),            %% provider-specific config
    created_at  :: integer(),        %% unix timestamp
    updated_at  :: integer(),
    last_refreshed_at :: integer()
}).
```

Provider-specific metadata fields:

| Provider | Key fields |
|----------|-----------|
| **Claude** | `id_token`, `access_token`, `refresh_token`, `email`, `expired` |
| **Codex** | `access_token`, `refresh_token`, `id_token`, `token_type`, `expires_in` |
| **Gemini** | `token` (nested: `access_token`, `expiry`), `project_id`, `email`, `auto`, `checked` |
| **Kimi** | `access_token`, `refresh_token`, `token_type`, `scope`, `device_id`, `expired` |
| **Antigravity** | `access_token`, `refresh_token`, `expires_in`, `token_type` |
| **Vertex** | `service_account` (full JSON key), `project_id`, `email`, `location`, `prefix` |

## Token Refresh Architecture

### The Go problem

The Go auto-refresh system is a mini scheduler built from scratch: a min-heap priority queue, a fixed worker pool (16 goroutines), a dirty-set with wake channel for incremental updates, and a 5-second polling loop. Each provider has a different refresh lead time and backoff strategy. The state machine (Ready/Cooldown/Blocked/Disabled) is encoded in struct fields and checked with conditional branches.

### Erlang redesign: process-per-credential

Instead of a central scheduler dispatching work to a thread pool, **each credential is its own process**. This is the natural Erlang pattern — the BEAM handles tens of thousands of lightweight processes. Each credential process knows when it needs refreshing and schedules its own timer.

```
                    provider_sup (one_for_one)
                   ┌──────┼──────────┐
                   │      │          │
            claude_executor  ...   credential_sup (simple_one_for_one)
                                    ├── credential_1 (gen_statem)
                                    ├── credential_2 (gen_statem)
                                    ├── credential_3 (gen_statem)
                                    └── ...
```

### Credential lifecycle as `gen_statem`

Each credential process is a state machine with four states, directly mapping the Go scheduler's `scheduledState*` enum:

```
    ┌────────────────────────────────────────────────────┐
    │              credential (gen_statem)                │
    │                                                    │
    │   ┌───────┐   success    ┌───────────┐             │
    │   │ ready │◄────────────│ refreshing │             │
    │   │       │──────────►  │            │             │
    │   └───┬───┘  timer      └─────┬──────┘             │
    │       │                       │ failure             │
    │       │ 429/quota             ▼                     │
    │       │               ┌────────────┐               │
    │       └──────────────►│  cooldown   │               │
    │                       │ (backoff)   │               │
    │                       └──────┬─────┘               │
    │                              │ timer expires        │
    │                              ▼                      │
    │                         back to ready               │
    │                                                    │
    │   ┌──────────┐                                     │
    │   │ disabled │  (operator action, terminal)        │
    │   └──────────┘                                     │
    └────────────────────────────────────────────────────┘
```

```erlang
-module(credential_proc).
-behaviour(gen_statem).

-record(data, {
    id              :: binary(),
    provider        :: atom(),
    metadata        :: map(),           %% token data
    backoff_level   :: non_neg_integer(),
    last_error      :: term(),
    model_states    :: #{binary() => model_state()},
    refresh_module  :: module()         %% oauth_claude | oauth_codex | ...
}).

callback_mode() -> [state_functions, state_enter].

%% ── ready ──
ready(enter, _OldState, Data) ->
    Delay = calc_refresh_delay(Data),
    {keep_state, Data, [{state_timeout, Delay, time_to_refresh}]};

ready(state_timeout, time_to_refresh, Data) ->
    {next_state, refreshing, Data};

ready({call, From}, {get_status, _Model}, Data) ->
    {keep_state, Data, [{reply, From, available}]};

ready({call, From}, {mark_result, Model, StatusCode}, Data) ->
    case classify_status(StatusCode) of
        ok ->
            Data1 = clear_model_cooldown(Model, Data),
            {keep_state, Data1, [{reply, From, ok}]};
        rate_limited ->
            Data1 = set_model_cooldown(Model, Data),
            {keep_state, Data1, [{reply, From, cooldown}]};
        auth_error ->
            Data1 = set_model_cooldown(Model, Data),
            {next_state, cooldown, Data1, [{reply, From, cooldown}]}
    end.

%% ── refreshing ──
refreshing(enter, _OldState, Data) ->
    %% Spawn a linked process for the HTTP call so we don't block the statem
    Self = self(),
    spawn_link(fun() ->
        Result = (Data#data.refresh_module):refresh(Data#data.metadata),
        gen_statem:cast(Self, {refresh_result, Result})
    end),
    {keep_state, Data, [{state_timeout, 60_000, refresh_timeout}]};

refreshing(cast, {refresh_result, {ok, NewMetadata}}, Data) ->
    %% Persist updated tokens
    auth_store:update(Data#data.id, NewMetadata),
    %% Update CLIPS facts
    clips_engine:retract({credential, Data#data.id}),
    clips_engine:assert({credential, metadata_to_credential(Data, NewMetadata)}),
    {next_state, ready, Data#data{
        metadata = NewMetadata,
        backoff_level = 0,
        last_error = undefined
    }};

refreshing(cast, {refresh_result, {error, Reason}}, Data) ->
    {next_state, cooldown, Data#data{last_error = Reason}};

refreshing(state_timeout, refresh_timeout, Data) ->
    {next_state, cooldown, Data#data{last_error = timeout}}.

%% ── cooldown ──
cooldown(enter, _OldState, Data) ->
    Delay = backoff_delay(Data#data.backoff_level),
    {keep_state, Data#data{backoff_level = Data#data.backoff_level + 1},
     [{state_timeout, Delay, cooldown_expired}]};

cooldown(state_timeout, cooldown_expired, Data) ->
    {next_state, ready, Data};

cooldown({call, From}, {get_status, _Model}, Data) ->
    {keep_state, Data, [{reply, From, unavailable}]}.

%% ── disabled ──
disabled(enter, _OldState, _Data) ->
    keep_state_and_data;

disabled({call, From}, {get_status, _Model}, _Data) ->
    {keep_state_and_data, [{reply, From, disabled}]};

disabled(cast, enable, Data) ->
    {next_state, ready, Data#data{backoff_level = 0}}.

%% ── Helpers ──

calc_refresh_delay(#data{provider = claude, metadata = M}) ->
    %% Claude: 4 hours before expiry
    Expiry = maps:get(<<"expired">>, M, 0),
    max(0, (Expiry - erlang:system_time(second) - 4 * 3600)) * 1000;
calc_refresh_delay(#data{provider = codex, metadata = M}) ->
    %% Codex: 5 days before expiry
    ExpiresIn = maps:get(<<"expires_in">>, M, 3600),
    max(0, ExpiresIn - 5 * 86400) * 1000;
calc_refresh_delay(#data{provider = Provider}) when Provider =:= antigravity;
                                                     Provider =:= kimi ->
    %% 5 minutes before expiry
    300_000;
calc_refresh_delay(_) ->
    3_600_000.  %% Default: check hourly

backoff_delay(Level) ->
    %% Exponential backoff: 5s, 10s, 20s, 40s, ... capped at 5 minutes
    min(5_000 * (1 bsl Level), 300_000).

classify_status(S) when S >= 200, S < 300 -> ok;
classify_status(429) -> rate_limited;
classify_status(S) when S =:= 401; S =:= 402; S =:= 403 -> auth_error;
classify_status(S) when S >= 500 -> retriable_error;
classify_status(_) -> ok.
```

### Why process-per-credential beats a worker pool

| Go worker pool | Erlang process-per-credential |
|----------------|-------------------------------|
| Central min-heap + dirty set + wake channel | Each process has its own timer — no central bookkeeping |
| Fixed 16 workers — 17th refresh waits | No worker contention — BEAM schedules thousands of processes |
| Shared state behind `sync.Mutex` | No shared state — each process owns its credential |
| Manual lifecycle (add/remove from heap) | Start/stop supervised child processes |
| `singleflight.Group` to deduplicate | Naturally deduplicated — one process per credential |
| State checked via field inspection | State is the process's current state function |

### Per-model state

Each credential process maintains per-model cooldowns in its `model_states` map. When the conductor asks "is credential C available for model M?", it calls the credential process:

```erlang
%% In conductor
is_available(CredentialPid, Model) ->
    gen_statem:call(CredentialPid, {get_status, Model}).
```

This replaces the Go pattern of checking `Auth.ModelStates[model]` behind a read lock. The credential process serializes access to its own state — no locks needed.

### Integration with CLIPS

The credential process keeps CLIPS facts in sync. On state change, it retracts the old fact and asserts the new one:

```erlang
update_clips_state(Data, NewStatus) ->
    clips_engine:retract({credential, Data#data.id}),
    clips_engine:assert({credential, #{
        id => Data#data.id,
        provider => Data#data.provider,
        status => NewStatus,
        cooldown_until => calc_cooldown_until(Data),
        priority => maps:get(<<"priority">>, Data#data.metadata, 0)
    }}).
```

The CLIPS engine sees credential state changes as fact updates — its rules automatically re-evaluate without any callback chain.

## Missing Providers

The initial design covers Claude, Codex, Gemini, Vertex, Antigravity, and OpenAI-compatible executors. Four additional provider types exist in the Go codebase:

### Kimi (Moonshot AI)

Kimi uses Device Code Flow (RFC 8628) for login, and a standard REST executor for inference. The executor follows the same `gen_server` pattern as other providers:

```erlang
-module(kimi_executor).
-behaviour(gen_server).

init([Config]) ->
    {ok, #{config => Config, pool => start_pool(kimi_pool, 20)}}.

handle_call({execute, Auth, Request, Opts}, From, State) ->
    spawn_link(fun() ->
        Headers = [{<<"Authorization">>, <<"Bearer ", (maps:get(<<"access_token">>, Auth))/binary>>}],
        Result = do_http_request(<<"https://api.moonshot.cn/v1/chat/completions">>,
                                 Headers, Request, State),
        gen_server:reply(From, Result)
    end),
    {noreply, State}.
```

### Gemini CLI

Gemini CLI is distinct from the Gemini API — it uses an internal endpoint (`/v1internal:method`) and has its own OAuth flow and state management. The executor handles the CLI-specific request format:

```erlang
-module(gemini_cli_executor).
-behaviour(gen_server).

-record(state, {
    config :: map(),
    pool   :: pid(),
    %% CLI-specific state
    session_state :: map()    %% per-session command history
}).
```

### AI Studio (WebSocket runtime credentials)

AI Studio credentials are dynamic — they arrive via WebSocket connections and are registered at runtime. The WebSocket handler asserts a credential into CLIPS on connect and retracts on disconnect:

```erlang
-module(aistudio_ws_handler).
-behaviour(cowboy_websocket).

websocket_init(State) ->
    AuthId = generate_auth_id(),
    clips_engine:assert({credential, #{
        id => AuthId, provider => <<"aistudio">>,
        status => active, has_websocket => yes
    }}),
    {ok, State#{auth_id => AuthId}}.

websocket_terminate(_Reason, _Req, #{auth_id := AuthId}) ->
    clips_engine:retract({credential, AuthId}),
    ok.
```

### Codex WebSocket (Responses API over WS)

Codex supports the Responses API over WebSocket for real-time bidirectional communication. This is architecturally different from SSE streaming — the WebSocket process handles both request dispatch and response streaming in a single connection:

```erlang
-module(codex_ws_executor).
-behaviour(gen_server).

%% Manages a pool of persistent WebSocket connections to the Codex backend
%% Each connection is a process that can handle multiple requests

handle_call({execute_ws, Auth, Request, Opts}, From, State) ->
    Conn = get_or_create_connection(Auth, State),
    Conn ! {send_request, Request, From},
    {noreply, State}.
```

## Management API

### The Go problem

The Go codebase has 40+ management endpoints spread across 14 handler files, each registering routes manually in `server.go`. The authentication is a custom middleware with rate limiting, bcrypt comparison, and IP-based tracking.

### Erlang redesign

Management becomes a dedicated Cowboy route group with its own middleware pipeline. The routes are organized by concern:

```erlang
-module(management_routes).

routes() ->
    [{"/v0/management/[...]", management_handler, []}].

%% management_handler dispatches by path and method
init(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    %% Auth check first
    case management_auth:check(Req) of
        ok -> dispatch(Method, Path, Req, State);
        {error, Reason} -> reply_error(Req, 401, Reason)
    end.
```

### Endpoint groups

| Group | Endpoints | Purpose |
|-------|-----------|---------|
| **Config** | `GET/PUT/PATCH /config`, `GET/PUT /config.yaml` | Full config CRUD |
| **Auth files** | `GET/POST/DELETE /auth-files`, `PATCH .../status`, `PATCH .../fields` | Credential management |
| **API keys** | `GET/PUT/PATCH/DELETE /api-keys`, `GET /api-key-usage` | Access control |
| **Provider keys** | `*/gemini-api-key`, `*/claude-api-key`, `*/codex-api-key`, `*/openai-compatibility`, `*/vertex-api-key` | Direct API key management |
| **OAuth** | `GET /{provider}-auth-url`, `POST /oauth-callback`, `GET /get-auth-status` | Login flow initiation |
| **Routing** | `*/routing/strategy`, `*/oauth-excluded-models`, `*/oauth-model-alias` | Credential selection tuning |
| **Logging** | `*/debug`, `*/logging-to-file`, `*/request-log`, `GET/DELETE /logs` | Diagnostics |
| **Quota** | `*/quota-exceeded/switch-project`, `*/quota-exceeded/switch-preview-model` | Overflow behavior |
| **Amp CLI** | `*/ampcode/*` | Amp routing config |
| **Vertex** | `POST /vertex/import` | Service account import |

### Management authentication

```erlang
-module(management_auth).

check(Req) ->
    Key = extract_key(Req),
    ClientIP = cowboy_req:peer(Req),
    case is_localhost(ClientIP) of
        true  -> check_local(Key);
        false -> check_remote(Key)
    end.

check_remote(Key) ->
    case application:get_env(cli_proxy, management_secret) of
        {ok, HashedSecret} ->
            case bcrypt:verify(Key, HashedSecret) of
                true -> ok;
                false -> {error, unauthorized}
            end;
        undefined ->
            {error, remote_management_disabled}
    end.

extract_key(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Key/binary>> -> Key;
        _ -> cowboy_req:header(<<"x-management-key">>, Req, <<>>)
    end.
```

## Middleware & Request Pipeline

### Cowboy middleware chain

In Go, middleware is a chain of `gin.HandlerFunc` wrappers. In Cowboy, the equivalent is either Cowboy middleware modules or explicit dispatch in the handler. For this project, a handler-level pipeline is clearer:

```erlang
%% In each API handler
init(Req0, State) ->
    Req1 = cors_headers(Req0),
    case cowboy_req:method(Req1) of
        <<"OPTIONS">> ->
            {ok, cowboy_req:reply(204, Req1), State};
        _ ->
            case home_heartbeat_check(Req1) of
                ok ->
                    case api_key_auth(Req1, State) of
                        {ok, Principal} ->
                            handle(Req1, State#{principal => Principal});
                        {error, _} ->
                            {ok, cowboy_req:reply(401, Req1), State}
                    end;
                unhealthy ->
                    {ok, cowboy_req:reply(503, Req1), State}
            end
    end.
```

| Middleware | Go | Erlang |
|-----------|-----|--------|
| CORS | `corsMiddleware()` | `cors_headers/1` — sets `Access-Control-Allow-*` headers |
| Panic recovery | `gin.Recovery()` | Built-in — process crash is isolated, supervisor restarts |
| Request logging | `RequestLoggingMiddleware()` | `request_logger` gen_server receiving `{log, Req, Resp}` messages |
| Home heartbeat | `homeHeartbeatMiddleware()` | `home_heartbeat_check/1` — checks `home_client:is_healthy()` |
| API key auth | `AuthMiddleware()` | `api_key_auth/2` — validates against ETS-backed key set |

### Request logging

Instead of wrapping the response writer, the Erlang approach uses a separate logging process. After the handler completes, it sends the request/response data to the logger:

```erlang
-module(request_logger).
-behaviour(gen_server).

handle_cast({log, #{method := Method, path := Path, status := Status,
                     request_body := ReqBody, response_body := RespBody,
                     duration_ms := Duration, ttfb_ms := TTFB}}, State) ->
    case should_log(Status, State#state.error_only) of
        true ->
            Entry = format_entry(Method, Path, Status, Duration, TTFB, ReqBody, RespBody),
            write_log(Entry, State);
        false ->
            ok
    end,
    {noreply, State}.
```

## Storage Backends

### Behaviour definition

All storage backends implement a common behaviour:

```erlang
-module(auth_store).

-callback load_all() -> {ok, [auth_file()]} | {error, term()}.
-callback save(Provider :: atom(), TokenData :: map()) -> ok | {error, term()}.
-callback update(Id :: binary(), NewMetadata :: map()) -> ok | {error, term()}.
-callback delete(Id :: binary()) -> ok | {error, term()}.
-callback load_config() -> {ok, map()} | {error, term()}.
-callback save_config(Config :: map()) -> ok | {error, term()}.
```

### Implementations

| Backend | Module | When to use |
|---------|--------|-------------|
| **File system** | `file_store` | Default. Local development, single-node. |
| **PostgreSQL** | `pg_store` | Multi-node with shared state. Schema: `config` + `auth_files` tables. |
| **Git** | `git_store` | Version-controlled credential storage. Auto-commit on changes. |
| **Object store** | `s3_store` | Cloud deployment with S3-compatible storage (AWS, MinIO). |

```erlang
-module(file_store).
-behaviour(auth_store).

load_all() ->
    AuthDir = application:get_env(cli_proxy, auth_dir, "~/.cli-proxy-api/"),
    Files = filelib:wildcard(filename:join(AuthDir, "*.json")),
    {ok, [parse_auth_file(F) || F <- Files]}.

save(Provider, TokenData) ->
    AuthDir = application:get_env(cli_proxy, auth_dir, "~/.cli-proxy-api/"),
    Filename = generate_filename(Provider, TokenData),
    Path = filename:join(AuthDir, Filename),
    ok = file:write_file(Path, jiffy:encode(TokenData)).
```

## Quota & Usage Tracking

### Quota state in CLIPS

Quota tracking extends the CLIPS fact model with quota-specific facts:

```clips
(deftemplate quota-state
  (slot credential-id (type STRING))
  (slot exceeded (type SYMBOL) (default no))
  (slot reason (type STRING) (default ""))
  (slot recover-at (type INTEGER) (default 0))
  (slot backoff-level (type INTEGER) (default 0)))

(defrule quota-exceeded-switch-project
  "When quota exceeded and switch-project enabled, try another project"
  (declare (salience 90))
  (select-request (id ?rid) (model ?m))
  (quota-state (credential-id ?cid) (exceeded yes) (recover-at ?t))
  (config-flag (name switch-project) (value yes))
  (credential (id ?alt-cid) (provider ?p) (status active))
  (test (neq ?cid ?alt-cid))
  (not (quota-state (credential-id ?alt-cid) (exceeded yes)))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?alt-cid)
                      (score 50) (reason "quota-switch-project"))))
```

### Usage logging

Usage statistics are collected per-request and optionally queued:

```erlang
-module(usage_logger).
-behaviour(gen_server).

handle_cast({log_usage, #{credential_id := CredId, model := Model,
                           status := Status, tokens := Tokens}}, State) ->
    %% Update in-memory counters
    ets:update_counter(?USAGE_TABLE, {CredId, Model, success_or_fail(Status)},
                       {2, 1}, {{CredId, Model, success_or_fail(Status)}, 0}),
    %% Queue for external consumption if enabled
    case State#state.queue_enabled of
        true -> enqueue_usage(CredId, Model, Status, Tokens, State);
        false -> ok
    end,
    {noreply, State}.
```

## Configuration

### Full config structure

```erlang
-record(config, {
    %% Network
    host = "0.0.0.0"          :: string(),
    port                      :: pos_integer(),
    tls                       :: #tls_config{} | undefined,

    %% Home control plane
    home                      :: #home_config{} | undefined,

    %% Remote management
    remote_management         :: #remote_mgmt_config{},

    %% Auth
    auth_dir = "~/.cli-proxy-api/" :: string(),

    %% Debug & logging
    debug = false             :: boolean(),
    logging_to_file = false   :: boolean(),
    logs_max_total_size_mb = 0 :: non_neg_integer(),
    error_logs_max_files = 10 :: pos_integer(),
    request_log = false       :: boolean(),

    %% Retry
    request_retry = 3         :: non_neg_integer(),
    max_retry_credentials = 0 :: non_neg_integer(),  %% 0 = all
    max_retry_interval = 0    :: non_neg_integer(),

    %% Quota
    quota_exceeded            :: #quota_exceeded_config{},

    %% Routing
    routing                   :: #routing_config{},

    %% WebSocket
    ws_auth = false           :: boolean(),

    %% Provider keys (direct API key usage)
    gemini_keys = []          :: [#gemini_key{}],
    claude_keys = []          :: [#claude_key{}],
    codex_keys = []           :: [#codex_key{}],
    openai_compat = []        :: [#openai_compat{}],
    vertex_keys = []          :: [#vertex_key{}],

    %% Model management
    oauth_excluded_models = #{} :: #{atom() => [binary()]},
    oauth_model_alias = #{}     :: #{atom() => [#model_alias{}]},

    %% Payload rules
    payload                   :: #payload_config{} | undefined,

    %% Proxy
    proxy_url                 :: binary() | undefined,

    %% Cooling
    disable_cooling = false   :: boolean(),

    %% Usage
    usage_statistics_enabled = false :: boolean(),

    %% Amp CLI
    ampcode                   :: #ampcode_config{} | undefined,

    %% Signature cache
    antigravity_signature_cache_enabled = true :: boolean()
}).
```

## CLI Entry Points

### escript / release

The Erlang version uses an OTP release built with `rebar3`:

```erlang
%% In cli_proxy_app.erl
start(_StartType, _StartArgs) ->
    Args = parse_cli_args(init:get_plain_arguments()),
    case Args of
        #{login := Provider} ->
            run_login(Provider, Args),
            init:stop();
        #{vertex_import := File} ->
            run_vertex_import(File, Args),
            init:stop();
        _ ->
            cli_proxy_sup:start_link(Args)
    end.
```

### CLI flags mapping

| Go flag | Erlang equivalent | Description |
|---------|-------------------|-------------|
| `-login` / `-gemini-login` | `--login gemini` | Gemini OAuth |
| `-codex-login` | `--login codex` | Codex OAuth |
| `-codex-device-login` | `--login codex-device` | Codex device flow |
| `-claude-login` | `--login claude` | Claude OAuth |
| `-antigravity-login` | `--login antigravity` | Antigravity OAuth |
| `-kimi-login` | `--login kimi` | Kimi device flow |
| `-no-browser` | `--no-browser` | Skip browser open |
| `-oauth-callback-port` | `--callback-port PORT` | Override callback port |
| `-config` | `--config PATH` | Config file path |
| `-vertex-import` | `--vertex-import FILE` | Import Vertex SA |
| `-password` | `--password PW` | Management API password |
| `-home` | `--home ADDR` | Home control plane |
| `-tui` | `--tui` | Terminal UI mode |
| `-local-model` | `--local-models` | Skip remote model updates |

## Deployment

### Release structure

```
_build/prod/rel/cli_proxy/
├── bin/cli_proxy              # Start/stop/attach script
├── lib/                       # Compiled BEAM files
├── releases/
│   └── 1.0.0/
│       ├── sys.config         # Application config
│       └── vm.args            # BEAM VM flags
├── erts-*/                    # Embedded Erlang runtime
└── priv/
    ├── clips/                 # CLIPS rule files
    ├── clips_port             # Compiled CLIPS C binary
    └── models.json            # Embedded model catalog
```

### vm.args

```
## Name and cookie for distributed Erlang
-name cli_proxy@127.0.0.1
-setcookie cli_proxy_secret

## Process and port limits
+P 1048576
+Q 65536

## Scheduler
+S 4:4
+SDcpu 50

## Memory
+MBas aobf
+MBlmbcs 512

## Kernel polling
+K true
```

### Dockerfile

```dockerfile
FROM erlang:27-alpine AS builder
RUN apk add --no-cache gcc musl-dev make git

WORKDIR /app
COPY rebar.config rebar.lock ./
RUN rebar3 deps

COPY . .
# Build CLIPS port program
RUN cd apps/clips_port && make
# Build release
RUN rebar3 as prod release

FROM alpine:3.20
RUN apk add --no-cache libstdc++ ncurses-libs openssl
COPY --from=builder /app/_build/prod/rel/cli_proxy /opt/cli_proxy

EXPOSE 8317 8085 1455 54545
ENTRYPOINT ["/opt/cli_proxy/bin/cli_proxy"]
CMD ["foreground"]
```

### Health check

```erlang
%% Simple health endpoint — no management auth required
-module(health_handler).

init(Req, State) ->
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>},
                          <<"ok">>, Req), State}.
```

Registered at `/healthz` outside the management route group.

## Responses API (WebSocket + HTTP)

### The Go problem

The Responses API handler (`openai_responses_websocket.go`, 1191 lines) is the most complex single handler in the codebase. It manages:
- A bidirectional WebSocket protocol with 16+ event types and sequence numbering
- Per-session tool call caches with TTL-based eviction
- Credential pinning with automatic failover on auth errors
- Incremental input optimization (send deltas instead of full transcript)
- Upstream connection pooling (persistent WS to Codex)
- Transcript replay bypass detection
- Format translation between internal SSE and client-facing WS frames

In Go, this is a single goroutine per connection with manual mutex locks for session state, shared global caches behind `sync.Map`, and interleaved request/response handling.

### Protocol specification

**Client → Server (request frames):**

| Type | Purpose |
|------|---------|
| `response.create` | Start a new response. Contains `model`, `instructions`, `input`, `tools`, etc. |
| `response.append` | Continue with incremental input. May reference `previous_response_id`. |

**Server → Client (event frames):**

| Type | Purpose |
|------|---------|
| `response.created` | Response started, contains response object stub |
| `response.in_progress` | Response actively generating |
| `response.output_item.added` | New output item started (message, function_call, reasoning) |
| `response.content_part.added` | New content part within an item |
| `response.output_text.delta` | Streaming text chunk |
| `response.output_text.done` | Text part finalized |
| `response.content_part.done` | Content part finalized |
| `response.output_item.done` | Output item finalized |
| `response.function_call_arguments.delta` | Tool call arguments streaming |
| `response.function_call_arguments.done` | Tool call complete |
| `response.reasoning_summary_part.added` | Reasoning block started |
| `response.reasoning_summary_text.delta` | Reasoning text streaming |
| `response.reasoning_summary_text.done` | Reasoning text finalized |
| `response.reasoning_summary_part.done` | Reasoning part finalized |
| `response.completed` | Full response with usage stats |
| `error` | Fatal error with status code and type |

Termination marker: `[DONE]` (bare text, not JSON).

### Erlang redesign: one process per WS connection

Each client WebSocket connection is a `cowboy_websocket` handler process. The process owns all session state — no shared caches, no mutexes:

```
                    ┌──────────────────────────────────────────────┐
                    │         responses_ws_handler                  │
                    │         (cowboy_websocket)                    │
                    │                                               │
   Client WS ◄════►│  State:                                       │
                    │  - session_id (downstream key)                │
                    │  - pinned_auth_id                             │
                    │  - last_request (for transcript merge)        │
                    │  - last_response_output (for replay)          │
                    │  - tool_call_cache (ETS, per-session)         │
                    │  - sequence_number                            │
                    │  - upstream_pid (linked gun/WS process)       │
                    │                                               │
                    │  On response.create/append:                   │
                    │  1. Normalize + merge input                   │
                    │  2. Repair tool calls from cache              │
                    │  3. Ask conductor for credential              │
                    │  4. Translate request format                  │
                    │  5. Send to upstream (gun WS or HTTP)         │
                    │  6. Stream events back with seq numbering     │
                    │                                               │
                    └──────────────────────────────────────────────┘
```

```erlang
-module(responses_ws_handler).
-behaviour(cowboy_websocket).

-record(state, {
    session_id        :: binary(),         %% derived from client headers
    execution_id      :: binary(),         %% passthrough to conductor
    pinned_auth_id    :: binary() | undefined,
    last_request      :: map() | undefined,
    last_response_output :: [map()],       %% output items from last response
    tool_call_cache   :: ets:tid(),        %% call_id → tool_call map
    tool_output_cache :: ets:tid(),        %% call_id → output map
    seq               :: non_neg_integer(),%% sequence_number counter
    upstream_conn     :: pid() | undefined,%% persistent upstream WS
    translator_mod    :: module()          %% response event translator
}).

%% --- Connection init ---
websocket_init(Req, _Opts) ->
    SessionId = extract_session_key(Req),
    ExecId = generate_uuid(),
    ToolCallCache = ets:new(tool_calls, [set, private]),
    ToolOutputCache = ets:new(tool_outputs, [set, private]),
    {ok, #state{
        session_id = SessionId,
        execution_id = ExecId,
        last_response_output = [],
        tool_call_cache = ToolCallCache,
        tool_output_cache = ToolOutputCache,
        seq = 0
    }}.

%% --- Client sends request frame ---
websocket_handle({text, RawJSON}, State) ->
    case jiffy:decode(RawJSON, [return_maps]) of
        #{<<"type">> := <<"response.create">>} = Req ->
            handle_create(Req, State);
        #{<<"type">> := <<"response.append">>} = Req ->
            handle_append(Req, State);
        _ ->
            {ok, State}  %% ignore unknown
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

%% --- Upstream sends events ---
websocket_info({upstream_event, Event}, State) ->
    {Frames, State1} = translate_and_sequence(Event, State),
    {Frames, State1};

websocket_info({upstream_done, ResponseOutput, Usage}, State) ->
    %% Stream complete — update caches and state
    State1 = update_tool_caches(ResponseOutput, State),
    State2 = State1#state{last_response_output = ResponseOutput},
    DoneFrame = {text, <<"[DONE]">>},
    {[DoneFrame], State2};

websocket_info({upstream_error, Status, Message}, State) ->
    ErrorEvent = build_error_event(Status, Message),
    Frame = {text, jiffy:encode(ErrorEvent)},
    DoneFrame = {text, <<"[DONE]">>},
    %% Unpin auth on auth errors
    State1 = maybe_unpin_auth(Status, State),
    {[Frame, DoneFrame], State1};

websocket_info(_Info, State) ->
    {ok, State}.

%% --- Connection teardown ---
terminate(_Reason, _Req, #state{tool_call_cache = TC, tool_output_cache = TO,
                                 upstream_conn = Upstream}) ->
    ets:delete(TC),
    ets:delete(TO),
    %% Upstream connection dies with us (linked) or we close explicitly
    case Upstream of
        undefined -> ok;
        Pid -> gun:close(Pid)
    end,
    ok.
```

### Request handling: create & append

```erlang
handle_create(Req, State) ->
    %% 1. Normalize request
    Model = maps:get(<<"model">>, Req),
    Input = maps:get(<<"input">>, Req, []),

    %% 2. Merge with previous state (unless incremental mode)
    MergedInput = case should_use_incremental(Req, State) of
        true  -> Input;  %% delta only, upstream handles merge
        false -> merge_transcript(State#state.last_response_output, Input, State)
    end,

    %% 3. Repair orphaned tool outputs
    RepairedInput = repair_tool_calls(MergedInput, State#state.tool_call_cache),

    %% 4. Build normalized request
    NormReq = Req#{<<"input">> => RepairedInput, <<"stream">> => true},

    %% 5. Select credential via conductor
    {AuthId, Provider} = case State#state.pinned_auth_id of
        undefined -> conductor:select(Model, State#state.execution_id);
        Pinned    -> {Pinned, conductor:provider_for(Pinned)}
    end,

    %% 6. Translate to upstream format
    TranslatorMod = translator_registry:get_responses(openai_response, Provider),
    TranslatedReq = TranslatorMod:request(Model, NormReq, true),

    %% 7. Send upstream (WS or HTTP depending on provider)
    Self = self(),
    UpstreamPid = start_upstream_request(Provider, AuthId, TranslatedReq,
                                          State#state.upstream_conn, Self),

    State1 = State#state{
        last_request = NormReq,
        pinned_auth_id = AuthId,
        upstream_conn = UpstreamPid,
        translator_mod = TranslatorMod,
        seq = 0
    },
    {ok, State1}.

handle_append(Req, State) ->
    %% Append is structurally identical to create but uses previous state
    handle_create(maps:put(<<"type">>, <<"response.create">>, Req), State).
```

### Upstream connection process

For Codex-backed credentials, the upstream is also a WebSocket. A linked process manages the upstream connection and routes events back:

```erlang
-module(responses_upstream).

%% Spawned by the handler process, linked to it
start_link(Provider, AuthId, Request, ExistingConn, HandlerPid) ->
    spawn_link(fun() ->
        Conn = ensure_connection(Provider, AuthId, ExistingConn),
        send_request(Conn, Request),
        receive_loop(Conn, HandlerPid, Provider)
    end).

ensure_connection(codex, AuthId, undefined) ->
    %% New connection to Codex WebSocket
    URL = build_codex_ws_url(AuthId),
    Headers = build_codex_headers(AuthId),
    {ok, ConnPid} = gun:open(Host, Port, #{protocols => [http]}),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:ws_upgrade(ConnPid, Path, Headers),
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _} -> ok
    end,
    {ConnPid, StreamRef};
ensure_connection(_codex, _AuthId, {ConnPid, StreamRef}) ->
    %% Reuse existing connection
    {ConnPid, StreamRef};
ensure_connection(Provider, AuthId, _) ->
    %% Non-WS providers: use HTTP SSE
    {http, Provider, AuthId}.

send_request({ConnPid, StreamRef}, Request) ->
    Frame = jiffy:encode(Request),
    gun:ws_send(ConnPid, StreamRef, {text, Frame});
send_request({http, Provider, AuthId}, Request) ->
    %% HTTP streaming request
    self() ! {start_http_stream, Provider, AuthId, Request}.

receive_loop({ConnPid, StreamRef}, HandlerPid, Provider) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Data}} ->
            case parse_sse_or_json(Data) of
                {event, <<"[DONE]">>} ->
                    HandlerPid ! {upstream_done, get_output(), get_usage()};
                {event, EventJSON} ->
                    Event = jiffy:decode(EventJSON, [return_maps]),
                    HandlerPid ! {upstream_event, Event},
                    %% Accumulate output items for final state
                    maybe_accumulate(Event),
                    receive_loop({ConnPid, StreamRef}, HandlerPid, Provider);
                {error, Reason} ->
                    HandlerPid ! {upstream_error, 500, Reason}
            end;
        {gun_ws, ConnPid, StreamRef, close} ->
            HandlerPid ! {upstream_error, 502, <<"upstream closed">>};
        {gun_down, ConnPid, _, _, _} ->
            HandlerPid ! {upstream_error, 502, <<"connection lost">>}
    after 120_000 ->
        HandlerPid ! {upstream_error, 408, <<"timeout">>}
    end.
```

### Event translation and sequence numbering

Events from upstream are translated to the Responses API format and sequenced:

```erlang
translate_and_sequence(Event, #state{translator_mod = Mod, seq = Seq} = State) ->
    %% Translator converts upstream format → Responses API events
    %% May produce multiple output events per input event
    OutputEvents = Mod:response_stream_responses(Event),
    {Frames, FinalSeq} = lists:mapfoldl(
        fun(OutEvent, S) ->
            Sequenced = OutEvent#{<<"sequence_number">> => S},
            Frame = {text, jiffy:encode(Sequenced)},
            {Frame, S + 1}
        end, Seq, OutputEvents),
    {Frames, State#state{seq = FinalSeq}}.
```

### Tool call cache repair

When a client sends `function_call_output` without the matching `function_call` in the same request (common in multi-turn tool use), the handler injects the cached call:

```erlang
repair_tool_calls(Input, ToolCallCache) ->
    lists:flatmap(fun
        (#{<<"type">> := <<"function_call_output">>, <<"call_id">> := CallId} = Item) ->
            case ets:lookup(ToolCallCache, CallId) of
                [{CallId, CachedCall}] ->
                    %% Inject the function_call before the output
                    [CachedCall, Item];
                [] ->
                    [Item]  %% No cache hit, pass through
            end;
        (Item) ->
            [Item]
    end, Input).

update_tool_caches(ResponseOutput, State) ->
    %% Cache new tool calls from this response
    lists:foreach(fun
        (#{<<"type">> := <<"function_call">>, <<"call_id">> := CallId} = Item) ->
            ets:insert(State#state.tool_call_cache, {CallId, Item});
        (_) -> ok
    end, ResponseOutput),
    State.
```

### Credential pinning and failover

```erlang
maybe_unpin_auth(Status, State) when Status =:= 401;
                                      Status =:= 402;
                                      Status =:= 403;
                                      Status =:= 429 ->
    %% Auth failed — unpin and force full transcript on next request
    State#state{pinned_auth_id = undefined};
maybe_unpin_auth(_Status, State) ->
    State.
```

On unpin, the next `response.create` will re-select via the conductor. If the upstream supports incremental input (`previous_response_id`), a forced transcript replay ensures the new credential sees full context.

### Incremental vs full-transcript mode

```erlang
should_use_incremental(#{<<"previous_response_id">> := PrevId}, State)
  when PrevId =/= <<>>, PrevId =/= undefined ->
    %% Check if pinned auth supports incremental input
    case State#state.pinned_auth_id of
        undefined -> false;
        AuthId -> credential_supports_incremental(AuthId)
    end;
should_use_incremental(_, _) ->
    false.

credential_supports_incremental(AuthId) ->
    %% Only Codex with websocket=true supports incremental
    case credential_proc:get_metadata(AuthId, <<"websockets">>) of
        true -> true;
        _ -> false
    end.
```

### Compact mode (HTTP-only variant)

`POST /v1/responses/compact` is the non-streaming, non-WebSocket variant. It uses a simple request-response pattern:

```erlang
-module(responses_compact_handler).

init(Req, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    Request = jiffy:decode(Body, [return_maps]),
    Model = maps:get(<<"model">>, Request),

    {AuthId, Provider} = conductor:select(Model, generate_uuid()),
    TranslatorMod = translator_registry:get_responses(openai_response, Provider),
    TranslatedReq = TranslatorMod:request(Model, Request, false),

    case executor:execute(Provider, AuthId, TranslatedReq, #{alt => <<"responses/compact">>}) of
        {ok, RespBody} ->
            Translated = TranslatorMod:response_nonstream(RespBody),
            {ok, cowboy_req:reply(200, json_headers(), jiffy:encode(Translated), Req1), State};
        {error, Status, ErrBody} ->
            {ok, cowboy_req:reply(Status, json_headers(), ErrBody, Req1), State}
    end.
```

### Updated supervision tree

With Responses API WebSocket support, the HTTP supervisor accommodates dynamic WS processes:

```
              http_sup (one_for_one)
                │
         cowboy_listener
                │
    Per-connection processes (dynamic):
    ── responses_ws_handler_1     (client WS, cowboy_websocket)
    │       └── responses_upstream_1  (upstream WS, linked)
    ── responses_ws_handler_2
    │       └── responses_upstream_2
    ── ws_session_1               (AI Studio runtime credential)
    ── openai_handler_req_1       (regular HTTP, short-lived)
    └── ...
```

Each `responses_ws_handler` process is created by Cowboy on upgrade and dies with the connection. The linked `responses_upstream` process dies with it — no orphaned upstream connections. This is a key advantage over Go's manual goroutine lifecycle: linked processes guarantee cleanup without explicit `defer` chains.

### Error mapping

HTTP status codes from upstream are mapped to Responses API error types:

```erlang
error_type(401) -> <<"invalid_api_key">>;
error_type(402) -> <<"insufficient_quota">>;
error_type(403) -> <<"insufficient_quota">>;
error_type(404) -> <<"model_not_found">>;
error_type(408) -> <<"request_timeout">>;
error_type(429) -> <<"rate_limit_exceeded">>;
error_type(S) when S >= 400, S < 500 -> <<"invalid_request_error">>;
error_type(_) -> <<"internal_server_error">>.

build_error_event(Status, Message) ->
    #{
        <<"type">> => <<"error">>,
        <<"status">> => Status,
        <<"error">> => #{
            <<"type">> => error_type(Status),
            <<"message">> => Message
        }
    }.
```

## Home Control Plane (Distributed Mode)

### The Go problem

The Go implementation builds a custom distributed system using Redis RESP protocol: a central "home" node manages credentials and config, while satellite nodes communicate via `RPOP`/`LPUSH`/`SUBSCRIBE` with dynamically-generated JSON keys as queue identifiers. This is an unusual pattern — the request JSON itself becomes the Redis key for response delivery. The implementation includes: a custom RESP parser, heartbeat via PubSub subscription health, config overlay merging, usage forwarding with retry, and request log streaming.

### Why Erlang distribution replaces all of this

Erlang's built-in distribution provides everything the Home control plane needs:

| Go Home feature | Erlang equivalent |
|----------------|-------------------|
| Redis RESP protocol client | Eliminated — native message passing |
| PubSub config subscription | `gen_event` or process monitors |
| RPOP with JSON key for auth dispatch | `gen_server:call/2` to remote process |
| LPUSH for usage forwarding | `gen_server:cast/2` with buffering |
| Heartbeat via subscription health | `net_kernel:monitor_nodes/1` |
| Config overlay merge | Remote `gen_server:call` to config process |
| Request log streaming | Message passing to remote logger |

### Architecture

```
┌─────────────────────────────────────┐      ┌──────────────────────────────────────┐
│         Satellite Node              │      │          Home Node                   │
│    cli_proxy@satellite.local        │      │    cli_proxy@home.local              │
│                                     │      │                                      │
│  ┌───────────────┐                  │      │  ┌───────────────────┐               │
│  │ home_client   │──── rpc:call ────│─────►│  │ home_conductor    │               │
│  │ (gen_server)  │     auth_select  │      │  │ (gen_server)      │               │
│  │               │                  │      │  │ - manages all     │               │
│  │ - caches      │◄── reply ────────│──────│  │   credentials     │               │
│  │   config      │                  │      │  │ - CLIPS engine    │               │
│  │ - forwards    │                  │      │  │ - model registry  │               │
│  │   usage       │                  │      │  └───────────────────┘               │
│  └───────────────┘                  │      │                                      │
│         │                           │      │  ┌───────────────────┐               │
│         │ gen_event:notify          │      │  │ home_config       │               │
│         ▼                           │      │  │ (gen_server)      │◄── fs:subscribe│
│  ┌───────────────┐                  │      │  │ - broadcasts      │               │
│  │ config_watcher│◄── {config_push} │──────│  │   config changes  │               │
│  │ (applies      │                  │      │  └───────────────────┘               │
│  │  overlay)     │                  │      │                                      │
│  └───────────────┘                  │      │  ┌───────────────────┐               │
│                                     │      │  │ home_usage_log    │               │
│  ┌───────────────┐                  │      │  │ (gen_server)      │               │
│  │ usage_logger  │──── cast ────────│─────►│  │ - aggregates      │               │
│  │ (buffered)    │   forward_usage  │      │  │   from satellites │               │
│  └───────────────┘                  │      │  └───────────────────┘               │
└─────────────────────────────────────┘      └──────────────────────────────────────┘
```

### Satellite node: `home_client`

```erlang
-module(home_client).
-behaviour(gen_server).

-record(state, {
    home_node      :: node(),
    connected      :: boolean(),
    config_cache   :: map(),
    usage_buffer   :: [map()],
    buffer_timer   :: reference() | undefined
}).

init([HomeNode]) ->
    %% Monitor home node connectivity
    net_kernel:monitor_nodes(true),
    %% Attempt initial connection
    case net_adm:ping(HomeNode) of
        pong ->
            Config = gen_server:call({home_config, HomeNode}, get_config),
            apply_config_overlay(Config),
            {ok, #state{home_node = HomeNode, connected = true,
                        config_cache = Config, usage_buffer = []}};
        pang ->
            {ok, #state{home_node = HomeNode, connected = false,
                        config_cache = #{}, usage_buffer = []}}
    end.

%% --- Credential selection (synchronous, blocks request) ---
handle_call({select_auth, Model, SessionId, Headers}, _From,
            #state{home_node = Home, connected = true} = State) ->
    case gen_server:call({home_conductor, Home},
                         {select, Model, SessionId, Headers}, 5000) of
        {ok, Auth} ->
            {reply, {ok, Auth}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({select_auth, _, _, _}, _From, #state{connected = false} = State) ->
    {reply, {error, home_unavailable}, State}.

%% --- Usage forwarding (async, buffered) ---
handle_cast({log_usage, UsageRecord}, #state{usage_buffer = Buf} = State) ->
    Buf1 = [UsageRecord | Buf],
    State1 = case length(Buf1) >= 64 of
        true  -> flush_usage(State#state{usage_buffer = Buf1});
        false -> ensure_flush_timer(State#state{usage_buffer = Buf1})
    end,
    {noreply, State1}.

%% --- Node monitoring ---
handle_info({nodedown, Node}, #state{home_node = Node} = State) ->
    %% Home went down — mark unhealthy, buffer usage locally
    {noreply, State#state{connected = false}};

handle_info({nodeup, Node}, #state{home_node = Node} = State) ->
    %% Home came back — reconnect, fetch fresh config
    Config = gen_server:call({home_config, Node}, get_config),
    apply_config_overlay(Config),
    State1 = flush_usage(State#state{connected = true, config_cache = Config}),
    {noreply, State1};

%% --- Config push from home ---
handle_info({config_updated, NewConfig}, State) ->
    apply_config_overlay(NewConfig),
    {noreply, State#state{config_cache = NewConfig}}.

%% --- Flush buffered usage ---
flush_usage(#state{home_node = Home, usage_buffer = Buf, connected = true} = State) ->
    gen_server:cast({home_usage_log, Home}, {batch_usage, node(), Buf}),
    cancel_flush_timer(State#state{usage_buffer = []});
flush_usage(State) ->
    State.  %% Keep buffering if disconnected

ensure_flush_timer(#state{buffer_timer = undefined} = State) ->
    Ref = erlang:send_after(500, self(), flush_timer),
    State#state{buffer_timer = Ref};
ensure_flush_timer(State) ->
    State.
```

### Home node: config broadcast

```erlang
-module(home_config).
-behaviour(gen_server).

handle_call(get_config, _From, #state{config = Config} = State) ->
    {reply, Config, State};

handle_info({config_file_changed, NewConfig}, State) ->
    %% Broadcast to all connected satellite nodes
    Nodes = nodes(),
    [erlang:send({home_client, N}, {config_updated, NewConfig}) || N <- Nodes],
    {noreply, State#state{config = NewConfig}}.
```

### Config overlay rules

When a satellite receives config from home, certain fields are forced:

```erlang
apply_config_overlay(HomeConfig) ->
    LocalConfig = config_loader:get_base(),
    Merged = maps:merge(HomeConfig, #{
        %% Preserve local network settings
        host => maps:get(host, LocalConfig),
        port => maps:get(port, LocalConfig),
        tls => maps:get(tls, LocalConfig),
        %% Force satellite-mode settings
        disable_cooling => true,
        ws_auth => false,
        api_keys => [],
        usage_statistics_enabled => true,
        remote_management => #{
            disable_control_panel => true,
            allow_remote => false
        }
    }),
    config_loader:apply(Merged).
```

### Heartbeat

No separate heartbeat mechanism needed. Erlang's `net_kernel:monitor_nodes/1` delivers `{nodedown, Node}` and `{nodeup, Node}` messages automatically. The `home_heartbeat_check/1` middleware in the API pipeline simply checks the `connected` field:

```erlang
home_heartbeat_check(Req) ->
    case home_client:is_connected() of
        true -> ok;
        false -> unhealthy
    end.
```

## Amp CLI Module

### The Go problem

The Amp CLI module (`internal/api/modules/amp/`, 40+ endpoints) is a routing layer that decides whether to handle requests locally (using OAuth credentials) or forward them to the Amp control plane (`ampcode.com`). It supports model mappings with regex, per-client API key routing, multi-tier secret resolution, and response rewriting to hide internal model names.

### Erlang redesign

The Amp module becomes a Cowboy handler with a model routing decision tree:

```erlang
-module(amp_handler).

init(Req, State) ->
    case amp_config:is_enabled() of
        false -> {ok, cowboy_req:reply(404, Req), State};
        true  -> route(Req, State)
    end.

route(Req, State) ->
    Model = extract_model(Req),
    ClientKey = extract_client_key(Req),
    
    case resolve_model(Model, ClientKey) of
        {local, Provider, ResolvedModel} ->
            %% Handle locally via conductor
            forward_to_local(Provider, ResolvedModel, Req, State);
        {mapped, FromModel, ToModel} ->
            %% Local handling with response rewriting
            forward_with_rewrite(FromModel, ToModel, Req, State);
        {upstream, UpstreamURL, UpstreamKey} ->
            %% Proxy to ampcode.com
            reverse_proxy(UpstreamURL, UpstreamKey, Req, State)
    end.
```

### Model resolution priority

```erlang
resolve_model(Model, ClientKey) ->
    ForceMapping = amp_config:force_model_mappings(),
    case ForceMapping of
        true ->
            %% Mappings first, then local
            case check_mappings(Model) of
                {ok, Mapped} -> {mapped, Model, Mapped};
                nomatch -> check_local_then_upstream(Model, ClientKey)
            end;
        false ->
            %% Local first, then mappings, then upstream
            case check_local(Model) of
                {ok, Provider} -> {local, Provider, Model};
                nomatch ->
                    case check_mappings(Model) of
                        {ok, Mapped} -> {mapped, Model, Mapped};
                        nomatch -> resolve_upstream(ClientKey)
                    end
            end
    end.

check_mappings(Model) ->
    Mappings = amp_config:model_mappings(),
    lists:foldl(fun
        (#{from := Pattern, to := To, regex := true}, nomatch) ->
            case re:run(Model, Pattern) of
                {match, _} -> {ok, To};
                nomatch -> nomatch
            end;
        (#{from := Pattern, to := To, regex := false}, nomatch) ->
            case Pattern =:= Model of
                true -> {ok, To};
                false -> nomatch
            end;
        (_, Found) -> Found
    end, nomatch, Mappings).
```

### Per-client upstream key routing

```erlang
-module(amp_secret).

resolve_upstream_key(ClientKey) ->
    %% 1. Check per-client mapping
    case amp_config:upstream_api_keys() of
        [] -> resolve_default();
        Entries ->
            case find_client_entry(ClientKey, Entries) of
                {ok, #{upstream_api_key := Key}} -> Key;
                nomatch -> resolve_default()
            end
    end.

resolve_default() ->
    %% 2. Explicit config key
    case amp_config:upstream_api_key() of
        <<>> ->
            %% 3. Environment variable
            case os:getenv("AMP_API_KEY") of
                false ->
                    %% 4. File-based secret
                    read_secret_file();
                Key -> list_to_binary(Key)
            end;
        Key -> Key
    end.
```

### Response rewriting

When a model mapping is applied, responses have the model name rewritten back to the originally requested name:

```erlang
forward_with_rewrite(OriginalModel, MappedModel, Req, State) ->
    %% Execute with mapped model
    Result = execute_request(MappedModel, Req),
    %% Rewrite model name in response back to original
    case Result of
        {stream, Chunks} ->
            Rewritten = [rewrite_model_in_chunk(C, MappedModel, OriginalModel) || C <- Chunks],
            stream_response(Rewritten, Req, State);
        {ok, Body} ->
            Rewritten = rewrite_model_in_body(Body, MappedModel, OriginalModel),
            {ok, cowboy_req:reply(200, json_headers(), Rewritten, Req), State}
    end.

rewrite_model_in_body(Body, From, To) ->
    %% Replace "model":"mapped-name" with "model":"original-name"
    binary:replace(Body, <<"\"model\":\"", From/binary, "\"">>,
                         <<"\"model\":\"", To/binary, "\"">>).
```

### Amp management endpoints

Management endpoints for Amp configuration are handled by the standard management handler, exposing CRUD for:

```erlang
%% In management_handler dispatch:
["/v0/management/ampcode/upstream-url",
 "/v0/management/ampcode/upstream-api-key",
 "/v0/management/ampcode/restrict-management-to-localhost",
 "/v0/management/ampcode/model-mappings",
 "/v0/management/ampcode/force-model-mappings",
 "/v0/management/ampcode/upstream-api-keys"]
```

All changes are hot-reloaded — the `amp_config` gen_server subscribes to config updates and rebuilds its mapping table.

## Signature Cache

### The Go problem

Claude thinking blocks carry cryptographic signatures that must be preserved for multi-turn conversations. The Go implementation uses a nested `sync.Map[groupKey][textHash]` with 3-hour TTL and background cleanup every 10 minutes. Signatures are keyed by model group + SHA256 of thinking text (16 hex chars).

### Erlang redesign: ETS with TTL sweep

```erlang
-module(signature_cache).
-behaviour(gen_server).

-define(TABLE, signature_cache_tab).
-define(TTL_SECONDS, 10800).          %% 3 hours
-define(CLEANUP_INTERVAL, 600_000).   %% 10 minutes

%% ETS table: {Key, Signature, Timestamp}
%% Key = {ModelGroup :: binary(), TextHash :: binary()}

init([]) ->
    ets:new(?TABLE, [named_table, set, public, {read_concurrency, true}]),
    schedule_cleanup(),
    {ok, #{enabled => true, bypass_strict => false}}.

%% --- Public API ---

-spec cache(binary(), binary(), binary()) -> ok.
cache(ModelName, ThinkingText, Signature) ->
    case byte_size(Signature) >= 50 of
        true ->
            Group = model_group(ModelName),
            Hash = text_hash(ThinkingText),
            ets:insert(?TABLE, {{Group, Hash}, Signature, erlang:system_time(second)}),
            ok;
        false ->
            ok  %% Invalid signature, don't cache
    end.

-spec get(binary(), binary()) -> {ok, binary()} | miss.
get(ModelName, ThinkingText) ->
    Group = model_group(ModelName),
    Hash = text_hash(ThinkingText),
    case ets:lookup(?TABLE, {Group, Hash}) of
        [{{_, _}, Sig, Ts}] ->
            Now = erlang:system_time(second),
            case Now - Ts =< ?TTL_SECONDS of
                true ->
                    %% Sliding TTL: refresh on hit
                    ets:update_element(?TABLE, {Group, Hash}, {3, Now}),
                    {ok, Sig};
                false ->
                    ets:delete(?TABLE, {Group, Hash}),
                    miss
            end;
        [] ->
            miss
    end.

%% --- Background cleanup ---

handle_info(cleanup, State) ->
    Now = erlang:system_time(second),
    Expired = ets:select(?TABLE, [
        {{'$1', '_', '$2'}, [{'<', '$2', Now - ?TTL_SECONDS}], ['$1']}
    ]),
    [ets:delete(?TABLE, Key) || Key <- Expired],
    schedule_cleanup(),
    {noreply, State}.

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).

%% --- Helpers ---

model_group(<<"claude", _/binary>>) -> <<"claude">>;
model_group(<<"gpt", _/binary>>) -> <<"gpt">>;
model_group(<<"gemini", _/binary>>) -> <<"gemini">>;
model_group(Other) -> Other.

text_hash(Text) ->
    <<Hash:128, _/binary>> = crypto:hash(sha256, Text),
    integer_to_binary(Hash, 16).
```

### Integration with translators

Translators check the cache when building requests with thinking blocks:

```erlang
%% In translator_antigravity_claude:request/3
handle_thinking_block(#{<<"type">> := <<"thinking">>, <<"text">> := Text} = Block, Model) ->
    case signature_cache:get(Model, Text) of
        {ok, CachedSig} ->
            Block#{<<"signature">> => CachedSig};
        miss ->
            %% No cached signature — strip or pass through depending on config
            case signature_cache:bypass_enabled() of
                true  -> validate_and_pass(Block);
                false -> maps:remove(<<"signature">>, Block)
            end
    end.
```

On response, new signatures are cached:

```erlang
%% In translator response accumulator
handle_thinking_response(#{<<"type">> := <<"thinking">>,
                           <<"text">> := Text,
                           <<"signature">> := Sig}, Model) ->
    signature_cache:cache(Model, Text, Sig),
    ok.
```

## Access Control

### The Go problem

The Go implementation has a pluggable provider-based access manager (`sdk/access/`) that iterates through registered providers until one authenticates the request. In practice, the main usage is simple API key validation against a configured list.

### Erlang redesign

Access control is a simple module — no process needed for stateless validation:

```erlang
-module(access_control).

-spec authenticate(cowboy_req:req()) -> {ok, binary()} | {error, term()}.
authenticate(Req) ->
    Key = extract_key(Req),
    case Key of
        <<>> -> {error, no_credentials};
        _ -> validate_key(Key)
    end.

extract_key(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> -> Token;
        _ ->
            case cowboy_req:header(<<"x-api-key">>, Req) of
                undefined -> <<>>;
                Token -> Token
            end
    end.

validate_key(Key) ->
    %% Check against configured API keys (stored in ETS for O(1) lookup)
    case ets:member(api_keys_tab, Key) of
        true -> {ok, Key};
        false -> {error, invalid_key}
    end.
```

The API keys table is managed by the config system:

```erlang
%% In config_watcher, on config update:
update_api_keys(NewKeys) ->
    ets:delete_all_objects(api_keys_tab),
    [ets:insert(api_keys_tab, {K, true}) || K <- NewKeys].
```

This replaces the Go provider chain pattern — in practice, 95% of deployments only use API key auth. The pluggable provider interface can be added later if custom auth backends are needed.

## Model Registry

### The Go problem

The model registry (`internal/registry/`) tracks which models are available across all providers, with reference counting, per-client registration, quota-exceeded tracking with 5-minute windows, suspended clients, and per-handler format conversion. It maintains multiple indices and an available-models cache that's invalidated on registration changes.

### Erlang redesign: ETS-backed registry

The model registry is a `gen_server` that owns an ETS table for concurrent reads:

```erlang
-module(model_registry).
-behaviour(gen_server).

-define(MODELS_TAB, model_registry_models).
-define(CLIENTS_TAB, model_registry_clients).

-record(model_reg, {
    id          :: binary(),
    providers   :: #{binary() => pos_integer()},   %% provider → count
    total_count :: non_neg_integer(),
    info        :: map(),                           %% latest ModelInfo
    info_by_provider :: #{binary() => map()},
    quota_exceeded :: #{binary() => integer()},    %% clientId → expiry timestamp
    suspended   :: #{binary() => binary()}         %% clientId → reason
}).

init([]) ->
    ets:new(?MODELS_TAB, [named_table, set, public, {read_concurrency, true},
                          {keypos, #model_reg.id}]),
    ets:new(?CLIENTS_TAB, [named_table, set, protected]),
    {ok, #{}}.

%% --- Registration ---

handle_call({register_client, ClientId, Provider, Models}, _From, State) ->
    OldModels = get_client_models(ClientId),
    %% Diff: remove old, add new
    Removed = OldModels -- Models,
    Added = Models -- OldModels,
    [unregister_model(ClientId, Provider, M) || M <- Removed],
    [register_model(ClientId, Provider, M) || M <- Added],
    ets:insert(?CLIENTS_TAB, {ClientId, Provider, [M#{<<"id">> => Id} || #{<<"id">> := Id} = M <- Models]}),
    %% Notify CLIPS about model changes
    update_clips_model_capabilities(Added, Removed),
    {reply, ok, State};

handle_call({unregister_client, ClientId}, _From, State) ->
    case ets:lookup(?CLIENTS_TAB, ClientId) of
        [{ClientId, Provider, Models}] ->
            [unregister_model(ClientId, Provider, M) || M <- Models],
            ets:delete(?CLIENTS_TAB, ClientId);
        [] -> ok
    end,
    {reply, ok, State}.

%% --- Queries ---

handle_call({get_available_models, HandlerType}, _From, State) ->
    %% Scan ETS for all models with total_count > 0
    Models = ets:foldl(fun(#model_reg{total_count = C} = Reg, Acc) when C > 0 ->
        EffectiveCount = C - count_expired_quota(Reg) - count_suspended(Reg),
        case EffectiveCount > 0 of
            true -> [format_model(Reg, HandlerType) | Acc];
            false -> Acc
        end;
    (_, Acc) -> Acc
    end, [], ?MODELS_TAB),
    {reply, Models, State};

handle_call({is_model_available, ModelId, ClientId}, _From, State) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{} = Reg] ->
            Available = not is_quota_exceeded(Reg, ClientId)
                andalso not is_suspended(Reg, ClientId),
            {reply, Available, State};
        [] ->
            {reply, false, State}
    end.

%% --- Quota management ---

handle_cast({quota_exceeded, ClientId, ModelId}, State) ->
    case ets:lookup(?MODELS_TAB, ModelId) of
        [#model_reg{quota_exceeded = QE} = Reg] ->
            Expiry = erlang:system_time(second) + 300,  %% 5-minute window
            Reg1 = Reg#model_reg{quota_exceeded = QE#{ClientId => Expiry}},
            ets:insert(?MODELS_TAB, Reg1);
        [] -> ok
    end,
    {noreply, State}.

%% --- CLIPS integration ---

update_clips_model_capabilities(Added, Removed) ->
    [clips_engine:retract({model_capability, maps:get(<<"id">>, M)}) || M <- Removed],
    [clips_engine:assert({model_capability, model_to_capability_fact(M)}) || M <- Added].

model_to_capability_fact(#{<<"id">> := Id, <<"type">> := Provider} = M) ->
    Thinking = maps:get(<<"thinking">>, M, #{}),
    #{
        model => Id,
        provider => Provider,
        thinking_min => maps:get(<<"min">>, Thinking, 0),
        thinking_max => maps:get(<<"max">>, Thinking, 0),
        thinking_mode => determine_thinking_mode(Thinking)
    }.
```

### Remote model updates

A periodic process fetches model definitions from remote sources (provider APIs or embedded catalog):

```erlang
-module(model_updater).
-behaviour(gen_server).

init([]) ->
    %% Load embedded catalog on startup
    {ok, CatalogJSON} = file:read_file(code:priv_dir(cli_proxy) ++ "/models.json"),
    Catalog = jiffy:decode(CatalogJSON, [return_maps]),
    register_catalog(Catalog),
    %% Schedule periodic remote fetch (if enabled)
    schedule_update(),
    {ok, #{catalog => Catalog}}.

handle_info(update_models, State) ->
    case fetch_remote_models() of
        {ok, NewCatalog} ->
            register_catalog(NewCatalog),
            schedule_update(),
            {noreply, State#{catalog => NewCatalog}};
        {error, _} ->
            schedule_update(),
            {noreply, State}
    end.

schedule_update() ->
    erlang:send_after(3_600_000, self(), update_models).  %% hourly
```

## Payload Rules

### The Go problem

The payload rules system (`payload` config section) allows operators to set defaults, force overrides, and filter fields in API requests using JSON path syntax. Rules are matched against model name patterns (with wildcards) and protocol types. The Go implementation applies rules after translation, before upstream transmission.

### Erlang redesign

Payload rules are applied as a pure function in the executor pipeline:

```erlang
-module(payload_rules).

-spec apply(Body :: map(), Model :: binary(), Protocol :: atom(), Config :: map()) -> map().
apply(Body, Model, Protocol, Config) ->
    Body1 = apply_defaults(Body, Model, Protocol, maps:get(default, Config, [])),
    Body2 = apply_defaults_raw(Body1, Model, Protocol, maps:get(default_raw, Config, [])),
    Body3 = apply_overrides(Body2, Model, Protocol, maps:get(override, Config, [])),
    Body4 = apply_overrides_raw(Body3, Model, Protocol, maps:get(override_raw, Config, [])),
    Body5 = apply_filters(Body4, Model, Protocol, maps:get(filter, Config, [])),
    Body5.

%% --- Defaults: set only if path doesn't exist ---

apply_defaults(Body, Model, Protocol, Rules) ->
    lists:foldl(fun(#{models := ModelPatterns, params := Params}, Acc) ->
        case matches_any(Model, Protocol, ModelPatterns) of
            true ->
                maps:fold(fun(Path, Value, B) ->
                    case path_exists(B, Path) of
                        true  -> B;  %% Don't override existing
                        false -> set_path(B, Path, Value)
                    end
                end, Acc, Params);
            false ->
                Acc
        end
    end, Body, Rules).

%% --- Overrides: always set (last write wins) ---

apply_overrides(Body, Model, Protocol, Rules) ->
    lists:foldl(fun(#{models := ModelPatterns, params := Params}, Acc) ->
        case matches_any(Model, Protocol, ModelPatterns) of
            true ->
                maps:fold(fun(Path, Value, B) ->
                    set_path(B, Path, Value)
                end, Acc, Params);
            false ->
                Acc
        end
    end, Body, Rules).

%% --- Filters: remove paths ---

apply_filters(Body, Model, Protocol, Rules) ->
    lists:foldl(fun(#{models := ModelPatterns, params := Paths}, Acc) ->
        case matches_any(Model, Protocol, ModelPatterns) of
            true ->
                lists:foldl(fun(Path, B) ->
                    remove_path(B, Path)
                end, Acc, Paths);
            false ->
                Acc
        end
    end, Body, Rules).

%% --- Pattern matching ---

matches_any(Model, Protocol, Patterns) ->
    lists:any(fun(#{name := NamePattern, protocol := ProtoPattern}) ->
        matches_protocol(Protocol, ProtoPattern) andalso
        matches_wildcard(Model, NamePattern)
    end, Patterns).

matches_protocol(_Protocol, <<>>) -> true;  %% Empty = match all
matches_protocol(Protocol, Pattern) -> atom_to_binary(Protocol) =:= Pattern.

matches_wildcard(Str, Pattern) ->
    %% Convert wildcard pattern to regex
    Regex = binary:replace(Pattern, <<"*">>, <<".*">>, [global]),
    case re:run(Str, <<"^", Regex/binary, "$">>) of
        {match, _} -> true;
        nomatch -> false
    end.
```

### Pipeline integration

Payload rules are applied in each executor's request pipeline, after translation:

```erlang
%% In claude_executor handle_call
do_execute(Auth, Request, Opts, State) ->
    %% 1. Translate request
    Translated = translate_request(Request, Opts),
    %% 2. Apply payload rules
    PayloadConfig = config_loader:get(payload),
    Model = maps:get(<<"model">>, Translated),
    Protocol = maps:get(protocol, Opts, claude),
    Final = payload_rules:apply(Translated, Model, Protocol, PayloadConfig),
    %% 3. Send upstream
    send_to_provider(Auth, Final, Opts, State).
```

## Retry & Circuit Breaking

### The Go problem

The Go retry logic is embedded in the conductor's `Execute`/`ExecuteStream` functions: on retriable errors (408, 500, 502, 503, 504), the conductor re-asks CLIPS for the next credential and retries. Configuration controls max retries, max credentials to try, and max interval between retries.

### Erlang redesign: retry in the conductor

Since CLIPS already tracks credential state (the failed credential gets cooldown facts asserted), the conductor simply re-runs selection:

```erlang
-module(conductor).
-behaviour(gen_server).

handle_call({execute, Model, Request, Opts}, From, State) ->
    MaxRetries = config_loader:get(request_retry, 3),
    MaxCredentials = config_loader:get(max_retry_credentials, 0),
    spawn_link(fun() ->
        Result = execute_with_retry(Model, Request, Opts, MaxRetries, MaxCredentials, 0),
        gen_server:reply(From, Result)
    end),
    {noreply, State}.

execute_with_retry(_Model, _Request, _Opts, 0, _MaxCreds, _Tried) ->
    {error, max_retries_exceeded};
execute_with_retry(Model, Request, Opts, Retries, MaxCreds, Tried)
  when MaxCreds > 0, Tried >= MaxCreds ->
    {error, max_credentials_exceeded};
execute_with_retry(Model, Request, Opts, Retries, MaxCreds, Tried) ->
    %% 1. Select credential via CLIPS
    case select_credential(Model, Opts) of
        {error, no_credential} -> {error, no_credential_available};
        {ok, AuthId, Provider} ->
            %% 2. Get translated request
            TranslatorMod = translator_registry:get(
                maps:get(source_format, Opts), Provider),
            TranslatedReq = TranslatorMod:request(Model, Request,
                                                   maps:get(stream, Opts, false)),
            %% 3. Apply payload rules
            Final = payload_rules:apply(TranslatedReq, Model, Provider,
                                        config_loader:get(payload, #{})),
            %% 4. Execute
            case executor:execute(Provider, AuthId, Final, Opts) of
                {ok, Response} ->
                    %% Success — mark in CLIPS
                    credential_proc:mark_result(AuthId, Model, 200),
                    {ok, Response};
                {error, Status, Body} when Status =:= 408;
                                           Status =:= 500;
                                           Status =:= 502;
                                           Status =:= 503;
                                           Status =:= 504 ->
                    %% Retriable — mark failure, retry with different credential
                    credential_proc:mark_result(AuthId, Model, Status),
                    maybe_wait(Retries),
                    execute_with_retry(Model, Request, Opts,
                                       Retries - 1, MaxCreds, Tried + 1);
                {error, Status, Body} ->
                    %% Non-retriable error
                    credential_proc:mark_result(AuthId, Model, Status),
                    {error, Status, Body}
            end
    end.

maybe_wait(Retries) ->
    MaxInterval = config_loader:get(max_retry_interval, 0),
    case MaxInterval > 0 of
        true -> timer:sleep(min(MaxInterval * 1000, 5000));
        false -> ok
    end.
```

The key insight: CLIPS rules automatically exclude the just-failed credential (it's now in cooldown), so the next `select_credential/2` call returns a different one without any explicit exclusion logic.

## Image Generation

### Endpoint support

The proxy supports image generation endpoints:

```erlang
%% Routes
{"/v1/images/generations", image_handler, [generations]},
{"/v1/images/edits", image_handler, [edits]}
```

### Disable flag

Image generation can be disabled via config:

```erlang
-module(image_handler).

init(Req, [Type] = State) ->
    case config_loader:get(disable_image_generation) of
        <<"on">> ->
            {ok, cowboy_req:reply(403,
                #{<<"content-type">> => <<"application/json">>},
                jiffy:encode(#{error => <<"Image generation is disabled">>}),
                Req), State};
        _ ->
            handle_request(Req, Type, State)
    end.
```

### Payload rule integration

When `disable_image_generation` is set, payload rules also strip image generation tools from chat/responses requests (preventing tool-based image generation):

```erlang
%% In payload_rules:apply/4, before other rules:
maybe_strip_image_tools(Body, Config) ->
    case maps:get(disable_image_generation, Config, <<"off">>) of
        <<"off">> -> Body;
        _ ->
            Tools = maps:get(<<"tools">>, Body, []),
            Filtered = [T || T <- Tools,
                         maps:get(<<"type">>, T, <<>>) =/= <<"image_generation">>],
            case Filtered =:= Tools of
                true -> Body;
                false -> Body#{<<"tools">> => Filtered}
            end
    end.
```

## Keep-Alive & Timeouts

### Streaming keep-alive

For long-running streaming requests, the proxy sends periodic keep-alive signals to prevent client/proxy timeouts:

```erlang
-module(stream_keepalive).

%% Sends empty SSE comment every 30 seconds during streaming
start(CallerPid) ->
    spawn_link(fun() -> keepalive_loop(CallerPid) end).

keepalive_loop(CallerPid) ->
    receive
        stop -> ok
    after 30_000 ->
        CallerPid ! {keepalive, <<": keepalive\n\n">>},
        keepalive_loop(CallerPid)
    end.
```

### Request timeouts

```erlang
%% Per-request timeout based on streaming vs non-streaming
request_timeout(#{stream := true}) ->
    config_loader:get(streaming_timeout, 300_000);     %% 5 minutes for streaming
request_timeout(#{stream := false}) ->
    config_loader:get(nonstream_timeout, 120_000).     %% 2 minutes for non-streaming
```

## Logging System

### Request logging

The Erlang request logger is a gen_server that receives log entries asynchronously:

```erlang
-module(request_logger).
-behaviour(gen_server).

-record(log_entry, {
    id          :: binary(),
    timestamp   :: integer(),
    method      :: binary(),
    path        :: binary(),
    status      :: integer(),
    latency_ms  :: integer(),
    ttfb_ms     :: integer() | undefined,
    model       :: binary(),
    provider    :: binary(),
    auth_id     :: binary(),
    request_body  :: binary() | undefined,
    response_body :: binary() | undefined,
    tokens      :: map(),
    error       :: binary() | undefined
}).

handle_cast({log, Entry}, #state{enabled = true, mode = Mode} = State) ->
    case should_log(Entry, Mode) of
        true ->
            write_entry(Entry, State),
            maybe_forward_home(Entry, State);
        false ->
            ok
    end,
    {noreply, State};
handle_cast({log, _Entry}, #state{enabled = false} = State) ->
    {noreply, State}.

should_log(#log_entry{status = S}, error_only) when S < 400 -> false;
should_log(_, _) -> true.
```

### Log rotation

```erlang
-module(log_rotator).

rotate_if_needed(#state{max_total_size_mb = 0}) ->
    ok;  %% Rotation disabled
rotate_if_needed(#state{log_dir = Dir, max_total_size_mb = MaxMB}) ->
    Files = filelib:wildcard(filename:join(Dir, "*.log")),
    TotalSize = lists:sum([filelib:file_size(F) || F <- Files]),
    case TotalSize > MaxMB * 1024 * 1024 of
        true ->
            %% Remove oldest files until under limit
            Sorted = lists:sort(fun(A, B) ->
                filelib:last_modified(A) < filelib:last_modified(B)
            end, Files),
            prune_oldest(Sorted, TotalSize, MaxMB * 1024 * 1024);
        false ->
            ok
    end.
```

### Error log files

Per-request error logs (detailed body captures for failed requests):

```erlang
handle_cast({log_error, ReqId, Details}, #state{error_log_dir = Dir,
                                                  error_max_files = Max} = State) ->
    Filename = io_lib:format("~s-~s.json", [date_string(), ReqId]),
    Path = filename:join(Dir, Filename),
    ok = file:write_file(Path, jiffy:encode(Details)),
    %% Rotate if too many files
    cleanup_error_logs(Dir, Max),
    {noreply, State}.
```

## Updated Module Structure

The final module structure incorporating all subsystems:

```
cli_proxy/
├── apps/
│   ├── cli_proxy/
│   │   ├── src/
│   │   │   ├── cli_proxy_app.erl
│   │   │   ├── cli_proxy_sup.erl
│   │   │   │
│   │   │   ├── http/
│   │   │   │   ├── openai_handler.erl
│   │   │   │   ├── claude_handler.erl
│   │   │   │   ├── gemini_handler.erl
│   │   │   │   ├── responses_handler.erl       # POST /v1/responses
│   │   │   │   ├── responses_ws_handler.erl    # WS /v1/responses
│   │   │   │   ├── responses_upstream.erl      # Upstream WS connection
│   │   │   │   ├── responses_compact_handler.erl
│   │   │   │   ├── codex_direct_handler.erl    # /backend-api/codex/*
│   │   │   │   ├── gemini_cli_handler.erl      # /v1internal:method
│   │   │   │   ├── ws_handler.erl              # AI Studio runtime WS
│   │   │   │   ├── image_handler.erl           # /v1/images/*
│   │   │   │   ├── models_handler.erl          # GET /v1/models
│   │   │   │   ├── health_handler.erl          # /healthz
│   │   │   │   ├── management_handler.erl      # /v0/management/*
│   │   │   │   ├── oauth_callback_handler.erl  # /*/callback
│   │   │   │   └── amp_handler.erl             # /api/provider/*
│   │   │   │
│   │   │   ├── conductor/
│   │   │   │   ├── conductor.erl               # Request orchestration + retry
│   │   │   │   ├── clips_engine.erl            # CLIPS port wrapper
│   │   │   │   ├── credential_proc.erl         # gen_statem per credential
│   │   │   │   └── credential_sup.erl          # simple_one_for_one
│   │   │   │
│   │   │   ├── executor/
│   │   │   │   ├── claude_executor.erl
│   │   │   │   ├── codex_executor.erl
│   │   │   │   ├── codex_ws_executor.erl       # Codex WebSocket mode
│   │   │   │   ├── gemini_executor.erl
│   │   │   │   ├── gemini_cli_executor.erl
│   │   │   │   ├── vertex_executor.erl
│   │   │   │   ├── antigravity_executor.erl
│   │   │   │   ├── kimi_executor.erl
│   │   │   │   ├── aistudio_executor.erl
│   │   │   │   └── openai_compat_executor.erl
│   │   │   │
│   │   │   ├── translator/
│   │   │   │   ├── translator.erl              # Behaviour definition
│   │   │   │   ├── translator_registry.erl     # ETS-backed registry
│   │   │   │   ├── translator_openai_claude.erl
│   │   │   │   ├── translator_claude_openai.erl
│   │   │   │   ├── translator_openai_responses_claude.erl
│   │   │   │   ├── translator_claude_gemini.erl
│   │   │   │   ├── translator_gemini_claude.erl
│   │   │   │   ├── translator_openai_gemini.erl
│   │   │   │   ├── translator_gemini_openai.erl
│   │   │   │   ├── translator_codex_claude.erl
│   │   │   │   ├── translator_codex_openai.erl
│   │   │   │   ├── translator_antigravity_claude.erl
│   │   │   │   └── ...                         # ~28 modules total
│   │   │   │
│   │   │   ├── oauth/
│   │   │   │   ├── oauth_session.erl           # gen_statem per login
│   │   │   │   ├── oauth_session_registry.erl  # Track active sessions
│   │   │   │   ├── oauth_claude.erl            # Claude PKCE flow
│   │   │   │   ├── oauth_codex.erl             # Codex PKCE + device
│   │   │   │   ├── oauth_gemini.erl            # Google OAuth2
│   │   │   │   ├── oauth_antigravity.erl       # Antigravity flow
│   │   │   │   ├── oauth_kimi.erl              # Kimi device flow
│   │   │   │   └── vertex_import.erl           # Service account import
│   │   │   │
│   │   │   ├── config/
│   │   │   │   ├── config_watcher.erl          # fs:subscribe + hash compare
│   │   │   │   ├── config_loader.erl           # ETS-backed config access
│   │   │   │   └── config_types.hrl            # Record definitions
│   │   │   │
│   │   │   ├── registry/
│   │   │   │   ├── model_registry.erl          # gen_server + ETS
│   │   │   │   └── model_updater.erl           # Periodic remote fetch
│   │   │   │
│   │   │   ├── cache/
│   │   │   │   └── signature_cache.erl         # ETS with TTL sweep
│   │   │   │
│   │   │   ├── store/
│   │   │   │   ├── auth_store.erl              # Behaviour
│   │   │   │   ├── file_store.erl
│   │   │   │   ├── pg_store.erl
│   │   │   │   ├── git_store.erl
│   │   │   │   └── s3_store.erl
│   │   │   │
│   │   │   ├── home/
│   │   │   │   ├── home_client.erl             # Satellite gen_server
│   │   │   │   └── home_config.erl             # Home-side config broadcaster
│   │   │   │
│   │   │   ├── amp/
│   │   │   │   ├── amp_config.erl              # Hot-reloadable config
│   │   │   │   ├── amp_secret.erl              # Multi-tier key resolution
│   │   │   │   └── amp_model_mapper.erl        # Regex model mapping
│   │   │   │
│   │   │   ├── logging/
│   │   │   │   ├── request_logger.erl          # Async gen_server logger
│   │   │   │   ├── log_rotator.erl             # Size-based rotation
│   │   │   │   └── usage_logger.erl            # Usage stats + queue
│   │   │   │
│   │   │   ├── access/
│   │   │   │   └── access_control.erl          # API key validation
│   │   │   │
│   │   │   ├── rules/
│   │   │   │   └── payload_rules.erl           # Default/override/filter
│   │   │   │
│   │   │   └── util/
│   │   │       ├── stream_keepalive.erl
│   │   │       ├── sse_parser.erl              # SSE event parsing
│   │   │       └── browser.erl                 # Cross-platform browser open
│   │   │
│   │   └── priv/
│   │       ├── clips/
│   │       │   ├── templates.clp
│   │       │   ├── selection.clp
│   │       │   ├── cooldown.clp
│   │       │   ├── thinking.clp
│   │       │   ├── routing.clp
│   │       │   └── quota.clp
│   │       │
│   │       ├── models.json
│   │       └── management_ui/                  # Static files for control panel
│   │
│   └── clips_port/
│       ├── src/
│       │   ├── main.c
│       │   └── clips_bridge.c
│       └── Makefile
│
├── config/
│   ├── sys.config
│   ├── vm.args
│   └── config.example.yaml
│
├── rebar.config
├── Dockerfile
└── docker-compose.yml
```

## Final Summary

This document now covers the complete system redesign from Go to Erlang/OTP + CLIPS:

| Area | Go implementation | Erlang redesign | Key advantage |
|------|-------------------|-----------------|---------------|
| **Auth Conductor** | 5000-line imperative engine | ~200 CLIPS rules | Independently testable, auditable rules |
| **Concurrency** | goroutines + channels + mutex | OTP processes + supervisors | No shared mutable state, crash isolation |
| **Protocol Translation** | 107 files, `param *any` accumulator | `translator` behaviour, process-local state | Type-safe callbacks, no casting |
| **OAuth Flows** | Linear functions with error returns | `gen_statem` per session | Crash-recoverable state machines |
| **Token Refresh** | Min-heap + 16-worker pool | Process-per-credential | No contention, natural scheduling |
| **WebSocket (Responses)** | 1191-line handler + global caches | Per-connection process with ETS | No mutex, process = session |
| **Home Control Plane** | Custom Redis RESP protocol | Erlang distribution | Zero infrastructure, native clustering |
| **Config Hot-Reload** | fsnotify + debounce + hash | `fs:subscribe` + `rest_for_one` | Supervisor guarantees ordering |
| **Model Registry** | Nested maps + `sync.RWMutex` | ETS + `gen_server` | Lock-free reads, serialized writes |
| **Signature Cache** | `sync.Map` + background goroutine | ETS + periodic sweep | `read_concurrency`, no GC pressure |
| **Payload Rules** | Applied in executor pipeline | Pure function module | Testable without process context |
| **Retry Logic** | Embedded in conductor | CLIPS re-selection loop | Failed credential auto-excluded by rules |
| **Logging** | Goroutine + channel + file rotation | `gen_server` + `gen_event` | Backpressure via mailbox, no dropped logs |
| **Deployment** | Single static binary | OTP release + CLIPS port | Hot code upgrades, remote shell debugging |
