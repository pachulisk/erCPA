;;; ============================================================
;;; Status Code Handling Rules
;;; Classifies HTTP status codes into actions for retry/cooldown
;;; ============================================================

;;; Templates for status classification (transient)

(deftemplate status-input
  (slot id (type STRING))
  (slot status-code (type INTEGER))
  (slot model (type STRING) (default ""))
  (slot credential-id (type STRING) (default "")))

(deftemplate status-output
  (slot id (type STRING))
  (slot retriable (type SYMBOL) (allowed-symbols yes no))
  (slot cooldown-seconds (type INTEGER) (default 0))
  (slot quota-fallback (type SYMBOL) (default no) (allowed-symbols yes no))
  (slot action (type SYMBOL)
    (allowed-symbols retry cooldown quota-fallback pass)))

;;; --- Retriable server errors ---

(defrule status-408-retriable
  "Request timeout — retriable"
  (declare (salience 50))
  ?si <- (status-input (id ?id) (status-code 408))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable yes) (cooldown-seconds 0)
                         (quota-fallback no) (action retry))))

(defrule status-5xx-retriable
  "Server errors 500-504 — retriable"
  (declare (salience 50))
  ?si <- (status-input (id ?id) (status-code ?s&:(and (>= ?s 500) (<= ?s 504))))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable yes) (cooldown-seconds 0)
                         (quota-fallback no) (action retry))))

;;; --- Rate limit / quota ---

(defrule status-429-quota
  "Rate limited — trigger quota fallback"
  (declare (salience 60))
  ?si <- (status-input (id ?id) (status-code 429))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 300)
                         (quota-fallback yes) (action quota-fallback))))

;;; --- Auth errors ---

(defrule status-auth-error
  "Auth errors 401/402/403 — long cooldown, no retry"
  (declare (salience 50))
  ?si <- (status-input (id ?id) (status-code ?s&:(and (>= ?s 401) (<= ?s 403))))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 1800)
                         (quota-fallback no) (action cooldown))))

;;; --- Success ---

(defrule status-success
  "2xx — success, pass through"
  (declare (salience 40))
  ?si <- (status-input (id ?id) (status-code ?s&:(and (>= ?s 200) (< ?s 300))))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 0)
                         (quota-fallback no) (action pass))))

;;; --- Default: non-retriable ---

(defrule status-default
  "Any other status — not retriable"
  (declare (salience 10))
  ?si <- (status-input (id ?id) (status-code ?s))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 0)
                         (quota-fallback no) (action pass))))
