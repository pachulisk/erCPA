;;; ============================================================
;;; CLI Proxy CLIPS Fact Templates
;;; Based on DESIGN.md CLIPS Fact Model section
;;; ============================================================

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
  (slot has-websocket (type SYMBOL) (default no)
    (allowed-symbols yes no)))

;;; --- Per-model state on a credential ---
(deftemplate model-state
  (slot credential-id (type STRING))
  (slot model (type STRING))
  (slot available (type SYMBOL) (default yes)
    (allowed-symbols yes no))
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
  (slot need-websocket (type SYMBOL) (default no)
    (allowed-symbols yes no))
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

;;; --- Result feedback (for state transitions) ---
(deftemplate result
  (slot credential-id (type STRING))
  (slot model (type STRING))
  (slot status-code (type INTEGER))
  (slot now (type INTEGER)))

;;; --- Thinking normalization (transient) ---
(deftemplate thinking-input
  (slot id (type STRING))
  (slot source-format (type STRING))     ; "openai" | "claude" | "gemini"
  (slot target-format (type STRING))
  (slot model (type STRING))
  (slot mode (type SYMBOL)               ; budget | level | none | auto
    (allowed-symbols budget level none auto))
  (slot budget (type INTEGER) (default -1))
  (slot level (type STRING) (default ""))
  (slot suffix-override (type SYMBOL) (default no)
    (allowed-symbols yes no)))

(deftemplate thinking-output
  (slot id (type STRING))
  (slot mode (type SYMBOL)
    (allowed-symbols budget level none))
  (slot budget (type INTEGER))
  (slot level (type STRING)))

;;; --- Quota state ---
(deftemplate quota-state
  (slot credential-id (type STRING))
  (slot exceeded (type SYMBOL) (default no)
    (allowed-symbols yes no))
  (slot reason (type STRING) (default ""))
  (slot recover-at (type INTEGER) (default 0))
  (slot backoff-level (type INTEGER) (default 0)))

;;; --- Configuration flags (for rule conditions) ---
(deftemplate config-flag
  (slot name (type STRING))
  (slot value (type SYMBOL)
    (allowed-symbols yes no)))
