;;; ============================================================
;;; Cooldown / State Transition Rules
;;; Based on DESIGN.md MarkResult as fact mutation section
;;; ============================================================

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
  (bind ?cooldown (min (* (** 2 ?bl) 1) 1800))
  (assert (model-state (credential-id ?cid) (model ?m)
                        (available no)
                        (cooldown-until (+ ?now ?cooldown))
                        (backoff-level (+ ?bl 1)))))

(defrule mark-unauthorized
  "30-minute hold on auth failure (401/402/403)"
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

(defrule mark-server-error
  "Short cooldown on 5xx (60 seconds)"
  (declare (salience 100))
  (result (credential-id ?cid) (model ?m) (status-code ?s) (now ?now))
  (test (and (>= ?s 500) (< ?s 600)))
  ?ms <- (model-state (credential-id ?cid) (model ?m) (backoff-level ?bl))
  =>
  (retract ?ms)
  (bind ?cooldown (min (* (** 2 ?bl) 1) 60))
  (assert (model-state (credential-id ?cid) (model ?m)
                        (available no)
                        (cooldown-until (+ ?now ?cooldown))
                        (backoff-level (+ ?bl 1)))))
