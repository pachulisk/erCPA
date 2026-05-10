;;; ============================================================
;;; Model Routing Rules
;;; Maps models to providers based on model-capability facts
;;; ============================================================

(defrule route-model-to-provider
  "When selecting for a model, only consider credentials from matching provider"
  (declare (salience 95))
  (select-request (id ?rid) (model ?m))
  (model-capability (model ?m) (provider ?p))
  (credential (id ?cid) (provider ?cp))
  (test (neq ?p ?cp))
  (not (candidate (request-id ?rid) (credential-id ?cid)))
  =>
  (assert (candidate (request-id ?rid) (credential-id ?cid) (score -1)
                      (reason "provider-mismatch"))))
