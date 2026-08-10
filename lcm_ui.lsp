;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_ui.lsp
;;; DCL interface logic: ByLayer toggle, ACI picker, arrow deletion
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; UI global variables
;;; ------------------------------------------------------------

(setq lcm:placeholder "<not found>")

(if (not lcm:layers)
  (setq lcm:layers '())
)

(if (not lcm:points-zero)
  (setq lcm:points-zero '())
)

(if (not lcm:points-last)
  (setq lcm:points-last '())
)

(if (not lcm:maps)
  (setq lcm:maps '())
)


;;; ------------------------------------------------------------
;;; Helper: get selected value from popup_list
;;; ------------------------------------------------------------

(defun lcm:ui-get-popup-value (key lst / val idx)
  (setq val (get_tile key))

  (if (= val "")
    nil
    (progn
      (setq idx (atoi val))

      (if (and lst (>= idx 0) (< idx (length lst)))
        (nth idx lst)
        nil
      )
    )
  )
)


;;; ------------------------------------------------------------
;;; Helper: select item in popup_list by value
;;; ------------------------------------------------------------

(defun lcm:ui-select-item (key lst value / idx)
  (if (and lst (> (length lst) 0))
    (progn
      (if value
        (progn
          (setq idx (vl-position value lst))

          (if idx
            (set_tile key (itoa idx))
            (set_tile key "0")
          )
        )
        (set_tile key "0")
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Fill layer popup lists
;;; ------------------------------------------------------------

(defun lcm:ui-fill-layers
  (
    /
    current-zero
    current-last
    layer-count
  )

  (setq current-zero
    (lcm:ui-get-popup-value "layer_zero" lcm:layers)
  )

  (setq current-last
    (lcm:ui-get-popup-value "layer_last" lcm:layers)
  )

  (setq lcm:layers (lcm:get-layers))

  (start_list "layer_zero")
  (foreach layer lcm:layers
    (add_list layer)
  )
  (end_list)

  (start_list "layer_last")
  (foreach layer lcm:layers
    (add_list layer)
  )
  (end_list)

  (setq layer-count (length lcm:layers))

  (if (> layer-count 0)
    (progn

      (if current-zero
        (lcm:ui-select-item "layer_zero" lcm:layers current-zero)
        (set_tile "layer_zero" "0")
      )

      (if current-last
        (lcm:ui-select-item "layer_last" lcm:layers current-last)
        (if (> layer-count 1)
          (set_tile "layer_last" "1")
          (set_tile "layer_last" "0")
        )
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Fill deletion layer popup list
;;; ------------------------------------------------------------

(defun lcm:ui-fill-del-layer (/ current)

  (setq current
    (lcm:ui-get-popup-value "del_layer" lcm:layers)
  )

  (start_list "del_layer")
  (foreach layer lcm:layers
    (add_list layer)
  )
  (end_list)

  (if current
    (lcm:ui-select-item "del_layer" lcm:layers current)
    (if (> (length lcm:layers) 0)
      (set_tile "del_layer" "0")
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Point name helpers
;;; ------------------------------------------------------------

(defun lcm:ui-point-names-zero ()
  (mapcar 'car lcm:points-zero)
)

(defun lcm:ui-point-names-last ()
  (mapcar 'car lcm:points-last)
)


;;; ------------------------------------------------------------
;;; Fill point mapping popup lists
;;; ------------------------------------------------------------

(defun lcm:ui-fill-point-combos ()

  (start_list "map_from")
  (foreach item lcm:points-zero
    (add_list (car item))
  )
  (end_list)

  (start_list "map_to")
  (foreach item lcm:points-last
    (add_list (car item))
  )
  (end_list)

  (if (> (length lcm:points-zero) 0)
    (progn
      (set_tile "map_from" "0")
      (set_tile "map_from_edit" (nth 0 (lcm:ui-point-names-zero)))
    )
  )

  (if (> (length lcm:points-last) 0)
    (progn
      (set_tile "map_to" "0")
      (set_tile "map_to_edit" (nth 0 (lcm:ui-point-names-last)))
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Refresh points after layer selection
;;; ------------------------------------------------------------

(defun lcm:ui-refresh-points (/ layer-zero layer-last)

  (setq layer-zero
    (lcm:ui-get-popup-value "layer_zero" lcm:layers)
  )

  (setq layer-last
    (lcm:ui-get-popup-value "layer_last" lcm:layers)
  )

  (if layer-zero
    (setq lcm:points-zero
      (lcm:get-points-with-names layer-zero)
    )
    (setq lcm:points-zero '())
  )

  (if layer-last
    (setq lcm:points-last
      (lcm:get-points-with-names layer-last)
    )
    (setq lcm:points-last '())
  )

  (set_tile
    "info"
    (strcat
      "Точек в нулевом слое: "
      (itoa (length lcm:points-zero))
      " | Точек в последнем слое: "
      (itoa (length lcm:points-last))
    )
  )

  (lcm:ui-fill-point-combos)

  (lcm:ui-fill-mappings)

  (princ)
)


;;; ------------------------------------------------------------
;;; Mapping list helpers
;;; ------------------------------------------------------------

(defun lcm:ui-map-display (m / from to)
  (setq from (cdr (assoc 'from m)))
  (setq to (cdr (assoc 'to m)))

  (strcat from " -> " to)
)


(defun lcm:ui-fill-mappings ()

  (start_list "mappings")

  (foreach m lcm:maps
    (add_list (lcm:ui-map-display m))
  )

  (end_list)

  (princ)
)


(defun lcm:ui-get-list-index (key / val idx)
  (setq val (get_tile key))

  (if (= val "")
    nil
    (progn
      (setq idx (atoi val))

      (if (and (>= idx 0) (< idx (length lcm:maps)))
        idx
        nil
      )
    )
  )
)


(defun lcm:list-set-nth (lst idx new / i out)
  (setq i 0)
  (setq out '())

  (foreach item lst
    (if (= i idx)
      (setq out (cons new out))
      (setq out (cons item out))
    )

    (setq i (1+ i))
  )

  (reverse out)
)


(defun lcm:list-remove-nth (lst idx / i out)
  (setq i 0)
  (setq out '())

  (foreach item lst
    (if (/= i idx)
      (setq out (cons item out))
    )

    (setq i (1+ i))
  )

  (reverse out)
)

;;; ------------------------------------------------------------
;;; When user picks value from popup, copy it into edit box
;;; ------------------------------------------------------------

(defun lcm:ui-popup-sync (popup-key edit-key lst / val)
  (setq val (lcm:ui-get-popup-value popup-key lst))

  (if val
    (set_tile edit-key val)
  )

  (princ)
)

;;; ------------------------------------------------------------
;;; Add mapping
;;; ------------------------------------------------------------

(defun lcm:ui-add-map (/ from to new)

  (setq from (vl-string-trim " " (get_tile "map_from_edit")))
  (setq to (vl-string-trim " " (get_tile "map_to_edit")))

  (cond

    ((or (= from "") (= to ""))
     (alert "Введите имена точек или выберите их из списков.")
    )

    ((not (member from (lcm:ui-point-names-zero)))
     (alert (strcat "Точка \"" from "\" не найдена в нулевом слое."))
    )

    ((not (member to (lcm:ui-point-names-last)))
     (alert (strcat "Точка \"" to "\" не найдена в последнем слое."))
    )

    (T
     (setq new
       (list
         (cons 'from from)
         (cons 'to to)
       )
     )

     (setq lcm:maps
       (vl-remove-if
         (function
           (lambda (m)
             (= (cdr (assoc 'from m)) from)
           )
         )
         lcm:maps
       )
     )

     (setq lcm:maps
       (append
         lcm:maps
         (list new)
       )
     )

     (lcm:ui-fill-mappings)
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Update selected mapping
;;; ------------------------------------------------------------

(defun lcm:ui-update-map (/ idx from to)

  (setq idx
    (lcm:ui-get-list-index "mappings")
  )

  (if idx
    (progn

      (setq from (vl-string-trim " " (get_tile "map_from_edit")))
      (setq to (vl-string-trim " " (get_tile "map_to_edit")))

      (cond

        ((or (= from "") (= to ""))
         (alert "Введите имена точек или выберите их из списков.")
        )

        ((not (member from (lcm:ui-point-names-zero)))
         (alert (strcat "Точка \"" from "\" не найдена в нулевом слое."))
        )

        ((not (member to (lcm:ui-point-names-last)))
         (alert (strcat "Точка \"" to "\" не найдена в последнем слое."))
        )

        (T
         (setq lcm:maps
           (lcm:list-set-nth
             lcm:maps
             idx
             (list
               (cons 'from from)
               (cons 'to to)
             )
           )
         )

         (lcm:ui-fill-mappings)
        )
      )
    )
    (alert "Сначала выберите сопоставление в списке.")
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Remove selected mapping
;;; ------------------------------------------------------------

(defun lcm:ui-remove-map (/ idx)

  (setq idx
    (lcm:ui-get-list-index "mappings")
  )

  (if idx
    (progn
      (setq lcm:maps
        (lcm:list-remove-nth lcm:maps idx)
      )

      (lcm:ui-fill-mappings)
    )
    (alert "Сначала выберите сопоставление в списке.")
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Auto mapping
;;; ------------------------------------------------------------

(defun lcm:ui-auto-map (/ names-last to-name)

  (setq lcm:maps '())

  (setq names-last
    (lcm:ui-point-names-last)
  )

  (foreach item lcm:points-zero

    (if (member (car item) names-last)
      (setq to-name (car item))
      (setq to-name lcm:placeholder)
    )

    (setq lcm:maps
      (append
        lcm:maps
        (list
          (list
            (cons 'from (car item))
            (cons 'to to-name)
          )
        )
      )
    )
  )

  (lcm:ui-fill-mappings)

  (princ)
)


;;; ------------------------------------------------------------
;;; Clear all mappings
;;; ------------------------------------------------------------

(defun lcm:ui-clear-map ()
  (setq lcm:maps '())
  (lcm:ui-fill-mappings)
  (princ)
)


;;; ------------------------------------------------------------
;;; When user selects mapping in list, show it in combo boxes
;;; ------------------------------------------------------------

(defun lcm:ui-on-mapping-select (/ idx m from-names to-names)

  (setq idx
    (lcm:ui-get-list-index "mappings")
  )

  (if idx
    (progn
      (setq m (nth idx lcm:maps))

      (setq from-names
        (lcm:ui-point-names-zero)
      )

      (setq to-names
        (lcm:ui-point-names-last)
      )

      (set_tile "map_from_edit" (cdr (assoc 'from m)))
      (set_tile "map_to_edit" (cdr (assoc 'to m)))

      (lcm:ui-select-item
        "map_from"
        from-names
        (cdr (assoc 'from m))
      )

      (lcm:ui-select-item
        "map_to"
        to-names
        (cdr (assoc 'to m))
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; ByLayer toggle: enable/disable ACI fields
;;; ------------------------------------------------------------

(defun lcm:ui-update-by-layer (/ on)

  (setq on (= (get_tile "by_layer") "1"))

  (if on
    (progn
      (mode_tile "aci" 1)
      (mode_tile "pick_aci" 1)
    )
    (progn
      (mode_tile "aci" 0)
      (mode_tile "pick_aci" 0)
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Open native AutoCAD color dialog (with HSL palette)
;;; and put nearest ACI number into the field
;;; ------------------------------------------------------------

(defun lcm:ui-pick-aci (/ current new)

  (setq current (atoi (get_tile "aci")))

  (if (or (< current 1) (> current 255))
    (setq current 1)
  )

  (setq new
    (vl-catch-all-apply
      'acad_colordlg
      (list current)
    )
  )

  (if (and new (not (vl-catch-all-error-p new)))
    (set_tile "aci" (itoa new))
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Get valid mappings only
;;; ------------------------------------------------------------

(defun lcm:ui-valid-mappings (/ out from to)

  (setq out '())

  (foreach m lcm:maps

    (setq from (cdr (assoc 'from m)))
    (setq to (cdr (assoc 'to m)))

    (if (and
          from
          to
          (/= from "")
          (/= to "")
          (/= to lcm:placeholder)
        )
      (setq out (append out (list m)))
    )
  )

  out
)


;;; ------------------------------------------------------------
;;; Convert number to clean string
;;; ------------------------------------------------------------

(defun lcm:num->str (n)
  (if (= n (fix n))
    (itoa (fix n))
    (rtos n 2 3)
  )
)


;;; ------------------------------------------------------------
;;; Arrow deletion UI: update counter
;;; ------------------------------------------------------------

(defun lcm:ui-update-del-count (/ layer n)

  (setq layer
    (lcm:ui-get-popup-value "del_layer" lcm:layers)
  )

  (if layer
    (progn
      (setq n (length (lcm:find-arrows layer)))
      (set_tile "del_count" (strcat "Стрелок: " (itoa n)))
    )
    (set_tile "del_count" "Стрелок: -")
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Arrow deletion UI: delete all arrows on selected layer
;;; ------------------------------------------------------------

(defun lcm:ui-delete-arrows (/ layer n)

  (setq layer
    (lcm:ui-get-popup-value "del_layer" lcm:layers)
  )

  (if layer
    (progn
      (setq n (lcm:delete-arrows layer))

      (prompt
        (strcat
          "\nLCM: удалено стрелок на слое '"
          layer
          "': "
          (itoa n)
        )
      )

      (lcm:ui-update-del-count)
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Session state: keep dialog values between minimize/restore
;;; ------------------------------------------------------------

(defun lcm:ui-save-session ()
  (setq lcm:session-zero
    (lcm:ui-get-popup-value "layer_zero" lcm:layers)
  )

  (setq lcm:session-last
    (lcm:ui-get-popup-value "layer_last" lcm:layers)
  )

  (setq lcm:session-scale (get_tile "scale"))
  (setq lcm:session-text (get_tile "text_height"))
  (setq lcm:session-aci (get_tile "aci"))
  (setq lcm:session-bylayer (get_tile "by_layer"))
  (setq lcm:session-del
    (lcm:ui-get-popup-value "del_layer" lcm:layers)
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Restore session state to dialog tiles
;;; ------------------------------------------------------------

(defun lcm:ui-apply-session ()
  (lcm:ui-select-item "layer_zero" lcm:layers lcm:session-zero)
  (lcm:ui-select-item "layer_last" lcm:layers lcm:session-last)

  (set_tile "scale" lcm:session-scale)
  (set_tile "text_height" lcm:session-text)
  (set_tile "aci" lcm:session-aci)
  (set_tile "by_layer" lcm:session-bylayer)

  (lcm:ui-select-item "del_layer" lcm:layers lcm:session-del)

  (lcm:ui-update-by-layer)
  (lcm:ui-update-del-count)

  (princ)
)


;;; ------------------------------------------------------------
;;; Apply saved settings to dialog tiles
;;; ------------------------------------------------------------

(defun lcm:ui-apply-settings (/ by-layer)

  ;; Restore last layers
  (lcm:ui-select-item
    "layer_zero"
    lcm:layers
    (lcm:config-get "LAYER_ZERO")
  )

  (lcm:ui-select-item
    "layer_last"
    lcm:layers
    (lcm:config-get "LAYER_LAST")
  )

  ;; Restore parameters
  (set_tile "scale"
    (lcm:num->str (lcm:config-get "SCALE"))
  )

  (set_tile "text_height"
    (lcm:num->str (lcm:config-get "TEXT_HEIGHT"))
  )

  (set_tile "aci"
    (itoa (lcm:config-get "ACI"))
  )

  ;; Restore ByLayer toggle
  (setq by-layer (lcm:config-get "BY_LAYER"))

  (if (and by-layer (/= by-layer 0))
    (set_tile "by_layer" "1")
    (set_tile "by_layer" "0")
  )

  ;; Restore deletion layer
  (lcm:ui-select-item
    "del_layer"
    lcm:layers
    (lcm:config-get "DEL_LAYER")
  )

  (lcm:ui-update-by-layer)
  (lcm:ui-update-del-count)

  (princ)
)


;;; ------------------------------------------------------------
;;; Accept button validation
;;; ------------------------------------------------------------

(defun lcm:ui-accept
  (
    /
    layer-zero
    layer-last
    scale
    text-height
    by-layer
    color-mode
    color-data
    valid
  )

  (setq layer-zero
    (lcm:ui-get-popup-value "layer_zero" lcm:layers)
  )

  (setq layer-last
    (lcm:ui-get-popup-value "layer_last" lcm:layers)
  )

  (if (or (not layer-zero) (not layer-last))
    (progn
      (alert "Выберите оба слоя.")
      (exit)
    )
  )

  (setq scale (atof (get_tile "scale")))

  (if (or (not scale) (<= scale 0.0))
    (progn
      (alert "Масштаб должен быть положительным числом.")
      (exit)
    )
  )

  (setq text-height (atof (get_tile "text_height")))

  (if (or (not text-height) (<= text-height 0.0))
    (progn
      (alert "Высота текста должна быть положительным числом.")
      (exit)
    )
  )

  ;; Color mode: ByLayer toggle or ACI
  (setq by-layer (= (get_tile "by_layer") "1"))

  (if by-layer
    (progn
      (setq color-mode "BYLAYER")
      (setq color-data nil)
    )
    (progn
      (setq color-data (atoi (get_tile "aci")))

      (if (or (< color-data 1) (> color-data 255))
        (progn
          (alert "Цвет ACI должен быть в диапазоне от 1 до 255.")
          (exit)
        )
      )

      (setq color-mode "ACI")
    )
  )

  (setq valid (lcm:ui-valid-mappings))

  (if (= (length valid) 0)
    (progn
      (alert "Нет корректных сопоставлений.\nДобавьте сопоставления вручную или нажмите Авто-сопоставление.")
      (exit)
    )
  )

  ;; Save run parameters to global variables
  (setq lcm:run-layer-zero layer-zero)
  (setq lcm:run-layer-last layer-last)
  (setq lcm:run-scale scale)
  (setq lcm:run-color-mode color-mode)
  (setq lcm:run-color-data color-data)
  (setq lcm:run-text-height text-height)
  (setq lcm:run-mappings valid)

  ;; Save settings for next run
  (lcm:config-set "LAYER_ZERO" layer-zero)
  (lcm:config-set "LAYER_LAST" layer-last)
  (lcm:config-set "SCALE" scale)
  (lcm:config-set "TEXT_HEIGHT" text-height)
  (lcm:config-set "BY_LAYER" (if by-layer 1 0))

  (if (not by-layer)
    (lcm:config-set "ACI" color-data)
  )

  (lcm:config-set
    "DEL_LAYER"
    (lcm:ui-get-popup-value "del_layer" lcm:layers)
  )

  (lcm:config-save)

  (done_dialog 1)
)


;;; ------------------------------------------------------------
;;; Execute after dialog is closed
;;; ------------------------------------------------------------

(defun lcm:ui-execute ()

  (if (and
        lcm:run-layer-zero
        lcm:run-layer-last
        lcm:run-mappings
      )
    (lcm:run
      lcm:run-layer-zero
      lcm:run-layer-last
      lcm:run-mappings
      lcm:run-scale
      lcm:run-color-mode
      lcm:run-color-data
      lcm:run-text-height
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Main dialog entry point
;;; ------------------------------------------------------------

(defun lcm:show-main-dialog (/ dcl-id result)

  (setq dcl-id (load_dialog "lcm_ui.dcl"))

  (if (< dcl-id 0)
    (progn
      (alert "Не удалось загрузить lcm_ui.dcl.\nПроверьте, что папка проекта добавлена в Support File Search Path.")
      (exit)
    )
  )

  (if (not (new_dialog "lcm_main_dlg" dcl-id))
    (progn
      (unload_dialog dcl-id)
      (alert "Не удалось открыть диалог lcm_main_dlg.")
      (exit)
    )
  )

  ;; Load saved settings
  (lcm:config-load)

  ;; Fill interface
  (lcm:ui-fill-layers)
  (lcm:ui-fill-del-layer)

  ;; If dialog was minimized earlier, restore exact session state;
  ;; otherwise restore last saved settings
  (if lcm:session-zero
    (lcm:ui-apply-session)
    (lcm:ui-apply-settings)
  )

  (lcm:ui-refresh-points)

  ;; Actions
  (action_tile "layer_zero" "(lcm:ui-refresh-points)")
  (action_tile "layer_last" "(lcm:ui-refresh-points)")

  (action_tile "by_layer" "(lcm:ui-update-by-layer)")
  (action_tile "pick_aci" "(lcm:ui-pick-aci)")

  (action_tile "del_layer" "(lcm:ui-update-del-count)")
  (action_tile "delete_arrows" "(lcm:ui-delete-arrows)")

  (action_tile "map_from" "(lcm:ui-popup-sync \"map_from\" \"map_from_edit\" (lcm:ui-point-names-zero))")
  (action_tile "map_to" "(lcm:ui-popup-sync \"map_to\" \"map_to_edit\" (lcm:ui-point-names-last))")

  (action_tile "mappings" "(lcm:ui-on-mapping-select)")

  (action_tile "add_map" "(lcm:ui-add-map)")
  (action_tile "update_map" "(lcm:ui-update-map)")
  (action_tile "remove_map" "(lcm:ui-remove-map)")
  (action_tile "auto_map" "(lcm:ui-auto-map)")
  (action_tile "clear_map" "(lcm:ui-clear-map)")

  (action_tile "accept" "(progn (lcm:ui-save-session) (lcm:ui-accept))")
  (action_tile "minimize" "(progn (lcm:ui-save-session) (done_dialog 2))")
  (action_tile "cancel" "(progn (lcm:ui-save-session) (done_dialog 0))")

  (setq result (start_dialog))

  (unload_dialog dcl-id)

  (cond

    ;; Execute
    ((= result 1)
     (lcm:ui-execute)
    )

    ;; Minimize to drawing
    ((= result 2)
     (prompt "\nLCM: диалог свёрнут. Чертеж активен.")
     (prompt "\nLCM: вернитесь командой LCM или кнопкой на ленте.")
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Tell main module that UI is ready
;;; ------------------------------------------------------------

(setq lcm:ui-loaded T)

(princ)