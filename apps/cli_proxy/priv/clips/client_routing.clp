;;; ============================================================
;;; Client Routing Rules — Per-client API key mapping
;;; Map different client keys to different upstream provider keys
;;; ============================================================

(deftemplate client-key-mapping
  (slot client-key (type STRING))
  (slot upstream-key (type STRING))
  (slot provider (type STRING) (default "*")))

(deftemplate client-route-query
  (slot id (type STRING))
  (slot client-key (type STRING))
  (slot provider (type STRING)))

(deftemplate client-route-result
  (slot id (type STRING))
  (slot upstream-key (type STRING)))

;;; --- Routing rules ---

(defrule route-exact-match
  "Exact client+provider match"
  (declare (salience 80))
  (client-route-query (id ?id) (client-key ?ck) (provider ?p))
  (client-key-mapping (client-key ?ck) (upstream-key ?uk) (provider ?p))
  (not (client-route-result (id ?id)))
  =>
  (assert (client-route-result (id ?id) (upstream-key ?uk))))

(defrule route-wildcard-provider
  "Client match with wildcard provider"
  (declare (salience 50))
  (client-route-query (id ?id) (client-key ?ck) (provider ?p))
  (client-key-mapping (client-key ?ck) (upstream-key ?uk) (provider "*"))
  (not (client-route-result (id ?id)))
  =>
  (assert (client-route-result (id ?id) (upstream-key ?uk))))

(defrule route-no-match
  "No mapping found — use original key"
  (declare (salience 10))
  (client-route-query (id ?id) (client-key ?ck))
  (not (client-route-result (id ?id)))
  =>
  (assert (client-route-result (id ?id) (upstream-key ?ck))))
