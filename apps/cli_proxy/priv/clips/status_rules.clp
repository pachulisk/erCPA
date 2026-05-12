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
    (allowed-symbols retry cooldown quota-fallback pass))
  (slot error-type (type STRING) (default "internal_server_error"))
  (slot should-unpin-auth (type SYMBOL) (default no) (allowed-symbols yes no)))

;;; --- Retriable server errors ---

(defrule status-408-retriable
  "Request timeout — retriable"
  (declare (salience 50))
  ?si <- (status-input (id ?id) (status-code 408))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable yes) (cooldown-seconds 0)
                         (quota-fallback no) (action retry)
                         (error-type "request_timeout") (should-unpin-auth no))))

(defrule status-5xx-retriable
  "Server errors 500-504 — retriable"
  (declare (salience 50))
  ?si <- (status-input (id ?id) (status-code ?s&:(and (>= ?s 500) (<= ?s 504))))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable yes) (cooldown-seconds 0)
                         (quota-fallback no) (action retry)
                         (error-type "internal_server_error") (should-unpin-auth no))))

;;; --- Rate limit / quota ---

(defrule status-429-quota
  "Rate limited — trigger quota fallback, unpin auth"
  (declare (salience 60))
  ?si <- (status-input (id ?id) (status-code 429))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 300)
                         (quota-fallback yes) (action quota-fallback)
                         (error-type "rate_limit_exceeded") (should-unpin-auth yes))))

;;; --- Auth errors ---

(defrule status-401-auth
  "Unauthorized — unpin auth"
  (declare (salience 55))
  ?si <- (status-input (id ?id) (status-code 401))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 1800)
                         (quota-fallback no) (action cooldown)
                         (error-type "invalid_api_key") (should-unpin-auth yes))))

(defrule status-402-quota
  "Payment required — unpin auth"
  (declare (salience 55))
  ?si <- (status-input (id ?id) (status-code 402))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 1800)
                         (quota-fallback no) (action cooldown)
                         (error-type "insufficient_quota") (should-unpin-auth yes))))

(defrule status-403-forbidden
  "Forbidden — unpin auth"
  (declare (salience 55))
  ?si <- (status-input (id ?id) (status-code 403))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 1800)
                         (quota-fallback no) (action cooldown)
                         (error-type "forbidden") (should-unpin-auth yes))))

;;; --- Client errors ---

(defrule status-400-bad-request
  "Bad request"
  (declare (salience 45))
  ?si <- (status-input (id ?id) (status-code 400))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 0)
                         (quota-fallback no) (action pass)
                         (error-type "invalid_request_error") (should-unpin-auth no))))

(defrule status-404-not-found
  "Not found"
  (declare (salience 45))
  ?si <- (status-input (id ?id) (status-code 404))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 0)
                         (quota-fallback no) (action pass)
                         (error-type "model_not_found") (should-unpin-auth no))))

;;; --- Success ---

(defrule status-success
  "2xx — success, pass through"
  (declare (salience 40))
  ?si <- (status-input (id ?id) (status-code ?s&:(and (>= ?s 200) (< ?s 300))))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 0)
                         (quota-fallback no) (action pass)
                         (error-type "") (should-unpin-auth no))))

;;; --- Default: non-retriable ---

(defrule status-default
  "Any other status — not retriable"
  (declare (salience 10))
  ?si <- (status-input (id ?id) (status-code ?s))
  (not (status-output (id ?id)))
  =>
  (assert (status-output (id ?id) (retriable no) (cooldown-seconds 0)
                         (quota-fallback no) (action pass)
                         (error-type "internal_server_error") (should-unpin-auth no))))
