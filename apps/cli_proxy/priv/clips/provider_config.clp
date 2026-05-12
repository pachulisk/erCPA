;;; ============================================================
;;; OAuth Provider Configuration
;;; Hot-reloadable provider registry — add providers without code change
;;; ============================================================

(deftemplate provider-info
  (slot provider (type STRING))
  (slot oauth-module (type STRING))
  (slot auth-flow (type SYMBOL)
    (allowed-symbols authorization-code device-code both)
    (default authorization-code))
  (slot callback-port (type INTEGER) (default 54545)))

;;; Default provider configurations
(deffacts default-providers
  (provider-info (provider "claude") (oauth-module "oauth_claude")
                 (auth-flow authorization-code) (callback-port 54545))
  (provider-info (provider "codex") (oauth-module "oauth_codex")
                 (auth-flow both) (callback-port 1455))
  (provider-info (provider "codex_device") (oauth-module "oauth_codex")
                 (auth-flow device-code) (callback-port 1455))
  (provider-info (provider "gemini") (oauth-module "oauth_gemini")
                 (auth-flow authorization-code) (callback-port 8085))
  (provider-info (provider "kimi") (oauth-module "oauth_kimi")
                 (auth-flow device-code) (callback-port 0))
  (provider-info (provider "antigravity") (oauth-module "oauth_antigravity")
                 (auth-flow authorization-code) (callback-port 54545)))
