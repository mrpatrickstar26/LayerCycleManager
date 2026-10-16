;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_diag.lsp
;;; Этап 0: диагностика точек, подписей и расстояний между слоями
;;; ============================================================
;;;
;;; Модуль ТОЛЬКО ЧИТАЕТ чертёж: ничего не создаёт, не изменяет
;;; и не удаляет. Нужен для сбора данных перед доработкой
;;; сопоставления точек по координатам.
;;;
;;; Модуль самодостаточен: его можно загрузить отдельно командой
;;; APPLOAD, не загружая остальные файлы программы.
;;;
;;; Команды:
;;;   LCMSTATS    - статистика по одному слою
;;;   LCMDUMP     - выгрузка точек одного или нескольких слоёв в CSV
;;;   LCMDIAGPAIR - сравнение двух слоёв: совпадения по именам и пробелы
;;;
;;; Отчёты пишутся в папку reports рядом с файлом lcm_diag.lsp
;;; в кодировке Windows-1251 (кириллица), разделитель полей ";",
;;; десятичный разделитель - запятая (удобно для Excel).
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Параметры и защита от отсутствующих определений
;;; ------------------------------------------------------------

(if (not lcm:text-search-radius)
  (setq lcm:text-search-radius 50.0)
)

(if (not lcm:unnamed-point-prefix)
  (setq lcm:unnamed-point-prefix "Point_")
)

;;; Подпись считается подозрительной, если она дальше этого
;;; расстояния от точки (в единицах чертежа).
(if (not lcm:diag-label-warn)
  (setq lcm:diag-label-warn 1.0)
)

;;; Сколько строк печатать в отчётах.
(if (not lcm:diag-print-limit)
  (setq lcm:diag-print-limit 10)
)


;;; ------------------------------------------------------------
;;; Преобразование координат ActiveX в простое (x y)
;;; ------------------------------------------------------------

