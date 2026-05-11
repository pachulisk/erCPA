;;; ============================================================
;;; Cloaking Rules — Decide whether to disguise requests
;;; Hot-reloadable: change rules without Erlang code change
;;; ============================================================

(deftemplate cloak-input
  (slot id (type STRING))
  (slot user-agent (type STRING) (default ""))
  (slot mode (type SYMBOL) (default auto)
    (allowed-symbols auto always never)))

(deftemplate cloak-output
  (slot id (type STRING))
  (slot should-cloak (type SYMBOL) (allowed-symbols yes no))
  (slot reason (type STRING) (default "")))

(deftemplate sensitive-word
  (slot word (type STRING)))

;;; Default sensitive words (hot-configurable)
(deffacts default-sensitive-words
  (sensitive-word (word "proxy"))
  (sensitive-word (word "mirror"))
  (sensitive-word (word "relay"))
  (sensitive-word (word "forward")))

;;; --- Rules ---

(defrule cloak-mode-always
  "Always cloak regardless of User-Agent"
  (declare (salience 100))
  (cloak-input (id ?id) (mode always))
  (not (cloak-output (id ?id)))
  =>
  (assert (cloak-output (id ?id) (should-cloak yes) (reason "mode-always"))))

(defrule cloak-mode-never
  "Never cloak"
  (declare (salience 100))
  (cloak-input (id ?id) (mode never))
  (not (cloak-output (id ?id)))
  =>
  (assert (cloak-output (id ?id) (should-cloak no) (reason "mode-never"))))

(defrule cloak-auto-not-claude-cli
  "Auto mode: cloak if User-Agent is NOT claude-cli"
  (declare (salience 50))
  (cloak-input (id ?id) (mode auto) (user-agent ?ua&~""))
  (not (cloak-output (id ?id)))
  (test (not (str-index "claude-cli" ?ua)))
  =>
  (assert (cloak-output (id ?id) (should-cloak yes) (reason "auto-not-claude-cli"))))

(defrule cloak-auto-is-claude-cli
  "Auto mode: don't cloak if User-Agent starts with claude-cli"
  (declare (salience 50))
  (cloak-input (id ?id) (mode auto) (user-agent ?ua))
  (not (cloak-output (id ?id)))
  (test (neq (str-index "claude-cli" ?ua) FALSE))
  =>
  (assert (cloak-output (id ?id) (should-cloak no) (reason "auto-is-claude-cli"))))

(defrule cloak-auto-empty-ua
  "Auto mode: cloak if User-Agent is empty"
  (declare (salience 40))
  (cloak-input (id ?id) (mode auto) (user-agent ""))
  (not (cloak-output (id ?id)))
  =>
  (assert (cloak-output (id ?id) (should-cloak yes) (reason "auto-empty-ua"))))
