;;; ------------------------------------------------------------
;;; lcm_table.lsp — ведомость отклонений Layer Cycle Manager
;;; Строит таблицу отклонений по парам точек двух циклов.
;;; Команда: LCMDEV.  Функция: (lcm:dev-table layer-a layer-b radius)
;;; Кодировка файла: Windows-1251 (AutoCAD читает .lsp как ANSI)
;;; ------------------------------------------------------------

(vl-load-com)

;;; ------------------------------------------------------------
;;; Значения по умолчанию
;;; ------------------------------------------------------------

(defun lcm:dev-text-height ( / h)
  (setq h (lcm:config-get "TEXT_HEIGHT"))
  (if (and h (> h 0)) h 2.5)
)

(defun lcm:dev-radius (r)
  (cond
    ((and r (> r 0)) r)
    ((and (boundp (quote lcm:geo-default-radius)) lcm:geo-default-radius)
     lcm:geo-default-radius)
    (T 5.0)
  )
)

;;; ------------------------------------------------------------
;;; Габариты набора точек (name x y)
;;; ------------------------------------------------------------

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

;;; ------------------------------------------------------------
;;; Поиск точки по имени
;;; ------------------------------------------------------------

(defun lcm:dev-find (name pts / found p)
  (foreach p pts
    (if (and (null found) (= (car p) name)) (setq found p))
  )
  found
)

;;; ------------------------------------------------------------
;;; Сортировка пар по имени точки нулевого цикла
;;; ------------------------------------------------------------

(defun lcm:dev-sort (pairs)
  (vl-sort pairs
    (function (lambda (a b) (lcm:name< (cadr a) (cadr b))))
  )
)

;;; ------------------------------------------------------------
;;; Отрисовка таблицы
;;; Возвращает (таблица точка-вставки)
;;; ------------------------------------------------------------

(defun lcm:dev-table-draw
  (layer-a layer-b pairs pts-a pts-b
   / acad doc ms th rh cw rows cols ins bb tbl i row p pa pb dx dy ds)

  (setq th (lcm:dev-text-height))
  (setq rh (* 2.2 th))
  (setq cw (* 9.0 th))
  (setq rows (+ 2 (length pairs)))
  (setq cols 6)

  (setq acad (vlax-get-acad-object))
  (setq doc  (vla-get-ActiveDocument acad))
  (setq ms   (vla-get-ModelSpace doc))

  ;; Вставка: справа от габаритов точек обоих слоёв
  (setq bb (lcm:dev-bbox (append pts-a pts-b)))
  (setq ins (list (+ (nth 2 bb) (* 6.0 th)) (nth 3 bb) 0.0))

  (lcm:ensure-layer "LCM_ВЕДОМОСТЬ")

  (setq tbl (vla-AddTable ms (lcm:pt3 ins) rows cols rh cw))
  (vla-put-Layer tbl "LCM_ВЕДОМОСТЬ")

  ;; Заголовок таблицы
  (vla-SetText tbl 0 0 (strcat "Ведомость отклонений: " layer-a " -> " layer-b))
  (vl-catch-all-apply 'vla-MergeCells (list tbl 0 0 0 (1- cols)))

  ;; Шапка
  (vla-SetText tbl 1 0 "№")
  (vla-SetText tbl 1 1 "Цикл 0")
  (vla-SetText tbl 1 2 "Цикл 1")
  (vla-SetText tbl 1 3 "dX, мм")
  (vla-SetText tbl 1 4 "dY, мм")
  (vla-SetText tbl 1 5 "dS, мм")

  ;; Данные
  (setq i 0)
  (foreach p pairs
    (setq row (+ 2 i))
    (setq pa (lcm:dev-find (cadr p) pts-a))
    (setq pb (lcm:dev-find (caddr p) pts-b))
    (if (and pa pb)
      (progn
        (setq dx (* 1000.0 (- (nth 1 pb) (nth 1 pa))))
        (setq dy (* 1000.0 (- (nth 2 pb) (nth 2 pa))))
        (setq ds (* 1000.0
                    (distance (list (nth 1 pa) (nth 2 pa))
                              (list (nth 1 pb) (nth 2 pb)))))
        (vla-SetText tbl row 0 (itoa (1+ i)))
        (vla-SetText tbl row 1 (cadr p))
        (vla-SetText tbl row 2 (caddr p))
        (vla-SetText tbl row 3 (rtos dx 2 1))
        (vla-SetText tbl row 4 (rtos dy 2 1))
        (vla-SetText tbl row 5 (rtos ds 2 1))
      )
    )
    (setq i (1+ i))
  )

  ;; Выравнивание и высота текста во всех строках, кроме заголовка
  (setq row 1)
  (while (< row rows)
    (setq i 0)
    (while (< i cols)
      (vl-catch-all-apply 'vla-SetCellAlignment (list tbl row i 5))
      (vl-catch-all-apply 'vla-SetCellTextHeight (list tbl row i th))
      (setq i (1+ i))
    )
    (setq row (1+ row))
  )

  (list tbl ins)
)

;;; ------------------------------------------------------------
;;; Основная функция
;;; Возвращает (число пар точка-вставки) или nil
;;; ------------------------------------------------------------

(defun lcm:dev-table
  (layer-a layer-b radius / r pts-a pts-b pairs res)

  (setq r (lcm:dev-radius radius))
  (setq pts-a (lcm:get-points-with-names layer-a))
  (setq pts-b (lcm:get-points-with-names layer-b))

  (cond
    ((null pts-a)
     (princ (strcat "\nLCM: на слое нет точек: " layer-a)) nil)
    ((null pts-b)
     (princ (strcat "\nLCM: на слое нет точек: " layer-b)) nil)
    (T
     (setq pairs (lcm:dev-sort (lcm:geo-radius-pairs pts-a pts-b r)))
     (if (null pairs)
       (progn
         (princ (strcat "\nLCM: в радиусе " (rtos r 2 1) " пар не найдено"))
         nil)
       (progn
         (setq res (lcm:dev-table-draw layer-a layer-b pairs pts-a pts-b))
         (list (length pairs) (cadr res))
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
        (princ (strcat "\nLCM: ведомость готова, пар: " (itoa (car res))))
        (princ "\nLCM: ведомость не построена")
      )
    )
    (princ "\nLCM: отменено")
  )
  (princ)
)

(princ "\nLCM: модуль ведомости отклонений загружен (LCMDEV)")
(princ)