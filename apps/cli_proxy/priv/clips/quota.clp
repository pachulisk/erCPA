;;; ============================================================
;;; Quota Management Rules
;;; Based on DESIGN.md Quota & Usage Tracking section
;;; ============================================================

(defrule quota-mark-exceeded
  "Update quota state when credential reports exceeded"
  (declare (salience 90))
  (result (credential-id ?cid) (model ?m) (status-code 429) (now ?now))
  ?qs <- (quota-state (credential-id ?cid))
  =>
  (retract ?qs)
  (assert (quota-state (credential-id ?cid) (exceeded yes)
                        (reason "rate-limited")
                        (recover-at (+ ?now 300))
                        (backoff-level (+ (fact-slot-value ?qs backoff-level) 1)))))

(defrule quota-recover
  "Clear quota exceeded when recovery time passed"
  (declare (salience 85))
  (select-request (id ?rid) (now ?now))
  ?qs <- (quota-state (credential-id ?cid) (exceeded yes) (recover-at ?t))
  (test (<= ?t ?now))
  =>
  (retract ?qs)
  (assert (quota-state (credential-id ?cid) (exceeded no)
                        (reason "") (recover-at 0) (backoff-level 0))))
