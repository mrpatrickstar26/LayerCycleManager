;;; ------------------------------------------------------------
;;; lcm_table.lsp — ведомость отклонений Layer Cycle Manager
;;; Оформление повторяет таблицу из «Уч. 6 шпунт.xlsx».
;;; Отклонения определяются по НАРИСОВАННЫМ стрелкам: у какой точки
;;; слоя A начинается отрезок отклонения, та марка и попадает в таблицу.
;;; Команда: LCMDEV.  Функция: (lcm:dev-table layer-a layer-b radius)
;;; Кодировка файла: Windows-1251 (AutoCAD читает .lsp как ANSI)
;;; ------------------------------------------------------------

(vl-load-com)

;;; Высота текста таблицы и пропорции строк/столбцов
(defun lcm:dev-text-height () 5.0)
(defun lcm:dev-row-height () (* 1.2 (lcm:dev-text-height)))
(defun lcm:dev-col-width () (* 4.5 (lcm:dev-text-height)))

;;; Допуск примыкания отрезка к точке (единицы чертежа)
(defun lcm:dev-tolerance () 0.1)

(defun lcm:dev-radius (r)
  (cond
    ((and r (> r 0)) r)
    ((and (boundp (quote lcm:geo-default-radius)) lcm:geo-default-radius)
     lcm:geo-default-radius)
    (T 5.0)
  )
)

(defun lcm:dev-scale ( / s)
  (setq s (lcm:config-get "SCALE"))
  (if (and s (> s 0)) s 1.0)
)

;;; Габариты набора точек (name x y)
(defun lcm:dev-bbox (pts / xmin ymin xmax ymax p x y)
  (foreach p pts
    (setq x (nth 1 p) y (nth 2 p))
    (if (or (null xmin) (< x xmin)) (setq xmin x))
    (if (or (null ymin) (< y ymin)) (setq ymin y))
    (if (or (null xmax) (> x xmax)) (setq xmax x))
    (if (or (null ymax) (> y ymax)) (setq ymax y))
  )
  (if xmin (list xmin ymin xmax ymax))
)

(defun lcm:dev-find (name pts / found p)
  (foreach p pts (if (and (null found) (= (car p) name)) (setq found p)))
  found
)

(defun lcm:dev-sort-pts (pts)
  (vl-sort pts (function (lambda (a b) (lcm:name< (car a) (car b)))))
)

;;; Дата и подпись цикла
(defun lcm:dev-date ()
  (menucmd "M=$(edtime,$(getvar,date),DD.MO.YYYY)")
)

(defun lcm:dev-cycle-label (layer / pos)
  (setq pos (vl-string-search "Цикл" layer))
  (strcat (if pos (substr layer (1+ pos)) layer) " " (lcm:dev-date))
)

;;; ------------------------------------------------------------
;;; Отрезки и тексты на слое последнего цикла
;;; ------------------------------------------------------------

(defun lcm:dev-lines (layer / ss i e st en out)
  (setq ss (ssget "_X" (list (cons 0 "LINE") (cons 8 layer))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq e (entget (ssname ss i)))
        (setq st (cdr (assoc 10 e)) en (cdr (assoc 11 e)))
        (if (and st en) (setq out (cons (list st en) out)))
        (setq i (1+ i))
      )
    )
  )
  out
)

(defun lcm:dev-texts (layer / ss i e p txt out)
  (setq ss (ssget "_X" (list (cons 0 "TEXT,MTEXT") (cons 8 layer))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq e (entget (ssname ss i)))
        (setq p (cdr (assoc 10 e)) txt (cdr (assoc 1 e)))
        (if (and p txt) (setq out (cons (list p txt) out)))
        (setq i (1+ i))
      )
    )
  )
  out
)

