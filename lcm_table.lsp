;;; ------------------------------------------------------------
;;; lcm_table.lsp — ведомость отклонений Layer Cycle Manager
;;; Оформление повторяет таблицу из «Уч. 6 шпунт.xlsx»:
;;;   № марки | ??X | ??Y | D
;;;   «Смещение по x и y (мм)» — объединённый заголовок,
;;;   под ним строка цикла.
;;; Команда: LCMDEV.  Функция: (lcm:dev-table layer-a layer-b radius)
;;; Кодировка файла: Windows-1251 (AutoCAD читает .lsp как ANSI)
;;; ------------------------------------------------------------

(vl-load-com)

;;; Высота текста таблицы и пропорции строк/столбцов
(defun lcm:dev-text-height () 5.0)
(defun lcm:dev-row-height () (* 1.2 (lcm:dev-text-height)))
(defun lcm:dev-col-width () (* 4.5 (lcm:dev-text-height)))

(defun lcm:dev-radius (r)
  (cond
    ((and r (> r 0)) r)
    ((and (boundp (quote lcm:geo-default-radius)) lcm:geo-default-radius)
     lcm:geo-default-radius)
    (T 5.0)
  )
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
  (foreach p pts
    (if (and (null found) (= (car p) name)) (setq found p))
  )
  found
)

(defun lcm:dev-sort (pairs)
  (vl-sort pairs
    (function (lambda (a b) (lcm:name< (cadr a) (cadr b))))
  )
)

(defun lcm:dev-sort-pts (pts)
  (vl-sort pts
    (function (lambda (a b) (lcm:name< (car a) (car b))))
  )
)

;;; Дата для строки цикла: ДД.ММ.ГГГГ
(defun lcm:dev-date ()
  (menucmd "M=$(edtime,$(getvar,date),DD.MO.YYYY)")
)

;;; Подпись цикла как в Excel: «Цикл 1 ДД.ММ.ГГГГ»
(defun lcm:dev-cycle-label (layer / pos)
  (setq pos (vl-string-search "Цикл" layer))
  (strcat (if pos (substr layer (1+ pos)) layer) " " (lcm:dev-date))
)
;;; ------------------------------------------------------------
;;; Пары берутся из последнего отчёта LCM — того, что записан после
;;; LCMCHAIN / LCMAUTO / LCMAUTODRAW / LCMGEOFILL. Это ровно те пары,
;;; которые LCM нарисовал (или отобрал для отрисовки).
;;; ------------------------------------------------------------

;;; ------------------------------------------------------------
;;; Пары, которые LCM запомнил при отрисовке (lcm:check-remember).
;;; Это ровно те стрелки, что нарисованы в чертеже, поэтому таблица
;;; и отрисовка всегда согласованы.
;;; Возвращает (расстояние имяA имяB).
;;; ------------------------------------------------------------

(defun lcm:dev-remembered (layer-a layer-b pts-a pts-b / out m na nb pa pb)
  (if (and (boundp (quote lcm:last-mappings)) lcm:last-mappings
           (boundp (quote lcm:last-layer-a)) lcm:last-layer-a
           (boundp (quote lcm:last-layer-b)) lcm:last-layer-b
           (= (strcase lcm:last-layer-a) (strcase layer-a))
           (= (strcase lcm:last-layer-b) (strcase layer-b)))
    (foreach m lcm:last-mappings
      (setq na (cdr (assoc (quote from) m)))
      (setq nb (cdr (assoc (quote to) m)))
      (setq pa (lcm:dev-find na pts-a))
      (setq pb (lcm:dev-find nb pts-b))
      (if (and pa pb)
        (setq out (cons (list (distance (list (nth 1 pa) (nth 2 pa))
                                        (list (nth 1 pb) (nth 2 pb)))
                              na nb)
                        out))
      )
    )
  )
  out
)
;;; ------------------------------------------------------------
;;; Отрисовка таблицы
;;; ------------------------------------------------------------

