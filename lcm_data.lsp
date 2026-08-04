;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_data.lsp
;;; Stage 3: drawing data functions
;;; ============================================================

(vl-load-com)

;;; ------------------------------------------------------------
;;; Default settings for data module
;;; ------------------------------------------------------------

(if (not lcm:text-search-radius)
  (setq lcm:text-search-radius 50.0)
)

(if (not lcm:unnamed-point-prefix)
  (setq lcm:unnamed-point-prefix "Point_")
)


;;; ------------------------------------------------------------
;;; Convert ActiveX coordinate value to simple (x y) list
;;; ------------------------------------------------------------

(defun lcm:coords->xy (value / tmp out)
  (cond

    ;; Already a normal list
    ((listp value)
     (setq out value)
    )

    ;; Try to convert from ActiveX variant / safearray
    (T
     (setq out
       (vl-catch-all-apply
         'vlax-safearray->list
         (list value)
       )
     )

     (if (vl-catch-all-error-p out)
       (progn
         (setq tmp
           (vl-catch-all-apply
             'vlax-variant-value
             (list value)
           )
         )

         (if (not (vl-catch-all-error-p tmp))
           (progn
             (setq out
               (vl-catch-all-apply
                 'vlax-safearray->list
                 (list tmp)
               )
             )

             (if (vl-catch-all-error-p out)
               (setq out nil)
             )
           )
         )
       )
     )
    )
  )

  (if (and out (listp out) (>= (length out) 2))
    (list
      (float (nth 0 out))
      (float (nth 1 out))
    )
    nil
  )
)


;;; ------------------------------------------------------------
;;; Get coordinates from object
;;; Tries Coordinates first, then InsertionPoint
;;; ------------------------------------------------------------