;;; Длина отклонения в мм: берём текст у острия, иначе считаем по масштабу
(defun lcm:dev-arrow-length (tip texts / best bv d)
  (setq best 1.0e9 bv nil)
  (foreach tx texts
    (setq d (distance tip (car tx)))
    (if (< d best) (setq best d bv (cadr tx)))
  )
  (if (and bv (< best 0.5) (> (atof bv) 0.0)) (atof bv))
)

;;; ------------------------------------------------------------
;;; Отклонения по нарисованным стрелкам
;;; Возвращает список (имя dXмм dYмм Dмм)
;;; ------------------------------------------------------------

(defun lcm:dev-from-arrows (layer-a layer-b pts-a tol / lines texts out ln st en vx vy len d pa best bp bd dist)
  (setq lines (lcm:dev-lines layer-b))
  (setq texts (lcm:dev-texts layer-b))
  (foreach ln lines
    (setq st (car ln) en (cadr ln))
    (setq vx (- (car en) (car st)))
    (setq vy (- (cadr en) (cadr st)))
    (setq len (sqrt (+ (* vx vx) (* vy vy))))
    (if (> len 1.0e-9)
      (progn
        ;; Ближайшая точка слоя A к началу отрезка — и только она получает пару
        (setq best nil bp nil bd tol)
        (foreach pa pts-a
          (setq dist (distance (list (nth 1 pa) (nth 2 pa)) (list (car st) (cadr st))))
          (if (< dist bd) (setq bd dist bp pa))
        )
        (if bp
          (progn
            (setq d (lcm:dev-arrow-length en texts))
            (if (null d) (setq d (* 1000.0 (/ len (lcm:dev-scale)))))
            (setq out (cons (list (car bp)
                                  (* d (/ vx len))
                                  (* d (/ vy len))
                                  d) out))
          )
        )
      )
    )
  )
  out
)

;;; ------------------------------------------------------------
;;; Запасной путь: пары в радиусе (если стрелок в чертеже нет)
;;; ------------------------------------------------------------

(defun lcm:dev-from-radius (layer-b pts-a pts-b r / out item pa pb d dx dy)
  (foreach item (lcm:geo-radius-pairs pts-a pts-b r)
    (setq pa (lcm:dev-find (cadr item) pts-a))
    (setq pb (lcm:dev-find (caddr item) pts-b))
    (if (and pa pb)
      (progn
        (setq dx (* 1000.0 (- (nth 1 pb) (nth 1 pa))))
        (setq dy (* 1000.0 (- (nth 2 pb) (nth 2 pa))))
        (setq d (* 1000.0 (car item)))
        (setq out (cons (list (car pa) dx dy d) out))
      )
    )
  )
  out
)

;;; ------------------------------------------------------------
;;; Отрисовка таблицы
;;; ------------------------------------------------------------

