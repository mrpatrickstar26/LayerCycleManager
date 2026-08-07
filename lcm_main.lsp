;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_main.lsp
;;; Stage 2: entry point and test command
;;; ============================================================

;;; Load Visual LISP COM support
(vl-load-com)


;;; ------------------------------------------------------------
;;; Global program variables
;;; ------------------------------------------------------------

(setq lcm:version "0.3.0")

;;; Debug mode:
;;; T   - show module loading messages
;;; nil - quiet mode
(setq lcm:debug T)

;;; UI readiness flag.
;;; Later lcm_ui.lsp will set this to T when dialog functions exist.
(setq lcm:ui-loaded nil)


;;; ------------------------------------------------------------
;;; Safe module loader
;;; ------------------------------------------------------------

(defun lcm:load-module (file-name / file-path load-result)

  (setq file-path (findfile file-name))

  (if file-path

    ;; File found
    (progn
      (setq load-result
        (vl-catch-all-apply 'load (list file-path))
      )

      (if (vl-catch-all-error-p load-result)

        ;; Load error
        (prompt
          (strcat
            "\nLCM ERROR: failed to load module: "
            file-path
          )
        )

        ;; Load success
        (if lcm:debug
          (prompt
            (strcat
              "\nLCM: loaded module: "
              file-path
            )
          )
        )
      )

      ;; Return T if no error
      (not (vl-catch-all-error-p load-result))
    )

    ;; File not found
    (progn
      (if lcm:debug
        (prompt
          (strcat
            "\nLCM: module not found: "
            file-name
          )
        )
      )
      nil
    )
  )
)


;;; ------------------------------------------------------------
;;; Load project modules
;;; ------------------------------------------------------------

(defun lcm:load-modules (/)

  ;; Reset UI flag before loading modules
  (setq lcm:ui-loaded nil)

  (lcm:load-module "lcm_config.lsp")
  (lcm:load-module "lcm_data.lsp")
  (lcm:load-module "lcm_core.lsp")
  (lcm:load-module "lcm_ui.lsp")

  (princ)
)


;;; ------------------------------------------------------------
;;; Main start function
;;; ------------------------------------------------------------

(defun lcm:start (/)

  (prompt
    (strcat
      "\nLayer Cycle Manager v"
      lcm:version
    )
  )

  (if lcm:ui-loaded

    ;; If UI module says it is ready
    (progn
      (if lcm:debug
        (prompt "\nLCM: starting UI...")
      )

      (lcm:show-main-dialog)
    )

    ;; If UI is not implemented yet
    (prompt
      "\nLCM: UI is not implemented yet. Command LCM works."
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; AutoCAD command: LCM
;;; ------------------------------------------------------------

(defun C:LCM (/)
  (lcm:start)
  (princ)
)


;;; ------------------------------------------------------------
;;; Development helper command: LCMRELOAD
;;; ------------------------------------------------------------

(defun C:LCMRELOAD (/)
  (prompt "\nLCM: reloading modules...")
  (lcm:load-modules)
  (prompt "\nLCM: modules reloaded.")
  (princ)
)


;;; ------------------------------------------------------------
;;; Initial loading
;;; ------------------------------------------------------------

(lcm:load-modules)

;;; Flag that main module is loaded
(setq lcm:loaded T)

;;; Suppress return value in command line
(princ)