(defun lcm:diag-any->xy (value / out tmp)
  (cond

    ((listp value)
     (setq out value)
    )

    (T
     (setq out
       (vl-catch-all-apply 'vlax-safearray->list (list value))
     )

     (if (vl-catch-all-error-p out)
       (progn
         (setq tmp
           (vl-catch-all-apply 'vlax-variant-value (list value))
         )

         (if (not (vl-catch-all-error-p tmp))
           (progn
             (setq out
               (vl-catch-all-apply 'vlax-safearray->list (list tmp))
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
    (list (float (nth 0 out)) (float (nth 1 out)))
    nil
  )
)


;;; ------------------------------------------------------------
;;; Координаты объекта: сначала Coordinates, затем InsertionPoint
;;; ------------------------------------------------------------

(defun lcm:diag-coords (obj / value)
  (setq value
    (vl-catch-all-apply 'vlax-get (list obj 'Coordinates))
  )

  (if (vl-catch-all-error-p value)
    (setq value
      (vl-catch-all-apply 'vlax-get (list obj 'InsertionPoint))
    )
  )

  (if (not (vl-catch-all-error-p value))
    (lcm:diag-any->xy value)
    nil
  )
)


;;; ------------------------------------------------------------
;;; Handle объекта
;;; ------------------------------------------------------------

(defun lcm:diag-handle (obj / h)
  (setq h
    (vl-catch-all-apply 'vla-get-Handle (list obj))
  )

  (if (vl-catch-all-error-p h)
    "UNKNOWN"
    h
  )
)


;;; ------------------------------------------------------------
;;; Папка программы: ищем по собственному файлу модуля,
;;; чтобы отчёты попадали именно в загруженную копию.
;;; ------------------------------------------------------------

(defun lcm:diag-folder ( / path)
  (setq path (findfile "lcm_diag.lsp"))

  (if (not path)
    (setq path (findfile "lcm_main.lsp"))
  )

  (if path
    (vl-filename-directory path)
    (getvar "DWGPREFIX")
  )
)


;;; ------------------------------------------------------------
;;; Число в строку: десятичный разделитель - запятая
;;; ------------------------------------------------------------

(defun lcm:diag-num (value digits)
  (vl-string-subst "," "." (rtos (float value) 2 digits))
)


;;; ------------------------------------------------------------
;;; Поле CSV: разделитель полей - точка с запятой
;;; ------------------------------------------------------------

(defun lcm:diag-csv-field (value / text)
  (setq text (if (eq (type value) 'STR) value (vl-princ-to-string value)))
  ;; точка с запятой, перевод строки и возврат каретки внутри
  ;; значения сломали бы CSV - заменяем их на запятые
  (vl-string-translate (strcat ";" (chr 13) (chr 10)) ",,," text)
)


;;; ------------------------------------------------------------
;;; Сканирование слоя
;;; Возвращает список из трёх элементов:
;;;   (количество точек, количество текстов, записи)
;;; Запись: (handle x y имя расстояние_до_подписи handle_подписи)
;;; ------------------------------------------------------------

(defun lcm:diag-scan-layer
  (
    layer-name
    /
    acad doc ms obj layer obj-name
    points texts pt handle txt ins
    best-label best-dist best-handle d
    records
  )

  (setq acad (vlax-get-acad-object))
  (setq doc (vla-get-ActiveDocument acad))
  (setq ms (vla-get-ModelSpace doc))

  (setq points '())
  (setq texts '())

  (vlax-for obj ms

    (setq layer
      (vl-catch-all-apply 'vla-get-Layer (list obj))
    )

    (if (and
          (not (vl-catch-all-error-p layer))
          (= (strcase layer) (strcase layer-name))
        )
      (progn
        (setq obj-name
          (vl-catch-all-apply 'vla-get-ObjectName (list obj))
        )

        (cond

          ;; --- точка ---
          ((and
             (not (vl-catch-all-error-p obj-name))
             (= obj-name "AcDbPoint")
           )
           (setq pt (lcm:diag-coords obj))
           (if pt
             (progn
               (setq handle (lcm:diag-handle obj))
               (setq points
                 (cons (list handle (car pt) (cadr pt)) points)
               )
             )
           )
          )

          ;; --- текст или мтекст ---
          ((and
             (not (vl-catch-all-error-p obj-name))
             (or (= obj-name "AcDbText") (= obj-name "AcDbMText"))
           )
           (setq txt
             (vl-catch-all-apply 'vlax-get (list obj 'TextString))
           )
           (if (not (vl-catch-all-error-p txt))
             (progn
               (setq txt (vl-string-trim " " txt))
               (if (/= txt "")
                 (progn
                   (setq ins (lcm:diag-coords obj))
                   (if ins
                     (setq texts
                       (cons
                         (list txt (car ins) (cadr ins) (lcm:diag-handle obj))
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

  ;; --- подбор ближайшей подписи для каждой точки ---
  (setq records '())

  (foreach p points

    (setq best-label nil)
    (setq best-dist lcm:text-search-radius)
    (setq best-handle nil)

    (foreach tx texts
      (setq d
        (distance
          (list (nth 1 p) (nth 2 p))
          (list (nth 1 tx) (nth 2 tx))
        )
      )
      (if (< d best-dist)
        (progn
          (setq best-dist d)
          (setq best-label (nth 0 tx))
          (setq best-handle (nth 3 tx))
        )
      )
    )

    (if best-label
      (setq records
        (cons
          (list (nth 0 p) (nth 1 p) (nth 2 p) best-label best-dist best-handle)
          records
        )
      )
      (setq records
        (cons
          (list (nth 0 p) (nth 1 p) (nth 2 p)
                (strcat lcm:unnamed-point-prefix (nth 0 p))
                nil
                nil
          )
          records
        )
      )
    )
  )

  (list (length points) (length texts) records)
)


;;; ------------------------------------------------------------
;;; Расстояния до ближайшего соседа внутри одного слоя
;;; ------------------------------------------------------------

(defun lcm:diag-nn-distances (records / result best d)
  (setq result '())
  (foreach a records
    (setq best nil)
    (foreach b records
      (if (/= (car a) (car b))
        (progn
          (setq d
            (distance
              (list (nth 1 a) (nth 2 a))
              (list (nth 1 b) (nth 2 b))
            )
          )
          (if (or (null best) (< d best))
            (setq best d)
          )
        )
      )
    )
    (if best
      (setq result (cons best result))
    )
  )
  result
)


;;; ------------------------------------------------------------
;;; Процентиль по отсортированному списку
;;; ------------------------------------------------------------

(defun lcm:diag-percentile (sorted-values p / n idx)
  (setq n (length sorted-values))
  (if (= n 0)
    nil
    (progn
      (setq idx (fix (* p (1- n))))
      (if (< idx 0) (setq idx 0))
      (if (>= idx n) (setq idx (1- n)))
      (nth idx sorted-values)
    )
  )
)


;;; ------------------------------------------------------------
;;; Медиана по отсортированному списку
;;; ------------------------------------------------------------

(defun lcm:diag-median (sorted-values / n)
  (setq n (length sorted-values))
  (if (= n 0)
    nil
    (if (= (rem n 2) 1)
      (nth (/ (1- n) 2) sorted-values)
      (/ (+ (nth (1- (/ n 2)) sorted-values)
            (nth (/ n 2) sorted-values)
         )
         2.0
      )
    )
  )
)


;;; ------------------------------------------------------------
;;; Имена, встречающиеся больше одного раза
;;; ------------------------------------------------------------

(defun lcm:diag-duplicates (records / names name pair result)
  (setq names '())
  (foreach r records
    (setq name (nth 3 r))
    (setq pair (assoc name names))
    (if pair
      (setq names (subst (cons name (1+ (cdr pair))) pair names))
      (setq names (cons (cons name 1) names))
    )
  )
  (setq result '())
  (foreach pair names
    (if (> (cdr pair) 1)
      (setq result (cons pair result))
    )
  )
  (vl-sort result (function (lambda (a b) (> (cdr a) (cdr b)))))
)


;;; ------------------------------------------------------------
;;; Имя слоя, пригодное для имени файла
;;; ------------------------------------------------------------

(defun lcm:diag-safe-name (name)
  (vl-string-translate " /\\:*?\"<>|" "_________" name)
)


;;; ------------------------------------------------------------
;;; Метка времени вида ГГГГММДДЧЧММСС
;;; ------------------------------------------------------------

(defun lcm:diag-timestamp ( / value)
  (setq value (rtos (getvar "CDATE") 2 6))
  (vl-string-subst "" "." value)
)


;;; ------------------------------------------------------------
;;; Папка отчётов
;;; ------------------------------------------------------------

(defun lcm:diag-reports-folder ( / folder reports)
  (setq folder (lcm:diag-folder))
  (setq reports (strcat folder "\\reports"))
  (if (not (vl-file-directory-p reports))
    (vl-mkdir reports)
  )
  reports
)


;;; ------------------------------------------------------------
;;; Выгрузка одного слоя в CSV
;;; ------------------------------------------------------------

(defun lcm:diag-write-csv
  (
    layer-name
    /
    reports path scan records fp pts texts rec
  )

  (setq scan (lcm:diag-scan-layer layer-name))
  (setq pts (nth 0 scan))
  (setq texts (nth 1 scan))
  (setq records (nth 2 scan))

  (setq reports (lcm:diag-reports-folder))
  (setq path
    (strcat reports "\\lcm_points_"
            (lcm:diag-safe-name layer-name) "_"
            (lcm:diag-timestamp) ".csv"
    )
  )

  (setq fp (open path "w"))

  (if (not fp)
    (progn
      (prompt (strcat "\nLCM ERROR: не удалось создать файл: " path))
      nil
    )
    (progn
      (write-line "# Layer Cycle Manager - диагностика точек" fp)
      (write-line (strcat "# Чертеж: " (getvar "DWGNAME")) fp)
      (write-line (strcat "# Слой: " layer-name) fp)
      (write-line (strcat "# Точек: " (itoa pts) " | текстов: " (itoa texts)) fp)
      (write-line "# handle;x;y;name;label_dist;label_handle" fp)

      (foreach rec records
        (write-line
          (strcat
            (lcm:diag-csv-field (nth 0 rec)) ";"
            (lcm:diag-num (nth 1 rec) 6) ";"
            (lcm:diag-num (nth 2 rec) 6) ";"
            (lcm:diag-csv-field (nth 3 rec)) ";"
            (if (nth 4 rec) (lcm:diag-num (nth 4 rec) 6) "") ";"
            (if (nth 5 rec) (lcm:diag-csv-field (nth 5 rec)) "")
          )
          fp
        )
      )

      (close fp)

      (prompt (strcat "\nLCM: выгружено точек: " (itoa (length records))))
      (prompt (strcat "\nLCM: файл: " path))
      path
    )
  )
)


;;; ------------------------------------------------------------
;;; Карта имён слоя: (имя . (x y handle))
;;; При дубликате имени остаётся первая найденная точка.
;;; ------------------------------------------------------------

(defun lcm:diag-name-map (records / map name)
  (setq map '())
  (foreach rec records
    (setq name (nth 3 rec))
    (if (not (assoc name map))
      (setq map
        (cons
          (cons name (list (nth 1 rec) (nth 2 rec) (nth 0 rec)))
          map
        )
      )
    )
  )
  map
)


;;; ------------------------------------------------------------
;;; Отчёт по паре слоёв
;;; ------------------------------------------------------------

(defun lcm:diag-pair-report
  (
    layer-a
    layer-b
    /
    sa sb ra rb map-a map-b
    matched name pa pb d sorted
    gaps-a gaps-b pair
    best second best-name second-d cand
    reports path fp rows
    min-d med-d max-d
    i
  )

  (setq sa (lcm:diag-scan-layer layer-a))
  (setq sb (lcm:diag-scan-layer layer-b))
  (setq ra (nth 2 sa))
  (setq rb (nth 2 sb))
  (setq map-a (lcm:diag-name-map ra))
  (setq map-b (lcm:diag-name-map rb))

  ;; --- совпадения по имени ---
  (setq matched '())
  (foreach pair map-a
    (setq name (car pair))
    (setq pb (assoc name map-b))
    (if pb
      (setq matched
        (cons
          (list name
                (distance
                  (list (nth 0 (cdr pair)) (nth 1 (cdr pair)))
                  (list (nth 0 (cdr pb)) (nth 1 (cdr pb)))
                )
          )
          matched
        )
      )
    )
  )

  ;; --- пробелы ---
  (setq gaps-a '())
  (setq gaps-b '())
  (foreach pair map-a
    (if (not (assoc (car pair) map-b))
      (setq gaps-a (cons pair gaps-a))
    )
  )
  (foreach pair map-b
    (if (not (assoc (car pair) map-a))
      (setq gaps-b (cons pair gaps-b))
    )
  )

  ;; --- статистика совпадений ---
  (setq min-d nil med-d nil max-d nil)
  (if (> (length matched) 0)
    (progn
      (setq sorted
        (vl-sort (mapcar (function (lambda (m) (nth 1 m))) matched)
                 (function <)
        )
      )
      (setq min-d (car sorted))
      (setq max-d (last sorted))
      (setq med-d (lcm:diag-median sorted))
    )
  )

  ;; --- CSV ---
  (setq reports (lcm:diag-reports-folder))
  (setq path
    (strcat reports "\\lcm_pair_"
            (lcm:diag-safe-name layer-a) "__"
            (lcm:diag-safe-name layer-b) "_"
            (lcm:diag-timestamp) ".csv"
    )
  )

  (setq fp (open path "w"))

  (if (not fp)
    (progn
      (prompt (strcat "\nLCM ERROR: не удалось создать файл: " path))
      nil
    )
    (progn
      (write-line "# Layer Cycle Manager - сравнение слоёв" fp)
      (write-line (strcat "# Чертеж: " (getvar "DWGNAME")) fp)
      (write-line (strcat "# Слой A (нулевой): " layer-a) fp)
      (write-line (strcat "# Слой B (последний): " layer-b) fp)
      (write-line (strcat "# Точек A: " (itoa (length ra))
                          " | Точек B: " (itoa (length rb))
                          " | Уникальных имён A: " (itoa (length map-a))
                          " | B: " (itoa (length map-b))
                  ) fp)
      (write-line (strcat "# Совпало по именам: " (itoa (length matched))) fp)
      (if min-d
        (write-line (strcat "# Отклонение по совпавшим парам (ед. чертежа): минимум "
                            (lcm:diag-num min-d 6)
                            " | медиана " (lcm:diag-num med-d 6)
                            " | максимум " (lcm:diag-num max-d 6)
                    ) fp)
      )
      (write-line (strcat "# Пробелов: в A " (itoa (length gaps-a))
                          " | в B " (itoa (length gaps-b))
                  ) fp)
      (write-line "# side;from_name;from_x;from_y;to_name;to_x;to_y;dist;second_dist;ratio" fp)

      ;; --- пробелы слоя A ищем среди пробелов слоя B ---
      (foreach pair gaps-a
        (setq pa (cdr pair))
        (setq best nil best-name nil second nil)

        (foreach cand gaps-b
          (setq pb (cdr cand))
          (setq d
            (distance
              (list (nth 0 pa) (nth 1 pa))
              (list (nth 0 pb) (nth 1 pb))
            )
          )
          (if (or (null best) (< d best))
            (progn
              (setq second best)
              (setq best d)
              (setq best-name (car cand))
            )
            (if (or (null second) (< d second))
              (setq second d)
            )
          )
        )

        (if best
          (write-line
            (strcat "A;"
                    (lcm:diag-csv-field (car pair)) ";"
                    (lcm:diag-num (nth 0 pa) 6) ";"
                    (lcm:diag-num (nth 1 pa) 6) ";"
                    (lcm:diag-csv-field best-name) ";"
                    (lcm:diag-num (nth 0 (cdr (assoc best-name gaps-b))) 6) ";"
                    (lcm:diag-num (nth 1 (cdr (assoc best-name gaps-b))) 6) ";"
                    (lcm:diag-num best 6) ";"
                    (if second (lcm:diag-num second 6) "") ";"
                    (if (and second (> second 0.0))
                      (lcm:diag-num (/ best second) 4)
                      ""
                    )
            )
            fp
          )
        )
      )

      ;; --- пробелы слоя B ищем среди пробелов слоя A ---
      (foreach pair gaps-b
        (setq pa (cdr pair))
        (setq best nil best-name nil second nil)

        (foreach cand gaps-a
          (setq pb (cdr cand))
          (setq d
            (distance
              (list (nth 0 pa) (nth 1 pa))
              (list (nth 0 pb) (nth 1 pb))
            )
          )
          (if (or (null best) (< d best))
            (progn
              (setq second best)
              (setq best d)
              (setq best-name (car cand))
            )
            (if (or (null second) (< d second))
              (setq second d)
            )
          )
        )

        (if best
          (write-line
            (strcat "B;"
                    (lcm:diag-csv-field (car pair)) ";"
                    (lcm:diag-num (nth 0 pa) 6) ";"
                    (lcm:diag-num (nth 1 pa) 6) ";"
                    (lcm:diag-csv-field best-name) ";"
                    (lcm:diag-num (nth 0 (cdr (assoc best-name gaps-a))) 6) ";"
                    (lcm:diag-num (nth 1 (cdr (assoc best-name gaps-a))) 6) ";"
                    (lcm:diag-num best 6) ";"
                    (if second (lcm:diag-num second 6) "") ";"
                    (if (and second (> second 0.0))
                      (lcm:diag-num (/ best second) 4)
                      ""
                    )
            )
            fp
          )
        )
      )

      (close fp)

      ;; --- отчёт в командную строку ---
      (prompt "\n--- LCMDIAGPAIR ---")
      (prompt (strcat "\nСлой A: " layer-a " | точек: " (itoa (length ra))
                      " | уникальных имён: " (itoa (length map-a))))
      (prompt (strcat "\nСлой B: " layer-b " | точек: " (itoa (length rb))
                      " | уникальных имён: " (itoa (length map-b))))
      (prompt (strcat "\nСовпало по именам: " (itoa (length matched))))

      (if min-d
        (prompt (strcat "\nОтклонение по совпавшим парам: мин "
                        (lcm:diag-num min-d 3)
                        " | медиана " (lcm:diag-num med-d 3)
                        " | макс " (lcm:diag-num max-d 3)))
      )

      (prompt (strcat "\nПробелов: в A " (itoa (length gaps-a))
                      " | в B " (itoa (length gaps-b))))

      ;; --- самые крупные совпавшие пары ---
      (if (> (length matched) 0)
        (progn
          (setq rows
            (vl-sort matched (function (lambda (a b) (> (nth 1 a) (nth 1 b)))))
          )
          (prompt "\nСамые крупные отклонения среди совпавших по имени:")
          (setq i 0)
          (foreach cand rows
            (if (< i lcm:diag-print-limit)
              (prompt (strcat "\n  " (car cand) " -> " (lcm:diag-num (nth 1 cand) 4)))
            )
            (setq i (1+ i))
          )
        )
      )

      (prompt (strcat "\nLCM: файл отчёта: " path))
      path
    )
  )
)


;;; ------------------------------------------------------------
;;; Команда LCMSTATS: статистика по одному слою
;;; ------------------------------------------------------------

(defun C:LCMSTATS
  (
    /
    layer default scan pts texts records nn sorted
    unnamed far dup i rec
  )

  (setq default "0")
  (if (and lcm:settings (assoc "LAYER_ZERO" lcm:settings))
    (setq default (cdr (assoc "LAYER_ZERO" lcm:settings)))
  )

  (setq layer (getstring T (strcat "\nLCM: слой для анализа <" default ">: ")))
  (if (= layer "") (setq layer default))

  (if (= layer "")
    (prompt "\nLCM: слой не задан.")
    (progn
      (prompt (strcat "\nLCM: анализ слоя '" layer "'..."))

      (setq scan (lcm:diag-scan-layer layer))
      (setq pts (nth 0 scan))
      (setq texts (nth 1 scan))
      (setq records (nth 2 scan))

      (prompt "\n--- LCMSTATS ---")
      (prompt (strcat "\nСлой: " layer))
      (prompt (strcat "\nТочек (AcDbPoint): " (itoa pts)))
      (prompt (strcat "\nТекстов на слое (AcDbText/MText): " (itoa texts)))

      (if (= (length records) 0)
        (prompt "\nLCM: точек на слое не найдено. Проверьте имя слоя и то, что точки лежат в ModelSpace.")
        (progn
          (setq unnamed 0)
          (setq far 0)

          (foreach rec records
            (if (null (nth 4 rec))
              (setq unnamed (1+ unnamed))
            )
            (if (and (nth 4 rec) (> (nth 4 rec) lcm:diag-label-warn))
              (setq far (1+ far))
            )
          )

          (setq dup (lcm:diag-duplicates records))

          (prompt (strcat "\nТочек без подписи в радиусе "
                          (rtos lcm:text-search-radius 2 1) ": "
                          (itoa unnamed)))
          (prompt (strcat "\nТочек с подписью дальше "
                          (rtos lcm:diag-label-warn 2 2) ": "
                          (itoa far)))
          (prompt (strcat "\nИмён-дубликатов: " (itoa (length dup))))

          (setq i 0)
          (foreach pair dup
            (if (< i lcm:diag-print-limit)
              (prompt (strcat "\n  дубликат имени: '" (car pair) "' встречается "
                              (itoa (cdr pair)) " раз"))
            )
            (setq i (1+ i))
          )

          (setq nn (lcm:diag-nn-distances records))

          (if (> (length nn) 1)
            (progn
              (setq sorted (vl-sort nn (function <)))
              (prompt "\nРасстояние до ближайшего соседа (единицы чертежа):")
              (prompt (strcat "\n  минимум: " (lcm:diag-num (car sorted) 3)))
              (prompt (strcat "\n  p05:     "
                              (lcm:diag-num (lcm:diag-percentile sorted 0.05) 3)))
              (prompt (strcat "\n  медиана: "
                              (lcm:diag-num (lcm:diag-median sorted) 3)))
              (prompt (strcat "\n  p95:     "
                              (lcm:diag-num (lcm:diag-percentile sorted 0.95) 3)))
              (prompt (strcat "\nПредлагаемый порог сопоставления (0.5 x минимум): "
                              (lcm:diag-num (* 0.5 (car sorted)) 3)))
            )
            (prompt "\nLCM: для оценки расстояний до соседей нужно минимум 2 точки.")
          )
        )
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Команда LCMDUMP: выгрузка точек слоёв в CSV
;;; ------------------------------------------------------------

(defun C:LCMDUMP ( / layer)
  (prompt "\nLCMDUMP: выгрузка точек слоя в CSV.")
  (prompt "\nВводите имена слоёв по одному, пустая строка - завершить.")

  (while (/= (setq layer (getstring T "\nLCM: слой для выгрузки: ")) "")
    (prompt (strcat "\nLCM: сканирую слой '" layer "'..."))
    (if (lcm:diag-write-csv layer)
      (prompt "\nLCM: готово, можно ввести следующий слой.")
      (prompt "\nLCM: слой выгрузить не удалось.")
    )
  )

  (prompt "\nLCMDUMP: завершено.")
  (princ)
)


;;; ------------------------------------------------------------
;;; Команда LCMDIAGPAIR: сравнение двух слоёв
;;; ------------------------------------------------------------

(defun C:LCMDIAGPAIR ( / layer-a layer-b default-a default-b)
  (setq default-a "0")
  (setq default-b "0")

  (if (and lcm:settings (assoc "LAYER_ZERO" lcm:settings))
    (setq default-a (cdr (assoc "LAYER_ZERO" lcm:settings)))
  )
  (if (and lcm:settings (assoc "LAYER_LAST" lcm:settings))
    (setq default-b (cdr (assoc "LAYER_LAST" lcm:settings)))
  )

  (setq layer-a (getstring T (strcat "\nLCM: слой A (нулевой) <" default-a ">: ")))
  (if (= layer-a "") (setq layer-a default-a))

  (setq layer-b (getstring T (strcat "\nLCM: слой B (последний) <" default-b ">: ")))
  (if (= layer-b "") (setq layer-b default-b))

  (if (or (= layer-a "") (= layer-b ""))
    (prompt "\nLCM: нужно указать оба слоя.")
    (lcm:diag-pair-report layer-a layer-b)
  )

  (princ)
)


(princ)