(defun lcm:dev-table-draw
  (layer-b rows pts-a / acad doc ms th rh cw ins bb tbl i row p rec dx dy d)
  (setq th (lcm:dev-text-height))
  (setq rh (lcm:dev-row-height))
  (setq cw (lcm:dev-col-width))

  (setq pts-a (lcm:dev-sort-pts pts-a))
  (setq acad (vlax-get-acad-object))
  (setq doc  (vla-get-ActiveDocument acad))
  (setq ms   (vla-get-ModelSpace doc))

  (setq bb (lcm:dev-bbox pts-a))
  (setq ins (list (+ (nth 2 bb) (* 6.0 th)) (nth 3 bb) 0.0))

  (lcm:ensure-layer "LCM_ВЕДОМОСТЬ")
  (setq tbl (vla-AddTable ms (lcm:pt3 ins) (+ 3 (length pts-a)) 4 rh cw))
  (vla-put-Layer tbl "LCM_ВЕДОМОСТЬ")

  ;; Объединения — до заполнения текстом
  (vl-catch-all-apply 'vla-MergeCells (list tbl 1 0 2 1))
  (vl-catch-all-apply 'vla-MergeCells (list tbl 1 1 1 3))

  (vla-SetText tbl 0 0 "Смещение по x и y (мм)")
  (vla-SetText tbl 1 0 "№ марки")
  (vla-SetText tbl 1 1 (lcm:dev-cycle-label layer-b))
  (vla-SetText tbl 2 1 "\\U+03A3\\U+0394X")
  (vla-SetText tbl 2 2 "\\U+03A3\\U+0394Y")
  (vla-SetText tbl 2 3 "D")

  (setq i 0)
  (foreach p pts-a
    (setq row (+ 3 i))
    (setq rec (cdr (assoc (car p) rows)))
    (vla-SetText tbl row 0 (car p))
    (if rec
      (progn
        (vla-SetText tbl row 1 (rtos (car rec) 2 1))
        (vla-SetText tbl row 2 (rtos (cadr rec) 2 1))
        (vla-SetText tbl row 3 (rtos (caddr rec) 2 1))
      )
      (progn
        (vla-SetText tbl row 1 "-")
        (vla-SetText tbl row 2 "-")
        (vla-SetText tbl row 3 "-")
      )
    )
    (setq i (1+ i))
  )

  (setq row 0)
  (while (< row (+ 3 (length pts-a)))
    (setq i 0)
    (while (< i 4)
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl row i 5))
      (vl-catch-all-apply 'vla-SetCellTextHeight (list tbl row i th))
      (setq i (1+ i))
    )
    (setq row (1+ row))
  )

  (vl-catch-all-apply 'vla-SetRowHeight (list tbl 0 (* 2.2 th)))
  (vl-catch-all-apply 'vla-SetRowHeight (list tbl 1 (* 1.4 th)))
  (setq row 2)
  (while (< row (+ 3 (length pts-a)))
    (vl-catch-all-apply 'vla-SetRowHeight (list tbl row (* 1.4 th)))
    (setq row (1+ row))
  )
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl 0 (* 7.0 th)))

  (list tbl ins)
)

;;; ------------------------------------------------------------
;;; Основная функция: (число стрелок, число марок, точка вставки)
;;; ------------------------------------------------------------

(defun lcm:dev-table (layer-a layer-b radius / pts-a pts-b rows res)
  (setq pts-a (lcm:get-points-with-names layer-a))
  (setq pts-b (lcm:get-points-with-names layer-b))

  (cond
    ((null pts-a) (princ (strcat "\nLCM: на слое нет точек: " layer-a)) nil)
    (T
     ;; 1) отклонения по нарисованным стрелкам
     (setq rows (lcm:dev-from-arrows layer-a layer-b pts-a (lcm:dev-tolerance)))
     ;; 2) если стрелок нет — подбор в радиусе
     (if (null rows)
       (setq rows (lcm:dev-from-radius layer-b pts-a pts-b (lcm:dev-radius radius)))
     )
     (setq res (lcm:dev-table-draw layer-b rows pts-a))
     (list (length rows) (length pts-a) (cadr res))
    )
  )
)

;;; ------------------------------------------------------------
;;; Команда LCMDEV
;;; ------------------------------------------------------------

(defun c:LCMDEV ( / a b res)
  (setq a (lcm:config-get "LAYER_ZERO"))
  (setq b (lcm:config-get "LAYER_LAST"))
  (if (or (null a) (= a ""))
    (setq a (getstring T "\nLCM: слой нулевого цикла (Enter — отмена): ")))
  (if (and a (/= a ""))
    (if (or (null b) (= b ""))
      (setq b (getstring T "\nLCM: слой последнего цикла (Enter — отмена): "))))
  (if (and a (/= a "") b (/= b ""))
    (progn
      (setq res (lcm:dev-table a b nil))
      (if res
        (princ (strcat "\nLCM: ведомость готова, отклонений: " (itoa (car res))
                       ", марок: " (itoa (cadr res))))
        (princ "\nLCM: ведомость не построена"))
    )
    (princ "\nLCM: отменено"))
  (princ)
)

(princ "\nLCM: модуль ведомости отклонений загружен (LCMDEV)")
(princ)