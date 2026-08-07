;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_config.lsp
;;; Stage 6: settings storage
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Default settings
;;; ------------------------------------------------------------

(defun lcm:config-defaults ()
  (list
    (cons "LAYER_ZERO" "")
    (cons "LAYER_LAST" "")
    (cons "COLOR_MODE" 0)
    (cons "ACI" 1)
    (cons "RGB" (list 255 0 0))
    (cons "TEXT_HEIGHT" 2.5)
    (cons "SCALE" 5.0)
    (cons "TEXT_SEARCH_RADIUS" 50.0)
  )
)


;;; ------------------------------------------------------------
;;; Get full path to settings file
;;; ------------------------------------------------------------

(defun lcm:config-path (/ main-path)
  (setq main-path (findfile "lcm_main.lsp"))

  (if main-path
    (strcat
      (vl-filename-directory main-path)
      "/settings/lcm_settings.cfg"
    )
    nil
  )
)


;;; ------------------------------------------------------------
;;; Ensure settings folder exists
;;; ------------------------------------------------------------

(defun lcm:config-ensure-folder (/ main-path folder)
  (setq main-path (findfile "lcm_main.lsp"))

  (if main-path
    (progn
      (setq folder
        (strcat
          (vl-filename-directory main-path)
          "/settings"
        )
      )

      (if (not (vl-file-directory-p folder))
        (vl-mkdir folder)
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Helper: set value in association list
;;; ------------------------------------------------------------

(defun lcm:list-assoc-set (lst key val / pair)
  (setq pair (assoc key lst))

  (if pair
    (subst (cons key val) pair lst)
    (append lst (list (cons key val)))
  )
)


;;; ------------------------------------------------------------
;;; Get setting value
;;; ------------------------------------------------------------

(defun lcm:config-get (key / pair)
  (setq pair (assoc key lcm:settings))

  (if pair
    (cdr pair)
    nil
  )
)


;;; ------------------------------------------------------------
;;; Set setting value in memory
;;; ------------------------------------------------------------

(defun lcm:config-set (key val)
  (setq lcm:settings
    (lcm:list-assoc-set lcm:settings key val)
  )
)


;;; ------------------------------------------------------------
;;; Load settings from file
;;; ------------------------------------------------------------

(defun lcm:config-load (/ path file line text data item)

  (setq lcm:settings (lcm:config-defaults))

  (setq path (lcm:config-path))

  (if path
    (progn
      (setq file (open path "r"))

      (if file
        (progn

          ;; Read whole file content as a string
          (setq text "")

          (while (setq line (read-line file))
            (setq text (strcat text line))
          )

          (close file)

          ;; Parse LISP expression from string
          (if (/= text "")
            (progn

              (setq data
                (vl-catch-all-apply 'read (list text))
              )

              (if (vl-catch-all-error-p data)
                (progn
                  (prompt
                    "\nLCM WARNING: cannot parse settings file. Using defaults."
                  )
                  (setq data nil)
                )
              )

              (if (listp data)
                (foreach item data
                  (if (and
                        (listp item)
                        (assoc (car item) lcm:settings)
                      )
                    (setq lcm:settings
                      (lcm:list-assoc-set
                        lcm:settings
                        (car item)
                        (cdr item)
                      )
                    )
                  )
                )
              )
            )
          )
        )
      )
    )
  )

  ;; Apply saved text search radius to data module
  (setq lcm:text-search-radius
    (lcm:config-get "TEXT_SEARCH_RADIUS")
  )

  lcm:settings
)


;;; ------------------------------------------------------------
;;; Save settings to file
;;; ------------------------------------------------------------

(defun lcm:config-save (/ path file)

  (lcm:config-ensure-folder)

  (setq path (lcm:config-path))

  (if path
    (progn
      (setq file (open path "w"))

      (if file
        (progn
          (prin1 lcm:settings file)
          (close file)
          T
        )
        nil
      )
    )
    nil
  )
)


;;; ------------------------------------------------------------
;;; Initial loading of settings
;;; ------------------------------------------------------------

(lcm:config-load)

(princ)