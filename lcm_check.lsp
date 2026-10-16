;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_check.lsp
;;; Этап 3: проверки сопоставления и построенных стрелок
;;; ============================================================
;;;
;;; Что проверяется:
;;;   1) сколько стрелок реально лежит на слое;
;;;   2) каждая пара сопоставления: есть ли на слое стрелка с такой
;;;      длиной (текст в миллиметрах) в ожидаемом месте;
;;;   3) пересечение истинных отрезков отклонений - пара, при которой
;;;      отрезки перекрещиваются, почти всегда ошибка сопоставления;
;;;   4) отчёт CSV со всеми результатами.
;;;
;;; Важно: пересечения проверяются по истинным отрезкам (точка - точка),
;;; а не по нарисованным стрелкам: при масштабе больше 1 линии стрелок
;;; растянуты и пересекаются "на глаз" даже при верном сопоставлении.
;;;
;;; Требуется: lcm_diag.lsp, lcm_geo.lsp, lcm_core.lsp.
;;;
;;; Команды:
;;;   LCMCHECK - проверить последнюю отрисовку
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Запомнить последнюю отрисовку (вызывается из lcm_geo / lcm_chain)
;;; ------------------------------------------------------------

(defun lcm:check-remember (layer-a layer-b mappings scale)
  (setq lcm:last-layer-a layer-a)
  (setq lcm:last-layer-b layer-b)
  (setq lcm:last-mappings mappings)
  (setq lcm:last-scale scale)
  (princ)
)


;;; ------------------------------------------------------------
;;; Геометрия: ориентация точки относительно отрезка
;;; ------------------------------------------------------------

(defun lcm:check-orient (p q r)
  (- (* (- (car q) (car p)) (- (cadr r) (cadr p)))
     (* (- (cadr q) (cadr p)) (- (car r) (car p))))
)


;;; Пересечение двух отрезков (без учёта касаний и коллинеарных случаев).
(defun lcm:check-cross (p1 q1 p2 q2 / o1 o2 o3 o4)
  (setq o1 (lcm:check-orient p1 q1 p2))
  (setq o2 (lcm:check-orient p1 q1 q2))
  (setq o3 (lcm:check-orient p2 q2 p1))
  (setq o4 (lcm:check-orient p2 q2 q1))

  (and (< (* o1 o2) 0.0)
       (< (* o3 o4) 0.0))
)


;;; ------------------------------------------------------------
;;; Тексты слоя: список (значение x y handle)
;;; ------------------------------------------------------------

