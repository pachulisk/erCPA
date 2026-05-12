;;; ============================================================
;;; Credential Policy Rules
;;; Configurable cooldown durations and refresh schedules
;;; Hot-reloadable without Erlang code change
;;; ============================================================

;;; --- Templates (must be defined before deffacts) ---

(deftemplate refresh-schedule
  (slot provider (type STRING))
  (slot interval-ms (type INTEGER)))

(deftemplate cooldown-policy
  (slot id (type STRING))
  (slot status-code (type INTEGER))
  (slot cooldown-seconds (type INTEGER))
  (slot backoff-strategy (type SYMBOL)
    (allowed-symbols exponential fixed none)
    (default none)))

(deftemplate cooldown-query
  (slot id (type STRING))
  (slot status-code (type INTEGER))
  (slot backoff-level (type INTEGER) (default 0)))

(deftemplate cooldown-result
  (slot id (type STRING))
  (slot cooldown-seconds (type INTEGER))
  (slot new-backoff-level (type INTEGER)))

;;; --- Default refresh schedules (per provider, milliseconds) ---

(deffacts default-refresh-schedules
  (refresh-schedule (provider "claude") (interval-ms 14400000))      ; 4 hours
  (refresh-schedule (provider "codex") (interval-ms 432000000))      ; 5 days
  (refresh-schedule (provider "antigravity") (interval-ms 300000))   ; 5 minutes
  (refresh-schedule (provider "kimi") (interval-ms 300000))          ; 5 minutes
  (refresh-schedule (provider "*") (interval-ms 3600000)))           ; 1 hour default

;;; --- Cooldown rules ---

(defrule cooldown-429-exponential
  "Rate limit: exponential backoff, cap at 1800s"
  (declare (salience 50))
  ?q <- (cooldown-query (id ?id) (status-code 429) (backoff-level ?bl))
  (not (cooldown-result (id ?id)))
  =>
  (bind ?delay (min (integer (** 2 ?bl)) 1800))
  (assert (cooldown-result (id ?id) (cooldown-seconds ?delay)
                           (new-backoff-level (+ ?bl 1)))))

(defrule cooldown-auth-error
  "Auth errors: 30 minute hold"
  (declare (salience 50))
  ?q <- (cooldown-query (id ?id) (status-code ?s&:(and (>= ?s 401) (<= ?s 403)))
                        (backoff-level ?bl))
  (not (cooldown-result (id ?id)))
  =>
  (assert (cooldown-result (id ?id) (cooldown-seconds 1800)
                           (new-backoff-level 0))))

(defrule cooldown-5xx-short
  "Server errors: short cooldown, cap at 60s"
  (declare (salience 50))
  ?q <- (cooldown-query (id ?id) (status-code ?s&:(>= ?s 500))
                        (backoff-level ?bl))
  (not (cooldown-result (id ?id)))
  =>
  (bind ?delay (min (integer (** 2 ?bl)) 60))
  (assert (cooldown-result (id ?id) (cooldown-seconds ?delay)
                           (new-backoff-level (+ ?bl 1)))))

(defrule cooldown-success
  "2xx: clear cooldown"
  (declare (salience 60))
  ?q <- (cooldown-query (id ?id) (status-code ?s&:(and (>= ?s 200) (< ?s 300)))
                        (backoff-level ?bl))
  (not (cooldown-result (id ?id)))
  =>
  (assert (cooldown-result (id ?id) (cooldown-seconds 0)
                           (new-backoff-level 0))))

(defrule cooldown-default
  "Any other code: no cooldown"
  (declare (salience 10))
  ?q <- (cooldown-query (id ?id) (status-code ?s) (backoff-level ?bl))
  (not (cooldown-result (id ?id)))
  =>
  (assert (cooldown-result (id ?id) (cooldown-seconds 0)
                           (new-backoff-level ?bl))))
