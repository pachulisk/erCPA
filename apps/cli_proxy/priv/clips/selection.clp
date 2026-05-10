;;; ============================================================
;;; Credential Selection Rules
;;; Based on DESIGN.md Credential selection rules section
;;; ============================================================

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

;;; --- Quota-aware fallback (medium-high salience) ---

(defrule quota-exceeded-switch-project
  "When quota exceeded and switch-project enabled, try another credential"
  (declare (salience 60))
  (select-request (id ?rid) (model ?m))
  (quota-state (credential-id ?cid) (exceeded yes))
  (config-flag (name "switch-project") (value yes))
  (credential (id ?alt-cid&~?cid) (status active))
  (not (quota-state (credential-id ?alt-cid) (exceeded yes)))
  (not (candidate (request-id ?rid) (credential-id ?alt-cid)))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?alt-cid)
                      (score 50) (reason "quota-switch-project"))))

;;; --- Final selection (lowest salience, runs after scoring) ---

(defrule select-best-candidate
  "Pick highest-scoring candidate when no session affinity match"
  (declare (salience 10))
  (select-request (id ?rid))
  (not (selection-result (request-id ?rid)))
  (candidate (request-id ?rid) (credential-id ?cid) (score ?s))
  (not (candidate (request-id ?rid) (score ?s2&:(> ?s2 ?s))))
  (test (> ?s -1))
  =>
  (assert (selection-result (request-id ?rid) (credential-id ?cid)
                            (reason "best-score"))))