(defun lcm:check-texts (layer / acad doc ms obj obj-layer obj-name txt ins out)
  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))
  (setq ms (vla-get-ModelSpace doc))
  (setq out '())

  (vlax-for obj ms
    (setq obj-layer
      (vl-catch-all-apply 'vla-get-Layer (list obj)))

    (if (and (not (vl-catch-all-error-p obj-layer))
             (= (strcase obj-layer) (strcase layer)))
      (progn
        (setq obj-name
          (vl-catch-all-apply 'vla-get-ObjectName (list obj)))
        (if (and (not (vl-catch-all-error-p obj-name))
                 (or (= obj-name "AcDbText") (= obj-name "AcDbMText")))
          (progn
            (setq txt (vl-catch-all-apply 'vlax-get (list obj 'TextString)))
            (setq ins (lcm:diag-coords obj))
            (if (and (not (vl-catch-all-error-p txt)) ins)
              (setq out
                (cons (list txt (car ins) (cadr ins) (lcm:diag-handle obj)) out))
            )
          )
        )
      )
    )
  )

  (reverse out)
)


;;; ------------------------------------------------------------
;;; Проверка длин: для каждой пары ищем стрелку в ожидаемом месте
;;; Запись: (from to расстояние ожидаемая_длина найденная_длина статус)
;;; ------------------------------------------------------------

(defun lcm:check-lengths
  (layer-a layer-b mappings scale / pts-a pts-b texts out m from to pa pb d expect
   tipx tipy found status)
  (setq pts-a (lcm:geo-points (nth 2 (lcm:diag-scan-layer layer-a))))
  (setq pts-b (lcm:geo-points (nth 2 (lcm:diag-scan-layer layer-b))))
  (setq texts (lcm:check-texts layer-b))
  (setq out '())

  (foreach m mappings
    (setq from (cdr (assoc 'from m)))
    (setq to (cdr (assoc 'to m)))
    (setq pa (lcm:geo-find from pts-a))
    (setq pb (lcm:geo-find to pts-b))

    (if (and pa pb)
      (progn
        (setq d
          (distance
            (list (nth 1 pa) (nth 2 pa))
            (list (nth 1 pb) (nth 2 pb))))

        (setq expect (fix (+ (* d 1000.0) 0.5 1e-8)))
        (setq tipx (+ (nth 1 pa) (* (- (nth 1 pb) (nth 1 pa)) scale)))
        (setq tipy (+ (nth 2 pa) (* (- (nth 2 pb) (nth 2 pa)) scale)))

        (setq found nil)
        (foreach tx texts
          (if (and (not found)
                   (< (distance (list tipx tipy) (list (nth 1 tx) (nth 2 tx))) 0.01))
            (setq found tx)
          )
        )

        (setq status
          (cond
            ((null found) "стрелка не найдена")
            ((= (atoi (nth 0 found)) expect) "ок")
            (T (strcat "длина не совпала: " (nth 0 found)
                       " вместо " (itoa expect)))
          )
        )

        (setq out
          (append out
            (list (list from to d expect
                        (if found (nth 0 found) "")
                        status))))
      )
      (setq out
        (append out (list (list from to nil nil "" "точка не найдена"))))
    )
  )

  out
)


;;; ------------------------------------------------------------
;;; Проверка пересечений истинных отрезков отклонений
;;; Возвращает список пар имён, отрезки которых перекрещиваются
;;; ------------------------------------------------------------

(defun lcm:check-crossings
  (layer-a layer-b mappings / pts-a pts-b out n i j mi mj a1 a2 b1 b2)
  (setq pts-a (lcm:geo-points (nth 2 (lcm:diag-scan-layer layer-a))))
  (setq pts-b (lcm:geo-points (nth 2 (lcm:diag-scan-layer layer-b))))
  (setq out '())
  (setq n (length mappings))
  (setq i 0)

  (while (< i n)
    (setq j (1+ i))
    (while (< j n)

      (setq mi (nth i mappings))
      (setq mj (nth j mappings))
      (setq a1 (lcm:geo-find (cdr (assoc 'from mi)) pts-a))
      (setq a2 (lcm:geo-find (cdr (assoc 'to mi)) pts-b))
      (setq b1 (lcm:geo-find (cdr (assoc 'from mj)) pts-a))
      (setq b2 (lcm:geo-find (cdr (assoc 'to mj)) pts-b))

      (if (and a1 a2 b1 b2
               (lcm:check-cross
                 (list (nth 1 a1) (nth 2 a1))
                 (list (nth 1 a2) (nth 2 a2))
                 (list (nth 1 b1) (nth 2 b1))
                 (list (nth 1 b2) (nth 2 b2))))
        (setq out
          (append out
            (list (list (cdr (assoc 'from mi)) (cdr (assoc 'from mj))))))
      )

      (setq j (1+ j))
    )
    (setq i (1+ i))
  )

  out
)


;;; ------------------------------------------------------------
;;; Отчёт проверки
;;; ------------------------------------------------------------

(defun lcm:check-report
  (layer-a layer-b mappings arrows lengths crossings / reports path fp item)
  (setq reports (lcm:diag-reports-folder))
  (setq path
    (strcat reports "\\lcm_check_"
            (lcm:diag-safe-name layer-a) "__"
            (lcm:diag-safe-name layer-b) "_"
            (lcm:diag-timestamp) ".csv"))

  (setq fp (open path "w"))

  (if (not fp)
    (progn
      (prompt (strcat "\nLCM ERROR: не удалось создать файл: " path))
      nil
    )
    (progn
      (write-line "# Layer Cycle Manager - проверка отрисовки" fp)
      (write-line (strcat "# Чертеж: " (getvar "DWGNAME")) fp)
      (write-line (strcat "# Слой A: " layer-a) fp)
      (write-line (strcat "# Слой B: " layer-b) fp)
      (write-line (strcat "# Пар: " (itoa (length mappings))
                          " | стрелок на слое B: "
                          (if arrows (itoa arrows) "н/д")
                          " | пересечений: " (itoa (length crossings))) fp)
      (write-line "" fp)
      (write-line "# ПРОВЕРКА ДЛИН" fp)
      (write-line "# from;to;dist;expected_mm;found_text;status" fp)

      (foreach item lengths
        (write-line
          (strcat (lcm:diag-csv-field (nth 0 item)) ";"
                  (lcm:diag-csv-field (nth 1 item)) ";"
                  (if (nth 2 item) (lcm:diag-num (nth 2 item) 6) "") ";"
                  (if (nth 3 item) (itoa (nth 3 item)) "") ";"
                  (lcm:diag-csv-field (nth 4 item)) ";"
                  (lcm:diag-csv-field (nth 5 item)))
          fp)
      )

      (write-line "" fp)
      (write-line "# ПЕРЕСЕЧЕНИЯ ОТРЕЗКОВ (пары имён в слое A)" fp)
      (foreach item crossings
        (write-line
          (strcat (lcm:diag-csv-field (nth 0 item)) ";"
                  (lcm:diag-csv-field (nth 1 item)))
          fp)
      )

      (close fp)
      path
    )
  )
)


;;; ------------------------------------------------------------
;;; Полная проверка
;;; Возвращает сводку: (пар стрелок ок ошибок пересечений отчёт)
;;; ------------------------------------------------------------

(defun lcm:check-run
  (layer-a layer-b mappings scale / arrows lengths crossings ok bad item report)
  (setq arrows
    (if lcm:find-arrows (length (lcm:find-arrows layer-b)) nil))

  (prompt (strcat "\nLCM: проверка пар: " (itoa (length mappings))
                  (if arrows
                    (strcat ", стрелок на слое '" layer-b "': " (itoa arrows))
                    "")))

  (setq lengths (lcm:check-lengths layer-a layer-b mappings scale))
  (setq crossings (lcm:check-crossings layer-a layer-b mappings))

  (setq ok 0)
  (setq bad 0)
  (foreach item lengths
    (if (= (nth 5 item) "ок")
      (setq ok (1+ ok))
      (setq bad (1+ bad))
    )
  )

  (prompt (strcat "\nLCM: длины совпали: " (itoa ok)
                  " | расхождений: " (itoa bad)))
  (prompt (strcat "\nLCM: пересечений отрезков отклонений: "
                  (itoa (length crossings))))

  (if (> (length crossings) 0)
    (progn
      (prompt "\nLCM: ВНИМАНИЕ, пересекающиеся пары (проверьте сопоставление):")
      (setq ok 0)
      (foreach item crossings
        (if (< ok 10)
          (prompt (strcat "\n  " (nth 0 item) " и " (nth 1 item)))
        )
        (setq ok (1+ ok))
      )
    )
  )

  (foreach item lengths
    (if (/= (nth 5 item) "ок")
      (prompt (strcat "\n  " (nth 0 item) " -> " (nth 1 item)
                      ": " (nth 5 item)))
    )
  )

  (setq report (lcm:check-report layer-a layer-b mappings arrows lengths crossings))

  (if report
    (prompt (strcat "\nLCM: отчёт проверки: " report))
  )

  (list (length mappings) arrows ok bad (length crossings) report)
)


;;; ------------------------------------------------------------
;;; Команда LCMCHECK
;;; ------------------------------------------------------------

(defun C:LCMCHECK
  ( / layer-a layer-b mappings scale match result)
  (setq layer-a lcm:last-layer-a)
  (setq layer-b lcm:last-layer-b)
  (setq mappings lcm:last-mappings)
  (setq scale lcm:last-scale)

  (if (or (null layer-a) (null layer-b) (null mappings))

    ;; данных о последней отрисовке нет - спрашиваем слои и сопоставляем
    (progn
      (prompt "\nLCM: данных о последней отрисовке нет, потребуется сопоставление.")
      (setq layer-a (getstring T "\nLCM: слой A (нулевой цикл): "))
      (setq layer-b (getstring T "\nLCM: слой B (последний цикл): "))
      (if (and (/= layer-a "") (/= layer-b ""))
        (progn
          (setq match (lcm:geo-match layer-a layer-b nil))
          (setq mappings (nth 0 match))
          (setq scale (lcm:geo-setting "SCALE" 1.0))
          (setq result (lcm:check-run layer-a layer-b mappings scale))
        )
      )
    )

    (progn
      (if (or (null scale) (<= scale 0.0))
        (setq scale (lcm:geo-setting "SCALE" 1.0))
      )
      (setq result (lcm:check-run layer-a layer-b mappings scale))
    )
  )

  (if result
    (prompt (strcat "\nLCM: проверено пар: " (itoa (nth 0 result))
                    ", ошибок: " (itoa (nth 3 result))))
  )

  (princ)
)


(princ "\n=== LCM Check loaded: LCMCHECK ===")
(princ)
