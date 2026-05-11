;;; ============================================================
;;; Response Rewrite Rules
;;; Configurable model name, tool name, signature transformations
;;; ============================================================

(deftemplate rewrite-tool-name
  (slot from (type STRING))
  (slot to (type STRING)))

;;; Default tool name normalization rules (Amp compatibility)
(deffacts default-tool-rewrites
  (rewrite-tool-name (from "bash") (to "Bash"))
  (rewrite-tool-name (from "read") (to "Read"))
  (rewrite-tool-name (from "grep") (to "Grep"))
  (rewrite-tool-name (from "task") (to "Task"))
  (rewrite-tool-name (from "check") (to "Check")))
