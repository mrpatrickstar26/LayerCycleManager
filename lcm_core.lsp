;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_core.lsp
;;; Stage 3: arrow drawing core
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Degrees to radians
;;; ------------------------------------------------------------

(defun lcm:deg2rad (deg)
  (* deg (/ pi 180.0))
)


;;; ------------------------------------------------------------
;;; Convert 2D or 3D point to ActiveX 3D point
;;; ------------------------------------------------------------

(defun lcm:pt3 (pt)
  (vlax-3d-point
    (list
      (float (car pt))
      (float (cadr pt))
      0.0
    )
  )
)


;;; ------------------------------------------------------------
;;; Create layer if it does not exist
;;; ------------------------------------------------------------

(defun lcm:ensure-layer (layer-name / acad doc layers)
  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))

  (if (not (tblsearch "LAYER" layer-name))
    (progn
      (setq layers (vla-get-Layers doc))

      (vl-catch-all-apply
        'vla-Add
        (list layers layer-name)
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Set layer and color for object
;;; color-mode:
;;; "BYLAYER"
;;; "ACI"
;;; "RGB"
;;; ------------------------------------------------------------

(defun lcm:set-object-properties
  (
    obj
    layer-name
    color-mode
    color-data
    /
    mode tc
  )

  (if obj
    (progn

      (vl-catch-all-apply
        'vla-put-Layer
        (list obj layer-name)
      )

      (if (not color-mode)
        (setq color-mode "ACI")
      )

      (setq mode (strcase color-mode))

      (cond

        ;; ------------------------------------------------------------
        ;; ByLayer
        ;; ------------------------------------------------------------

        ((= mode "BYLAYER")
         (vl-catch-all-apply
           'vla-put-Color
           (list obj 256)
         )
        )


        ;; ------------------------------------------------------------
        ;; ACI color index
        ;; ------------------------------------------------------------

        ((= mode "ACI")

         (if (stringp color-data)
           (setq color-data (atoi color-data))
         )

         (if (or
               (not (numberp color-data))
               (< color-data 1)
               (> color-data 255)
             )
           (setq color-data 1)
         )

         (vl-catch-all-apply
           'vla-put-Color
           (list obj (fix color-data))
         )
        )


        ;; ------------------------------------------------------------
        ;; RGB TrueColor
        ;; ------------------------------------------------------------

        ((= mode "RGB")

         (if (and
               (listp color-data)
               (>= (length color-data) 3)
             )
           (progn
             (setq tc
               (vl-catch-all-apply
                 'vla-get-TrueColor
                 (list obj)
               )
             )

             (if (not (vl-catch-all-error-p tc))
               (progn
                 (vl-catch-all-apply
                   'vla-SetRGB
                   (list
                     tc
                     (car color-data)
                     (cadr color-data)
                     (caddr color-data)
                   )
                 )

                 (vl-catch-all-apply
                   'vla-put-TrueColor
                   (list obj tc)
                 )
               )
             )
           )
         )
        )
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Draw one arrow
;;; ------------------------------------------------------------
;;; start-point, end-point: (x y) or (x y z)
;;; layer-name: target layer
;;; color-mode: "BYLAYER", "ACI", "RGB"
;;; color-data: ACI integer or RGB list (r g b)
;;; text-height: text height
;;; scale: arrow length multiplier
;;; ------------------------------------------------------------

(defun lcm:draw-arrow
  (
    start-point
    end-point
    layer-name
    color-mode
    color-data
    text-height
    scale
    /
    acad doc ms
    dx dy length
    x3 y3 tip ang wing-len
    w1 w2
    line solid txt
    dist-mm
  )

  ;; Default values
  (if (not scale)
    (setq scale 1.0)
  )

  (if (not text-height)
    (setq text-height 2.5)
  )

  (if (not color-mode)
    (setq color-mode "ACI")
  )

  (if (not color-data)
    (setq color-data 1)
  )

  (if (or
        (not start-point)
        (not end-point)
        (<= scale 0.0)
        (<= text-height 0.0)
      )
    nil
    (progn

      (setq dx
        (- (car end-point) (car start-point))
      )

      (setq dy
        (- (cadr end-point) (cadr start-point))
      )

      (setq length
        (distance start-point end-point)
      )

      (if (zerop length)
        nil
        (progn

          (lcm:ensure-layer layer-name)

          ;; Arrow tip with scale
          (setq x3
            (+ (car start-point) (* dx scale))
          )

          (setq y3
            (+ (cadr start-point) (* dy scale))
          )

          (setq tip (list x3 y3))

          (setq ang
            (angle start-point tip)
          )

          ;; Arrow wing length = 0.2 * original length * scale
          (setq wing-len
            (* 0.2 length scale)
          )

          ;; Wing points
          (setq w1
            (polar
              tip
              (+ ang pi (- (lcm:deg2rad 10.0)))
              wing-len
            )
          )

          (setq w2
            (polar
              tip
              (+ ang pi (lcm:deg2rad 10.0))
              wing-len
            )
          )

          (setq acad (vlax-get-acad-object))
          (setq doc (vla-get-ActiveDocument acad))
          (setq ms (vla-get-ModelSpace doc))


          ;; ------------------------------------------------------------
          ;; Main line
          ;; ------------------------------------------------------------

          (setq line
            (vl-catch-all-apply
              'vla-AddLine
              (list
                ms
                (lcm:pt3 start-point)
                (lcm:pt3 tip)
              )
            )
          )

          (if (vl-catch-all-error-p line)
            (setq line nil)
          )


          ;; ------------------------------------------------------------
          ;; Solid arrow head
          ;; ------------------------------------------------------------

          (setq solid
            (vl-catch-all-apply
              'vla-AddSolid
              (list
                ms
                (lcm:pt3 tip)
                (lcm:pt3 w1)
                (lcm:pt3 w2)
                (lcm:pt3 w2)
              )
            )
          )

          (if (vl-catch-all-error-p solid)
            (setq solid nil)
          )


          ;; ------------------------------------------------------------
          ;; Distance text in millimeters
          ;; Drawing units are assumed to be meters
          ;; ------------------------------------------------------------

          (setq dist-mm
            (fix (+ (* length 1000.0) 0.5))
          )

          (setq txt
            (vl-catch-all-apply
              'vla-AddText
              (list
                ms
                (itoa dist-mm)
                (lcm:pt3 tip)
                (float text-height)
              )
            )
          )

          (if (vl-catch-all-error-p txt)
            (setq txt nil)
          )


          ;; ------------------------------------------------------------
          ;; Apply properties
          ;; ------------------------------------------------------------

          (foreach ent (list line solid txt)
            (if ent
              (lcm:set-object-properties
                ent
                layer-name
                color-mode
                color-data
              )
            )
          )

          line
        )
      )
    )
  )
)


;;; ------------------------------------------------------------
;;; Draw many arrows from mappings
;;; mappings format:
;;; (
;;;   ((from . "1") (to . "1"))
;;;   ((from . "2") (to . "5"))
;;; )
;;; ------------------------------------------------------------

(defun lcm:run
  (
    layer-zero
    layer-last
    mappings
    scale
    color-mode
    color-data
    text-height
    /
    acad doc
    points-zero points-last
    count errors
    from-name to-name
    start-pt end-pt
    result
  )

  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))

  (prompt "\nLCM: starting arrow drawing...")

  (setq points-zero
    (lcm:get-points-with-names layer-zero)
  )

  (setq points-last
    (lcm:get-points-with-names layer-last)
  )

  (prompt
    (strcat
      "\nLCM: points on layer '"
      layer-zero
      "': "
      (itoa (length points-zero))
    )
  )

  (prompt
    (strcat
      "\nLCM: points on layer '"
      layer-last
      "': "
      (itoa (length points-last))
    )
  )

  (if (= (length points-last) 0)
    (progn
      (prompt "\nLCM ERROR: no points on last layer.")
      nil
    )
    (progn

      (vla-StartUndoMark doc)

      (setq count 0)
      (setq errors 0)

      (foreach mapping mappings

        (setq from-name
          (cdr (assoc 'from mapping))
        )

        (setq to-name
          (cdr (assoc 'to mapping))
        )

        (setq start-pt
          (cdr (assoc from-name points-zero))
        )

        (setq end-pt
          (cdr (assoc to-name points-last))
        )

        (if (and start-pt end-pt)
          (progn

            (setq result
              (lcm:draw-arrow
                start-pt
                end-pt
                layer-last
                color-mode
                color-data
                text-height
                scale
              )
            )

            (if result
              (progn
                (setq count (1+ count))

                (prompt
                  (strcat
                    "\nLCM: arrow "
                    from-name
                    " -> "
                    to-name
                  )
                )
              )
              (progn
                (setq errors (1+ errors))

                (prompt
                  (strcat
                    "\nLCM ERROR: cannot draw arrow "
                    from-name
                    " -> "
                    to-name
                  )
                )
              )
            )
          )
          (progn
            (setq errors (1+ errors))

            (prompt
              (strcat
                "\nLCM ERROR: point not found for "
                from-name
                " -> "
                to-name
              )
            )
          )
        )
      )

      (vla-EndUndoMark doc)

      (prompt
        (strcat
          "\nLCM: finished. Arrows created: "
          (itoa count)
        )
      )

      (if (> errors 0)
        (prompt
          (strcat
            "\nLCM: errors: "
            (itoa errors)
          )
        )
      )

      T
    )
  )
)


;;; ------------------------------------------------------------
;;; Test command: list points from layer
;;; ------------------------------------------------------------

(defun C:LCMTESTDATA (/ layer-name pts)

  (setq layer-name
    (getstring T "\nLCM test: layer name to list points: ")
  )

  (if (/= layer-name "")
    (progn

      (setq pts
        (lcm:get-points-with-names layer-name)
      )

      (prompt
        (strcat
          "\nLCM: found "
          (itoa (length pts))
          " points on layer '"
          layer-name
          "'"
        )
      )

      (foreach item pts
        (prompt
          (strcat
            "\n"
            (car item)
            "  X="
            (rtos (cadr item) 2 3)
            "  Y="
            (rtos (caddr item) 2 3)
          )
        )
      )
    )
    (prompt "\nLCM: empty layer name.")
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Test command: draw one test arrow manually
;;; ------------------------------------------------------------

(defun C:LCMTESTDRAW (/ p1 p2 layer-name scale)

  (setq p1
    (getpoint "\nLCM test: start point: ")
  )

  (if p1
    (progn

      (setq p2
        (getpoint p1 "\nLCM test: end point: ")
      )

      (if p2
        (progn

          (setq layer-name
            (getstring T "\nLCM test: arrow layer <0>: ")
          )

          (if (= layer-name "")
            (setq layer-name "0")
          )

          (setq scale
            (getreal "\nLCM test: scale <5.0>: ")
          )

          (if (not scale)
            (setq scale 5.0)
          )

          (lcm:draw-arrow
            p1
            p2
            layer-name
            "ACI"
            1
            2.5
            scale
          )

          (prompt "\nLCM: test arrow created.")
        )
        (prompt "\nLCM: end point not selected.")
      )
    )
    (prompt "\nLCM: start point not selected.")
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Test command: automatic mapping and drawing
;;; ------------------------------------------------------------

(defun C:LCMTESTRUN
  (
    /
    layer-zero
    layer-last
    scale
    points-zero
    points-last
    mappings
  )

  (setq layer-zero
    (getstring T "\nLCM test: zero cycle layer: ")
  )

  (setq layer-last
    (getstring T "\nLCM test: last cycle layer: ")
  )

  (setq scale
    (getreal "\nLCM test: scale <5.0>: ")
  )

  (if (not scale)
    (setq scale 5.0)
  )

  (if (and
        (/= layer-zero "")
        (/= layer-last "")
      )
    (progn

      (setq points-zero
        (lcm:get-points-with-names layer-zero)
      )

      (setq points-last
        (lcm:get-points-with-names layer-last)
      )

      (setq mappings
        (lcm:auto-mappings
          points-zero
          points-last
        )
      )

      (prompt
        (strcat
          "\nLCM: auto mappings count: "
          (itoa (length mappings))
        )
      )

      (lcm:run
        layer-zero
        layer-last
        mappings
        scale
        "ACI"
        1
        2.5
      )
    )
    (prompt "\nLCM: layer names are required.")
  )

  (princ)
)


(princ)