(defun lcm:get-object-coords (obj / value)
  (setq value
    (vl-catch-all-apply
      'vlax-get
      (list obj 'Coordinates)
    )
  )

  (if (vl-catch-all-error-p value)
    (setq value
      (vl-catch-all-apply
        'vlax-get
        (list obj 'InsertionPoint)
      )
    )
  )

  (if (not (vl-catch-all-error-p value))
    (lcm:coords->xy value)
    nil
  )
)


;;; ------------------------------------------------------------
;;; Get object handle safely
;;; ------------------------------------------------------------

(defun lcm:get-object-handle (obj / h)
  (setq h
    (vl-catch-all-apply
      'vla-get-Handle
      (list obj)
    )
  )

  (if (vl-catch-all-error-p h)
    "UNKNOWN"
    h
  )
)


;;; ------------------------------------------------------------
;;; Check if string is numeric
;;; Examples:
;;; "12"   -> T
;;; "12.5" -> T
;;; "-7"   -> T
;;; "12a"  -> nil
;;; ------------------------------------------------------------

(defun lcm:is-numeric (s / i code len ok digit dot)
  (setq len (strlen s))

  (if (= len 0)
    nil
    (progn
      (setq i 1)
      (setq ok T)
      (setq digit nil)
      (setq dot nil)

      (while (and ok (<= i len))
        (setq code (ascii (substr s i 1)))

        (cond

          ;; minus sign
          ((= code 45)
           (if (> i 1)
             (setq ok nil)
           )
          )

          ;; decimal point
          ((= code 46)
           (if dot
             (setq ok nil)
             (setq dot T)
           )
          )

          ;; digits 0-9
          ((and (>= code 48) (<= code 57))
           (setq digit T)
          )

          ;; invalid character
          (T
           (setq ok nil)
          )
        )

        (setq i (1+ i))
      )

      (and ok digit)
    )
  )
)


;;; ------------------------------------------------------------
;;; Compare two point names for sorting
;;; Numeric names first, then text names
;;; ------------------------------------------------------------

(defun lcm:name< (a b / na nb)
  (setq na (lcm:is-numeric a))
  (setq nb (lcm:is-numeric b))

  (cond
    ((and na nb)
     (< (atof a) (atof b))
    )

    (na T)

    (nb nil)

    (T
     (< (strcase a) (strcase b))
    )
  )
)


;;; ------------------------------------------------------------
;;; Sort point association list by point name
;;; Input:
;;; (("1" . (x y)) ("2" . (x y)) ...)
;;; ------------------------------------------------------------

(defun lcm:sort-points (points)
  (vl-sort points
    (function
      (lambda (a b)
        (lcm:name< (car a) (car b))
      )
    )
  )
)


;;; ------------------------------------------------------------
;;; Add point to association list
;;; If name already exists, replace it
;;; ------------------------------------------------------------

(defun lcm:add-or-replace-point (pairs name coord / filtered)
  (setq filtered
    (vl-remove-if
      (function
        (lambda (item)
          (= (car item) name)
        )
      )
      pairs
    )
  )

  (cons (cons name coord) filtered)
)


;;; ------------------------------------------------------------
;;; Get all layers in current drawing
;;; ------------------------------------------------------------

(defun lcm:get-layers (/ acad doc layers layer)
  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))
  (setq layers '())

  (vlax-for layer (vla-get-Layers doc)
    (setq layers
      (cons
        (vla-get-Name layer)
        layers
      )
    )
  )

  (vl-sort layers
    (function
      (lambda (a b)
        (< (strcase a) (strcase b))
      )
    )
  )
)


;;; ------------------------------------------------------------
;;; Main data function
;;; Returns sorted association list:
;;; (("1" . (x y)) ("2" . (x y)) ("Point_1A2" . (x y)))
;;; ------------------------------------------------------------

(defun lcm:get-points-with-names
  (
    layer-name
    /
    acad doc ms
    points texts
    obj layer obj-name
    pt handle txt ins
    best-text best-dist d
    name pairs
  )

  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))
  (setq ms (vla-get-ModelSpace doc))

  (setq points '())
  (setq texts '())

  ;; ------------------------------------------------------------
  ;; Collect points and texts from required layer
  ;; ------------------------------------------------------------

  (vlax-for obj ms

    (setq layer
      (vl-catch-all-apply
        'vla-get-Layer
        (list obj)
      )
    )

    (if (not (vl-catch-all-error-p layer))

      (if (= (strcase layer) (strcase layer-name))

        (progn

          (setq obj-name
            (vl-catch-all-apply
              'vla-get-ObjectName
              (list obj)
            )
          )

          (if (not (vl-catch-all-error-p obj-name))

            (cond

              ;; ------------------------------------------------------------
              ;; POINT
              ;; ------------------------------------------------------------

              ((= obj-name "AcDbPoint")

               (setq pt (lcm:get-object-coords obj))

               (if pt
                 (progn
                   (setq handle (lcm:get-object-handle obj))

                   (setq points
                     (cons
                       (list
                         (car pt)
                         (cadr pt)
                         handle
                       )
                       points
                     )
                   )
                 )
               )
              )

              ;; ------------------------------------------------------------
              ;; TEXT / MTEXT
              ;; ------------------------------------------------------------

              ((or (= obj-name "AcDbText")
                   (= obj-name "AcDbMText")
               )

               (setq txt
                 (vl-catch-all-apply
                   'vlax-get
                   (list obj 'TextString)
                 )
               )

               (if (not (vl-catch-all-error-p txt))
                 (progn
                   (setq txt (vl-string-trim " " txt))

                   (if (/= txt "")
                     (progn
                       (setq ins (lcm:get-object-coords obj))

                       (if ins
                         (setq texts
                           (cons
                             (list
                               txt
                               (car ins)
                               (cadr ins)
                             )
                             texts
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
      )
    )
  )


  ;; ------------------------------------------------------------
  ;; Match each point with nearest text
  ;; ------------------------------------------------------------

  (setq pairs '())

  (foreach p points

    (setq best-text nil)
    (setq best-dist lcm:text-search-radius)

    (foreach tx texts

      (setq d
        (distance
          (list
            (nth 0 p)
            (nth 1 p)
          )
          (list
            (nth 1 tx)
            (nth 2 tx)
          )
        )
      )

      (if (< d best-dist)
        (progn
          (setq best-dist d)
          (setq best-text (nth 0 tx))
        )
      )
    )

    (if best-text
      (setq name best-text)
      (setq name
        (strcat
          lcm:unnamed-point-prefix
          (nth 2 p)
        )
      )
    )

    (setq pairs
      (lcm:add-or-replace-point
        pairs
        name
        (list
          (nth 0 p)
          (nth 1 p)
        )
      )
    )
  )

  (lcm:sort-points pairs)
)


;;; ------------------------------------------------------------
;;; Get only point names from point list
;;; ------------------------------------------------------------

(defun lcm:get-point-names (points)
  (mapcar 'car points)
)


;;; ------------------------------------------------------------
;;; Automatic mappings
;;; For each point from zero layer use same name in last layer
;;; Only exact matches are included
;;; ------------------------------------------------------------

(defun lcm:auto-mappings (points-zero points-last / names-last mappings)

  (setq names-last
    (lcm:get-point-names points-last)
  )

  (setq mappings '())

  (foreach item points-zero

    (if (member (car item) names-last)

      (setq mappings
        (append
          mappings
          (list
            (list
              (cons 'from (car item))
              (cons 'to (car item))
            )
          )
        )
      )
    )
  )

  mappings
)


;;; ------------------------------------------------------------
;;; Test command: list layers
;;; ------------------------------------------------------------

(defun C:LCMLAYERS (/ layers)
  (setq layers (lcm:get-layers))

  (prompt
    (strcat
      "\nLCM: layers count: "
      (itoa (length layers))
    )
  )

  (foreach layer layers
    (prompt
      (strcat
        "\n"
        layer
      )
    )
  )

  (princ)
)


(princ)