(defun lcm:dev-table-draw
  (layer-a layer-b pairs pts-a
   / acad doc ms th rh cw rows cols ins bb tbl i row p pa pb rec dx dy ds
     by-name)

  (setq th (lcm:dev-text-height))
  (setq rh (lcm:dev-row-height))
  (setq cw (lcm:dev-col-width))

  (setq pts-a (lcm:dev-sort-pts pts-a))
  (setq rows (+ 3 (length pts-a)))  ; 3 строки заголовка + данные
  (setq cols 4)

  (setq acad (vlax-get-acad-object))
  (setq doc  (vla-get-ActiveDocument acad))
  (setq ms   (vla-get-ModelSpace doc))

  (setq bb (lcm:dev-bbox pts-a))
  (setq ins (list (+ (nth 2 bb) (* 6.0 th)) (nth 3 bb) 0.0))

  (lcm:ensure-layer "LCM_ВЕДОМОСТЬ")

  (setq tbl (vla-AddTable ms (lcm:pt3 ins) rows cols rh cw))
  (vla-put-Layer tbl "LCM_ВЕДОМОСТЬ")

  ;; Строка 0 — штатный заголовок таблицы (занимает всю ширину и выводит текст).
  ;; Строки 1–2 — шапка: «№ марки» | «Цикл …» | ??X ??Y D.
  (vl-catch-all-apply 'vla-MergeCells (list tbl 1 0 2 1))
  (vl-catch-all-apply 'vla-MergeCells (list tbl 1 1 1 3))

  (vla-SetText tbl 0 0 "Смещение по x и y (мм)")
  (vla-SetText tbl 1 0 "№ марки")
  (vla-SetText tbl 1 1 (lcm:dev-cycle-label layer-b))
  (vla-SetText tbl 2 1 "\\U+03A3\\U+0394X")
  (vla-SetText tbl 2 2 "\\U+03A3\\U+0394Y")
  (vla-SetText tbl 2 3 "D")

  ;; Высоты строк: заголовок выше, остальные компактные
  (vl-catch-all-apply 'vla-SetRowHeight (list tbl 0 (* 2.2 th)))
  (vl-catch-all-apply 'vla-SetRowHeight (list tbl 1 (* 1.4 th)))

  ;; Карта пар: имя точки нулевого цикла -> (d имяB)
  (setq by-name (list))
  (foreach p pairs (setq by-name (cons (cons (cadr p) (list (car p) (caddr p))) by-name)))

  ;; Данные: все марки нулевого цикла, у кого нет пары — прочерк
  (setq i 0)
  (foreach pa pts-a
    (setq row (+ 3 i))
    (setq rec (cdr (assoc (car pa) by-name)))
    (vla-SetText tbl row 0 (car pa))
    (if rec
      (progn
        (setq pb (lcm:dev-find (cadr rec) (lcm:get-points-with-names layer-b)))
        (if pb
          (progn
            (setq dx (* 1000.0 (- (nth 1 pb) (nth 1 pa))))
            (setq dy (* 1000.0 (- (nth 2 pb) (nth 2 pa))))
            (setq ds (* 1000.0 (distance (list (nth 1 pa) (nth 2 pa))
                                         (list (nth 1 pb) (nth 2 pb)))))
            (vla-SetText tbl row 1 (rtos dx 2 1))
            (vla-SetText tbl row 2 (rtos dy 2 1))
            (vla-SetText tbl row 3 (rtos ds 2 1))
          )
          (progn
            (vla-SetText tbl row 1 "-")
            (vla-SetText tbl row 2 "-")
            (vla-SetText tbl row 3 "-")
          )
        )
      )
      (progn
        (vla-SetText tbl row 1 "-")
        (vla-SetText tbl row 2 "-")
        (vla-SetText tbl row 3 "-")
      )
    )
    (setq i (1+ i))
  )

  ;; Выравнивание и высота текста во всех ячейках
  (setq row 0)
  (while (< row rows)
    (setq i 0)
    (while (< i cols)
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl row i 5))
      (vl-catch-all-apply 'vla-SetCellTextHeight (list tbl row i th))
      (setq i (1+ i))
    )
    (setq row (1+ row))
  )

  ;; Остальные строки — компактные
  (setq row 2)
  (while (< row rows)
    (vl-catch-all-apply 'vla-SetRowHeight (list tbl row (* 1.4 th)))
    (setq row (1+ row))
  )

  ;; Первый столбец поуже
  (vl-catch-all-apply 'vla-SetColumnWidth (list tbl 0 (* 7.0 th)))

  (list tbl ins)
)

;;; ------------------------------------------------------------
;;; Основная функция
;;; ------------------------------------------------------------

(defun lcm:dev-table (layer-a layer-b radius / r pts-a pts-b pairs res)
  (setq r (lcm:dev-radius radius))
  (setq pts-a (lcm:get-points-with-names layer-a))
  (setq pts-b (lcm:get-points-with-names layer-b))

  (cond
    ((null pts-a) (princ (strcat "\nLCM: на слое нет точек: " layer-a)) nil)
    ((null pts-b) (princ (strcat "\nLCM: на слое нет точек: " layer-b)) nil)
    (T
     ;; Пары, запомненные LCM при отрисовке стрелок,
     ;; запасной вариант — ближайшая точка в радиусе
     (setq pairs (lcm:dev-remembered layer-a layer-b pts-a pts-b))
     (if (null pairs) (setq pairs (lcm:geo-radius-pairs pts-a pts-b r)))
     (setq pairs (lcm:dev-sort pairs))
     (if (null pairs)
       (progn (princ (strcat "\nLCM: в радиусе " (rtos r 2 1) " пар не найдено")) nil)
       (progn
         (setq res (lcm:dev-table-draw layer-a layer-b pairs pts-a))
         (list (length pairs) (length pts-a) (cadr res))
       )
     )
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
    (setq a (getstring T "\nLCM: слой нулевого цикла (Enter — отмена): "))
  )
  (if (and a (/= a ""))
    (if (or (null b) (= b ""))
      (setq b (getstring T "\nLCM: слой последнего цикла (Enter — отмена): "))
    )
  )

  (if (and a (/= a "") b (/= b ""))
    (progn
      (setq res (lcm:dev-table a b nil))
      (if res
        (princ (strcat "\nLCM: ведомость готова, пар: " (itoa (car res))
                       ", марок: " (itoa (cadr res))))
        (princ "\nLCM: ведомость не построена")
      )
    )
    (princ "\nLCM: отменено")
  )
  (princ)
)

(princ "\nLCM: модуль ведомости отклонений загружен (LCMDEV)")
(princ)