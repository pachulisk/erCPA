;;; ============================================================
;;; Thinking Normalization Rules
;;; Based on DESIGN.md Thinking normalization rules section
;;; ============================================================

(defrule clamp-budget-to-max
  "Budget exceeds model maximum"
  (declare (salience 80))
  ?ti <- (thinking-input (id ?id) (mode budget) (budget ?b) (model ?m))
  (model-capability (model ?m) (thinking-max ?max))
  (test (and (> ?b ?max) (> ?max 0)))
  =>
  (modify ?ti (budget ?max)))

(defrule clamp-budget-to-min
  "Budget below model minimum (and not zero/dynamic)"
  (declare (salience 80))
  ?ti <- (thinking-input (id ?id) (mode budget) (budget ?b) (model ?m))
  (model-capability (model ?m) (thinking-min ?min))
  (test (and (> ?b 0) (< ?b ?min) (> ?min 0)))
  =>
  (modify ?ti (budget ?min)))

(defrule convert-level-to-budget
  "Target model only supports budget, convert level"
  (declare (salience 70))
  ?ti <- (thinking-input (id ?id) (mode level) (level ?l) (model ?m))
  (model-capability (model ?m) (thinking-mode budget))
  =>
  (modify ?ti (mode budget) (budget (level-to-budget ?l ?m)) (level "")))

(defrule convert-budget-to-level
  "Target model only supports levels, convert budget"
  (declare (salience 70))
  ?ti <- (thinking-input (id ?id) (mode budget) (budget ?b) (model ?m))
  (model-capability (model ?m) (thinking-mode level))
  =>
  (modify ?ti (mode level) (level (budget-to-level ?b ?m)) (budget -1)))

(defrule emit-thinking-output
  "Normalization complete, emit result"
  (declare (salience 10))
  (thinking-input (id ?id) (mode ?mode) (budget ?b) (level ?l))
  (not (thinking-output (id ?id)))
  =>
  (assert (thinking-output (id ?id) (mode ?mode) (budget ?b) (level ?l))))
