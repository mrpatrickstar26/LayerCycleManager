;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_geo.lsp
;;; Этап 1: сопоставление точек по координатам
;;; ============================================================
;;;
;;; Назначение: после авто-сопоставления по именам закрыть пробелы
;;; (<not found>), то есть найти пары точек, у которых имена разные,
;;; но координаты близки. Пример: "43" и "43,1" - одна и та же точка
;;; разных циклов.
;;;
;;; Порядок работы ("по координатам"):
;;;   1) для каждой точки слоя A берётся ближайшая точка слоя B
;;;      в радиусе R (по умолчанию 5 единиц чертежа);
;;;   2) если на одну точку B претендуют несколько точек A,
;;;      побеждает пара с меньшим расстоянием;
;;;   3) пары по именам ("Авто-сопоставление" в диалоге) не трогаются:
;;;      команда только добавляет недостающие пары.
;;;
;;; Модуль цепочки циклов (lcm_chain.lsp) использует отдельное, более
;;; строгое сопоставление lcm:geo-match-points: взаимно ближайший
;;; кандидат, порог по 5-му процентилю и ограничение на второго кандидата.
;;;
;;; Требуется загруженный модуль lcm_diag.lsp (сканирование слоя).
;;; Для отрисовки требуется lcm_core.lsp (функция lcm:run).
;;;
;;; Команды:
;;;   LCMGEOFILL - диалоговая команда: отчет или отрисовка
;;;
;;; Функции для агента:
;;;   (lcm:geo-run "слой A" "слой B" nil T)   - сопоставить и нарисовать
;;;   (lcm:geo-run "слой A" "слой B" nil nil) - только отчёт, без отрисовки
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Параметры по умолчанию
;;; ------------------------------------------------------------

;;; Доля от минимального расстояния между соседями - порог поиска пары.
(if (not lcm:geo-r-factor)
  (setq lcm:geo-r-factor 0.5)
)

;;; Во сколько раз второй кандидат должен быть дальше лучшего,
;;; чтобы пара считалась однозначной.
(if (not lcm:geo-ratio)
  (setq lcm:geo-ratio 1.5)
)

;;; Значения по умолчанию для отрисовки, если настройки не загружены.
(if (not lcm:geo-default-scale)
  (setq lcm:geo-default-scale 70.0)
)

(if (not lcm:geo-default-text-height)
  (setq lcm:geo-default-text-height 5.0)
)


;;; ------------------------------------------------------------
;;; Вспомогательные функции
;;; ------------------------------------------------------------

;;; Настройка из lcm:settings или значение по умолчанию.
(defun lcm:geo-setting (key default)
  (if (and lcm:settings (assoc key lcm:settings))
    (cdr (assoc key lcm:settings))
    default
  )
)


;;; Преобразование записей слоя в список точек (имя x y handle).
(defun lcm:geo-points (records / out)
  (setq out '())
  (foreach r records
    (setq out
      (cons (list (nth 3 r) (nth 1 r) (nth 2 r) (nth 0 r)) out)
    )
  )
  (reverse out)
)


;;; Количество вхождений каждого имени: alist (имя . количество).
(defun lcm:geo-name-counts (points / counts name pair)
  (setq counts '())
  (foreach p points
    (setq name (car p))
    (setq pair (assoc name counts))
    (if pair
      (setq counts (subst (cons name (1+ (cdr pair))) pair counts))
      (setq counts (cons (cons name 1) counts))
    )
  )
  counts
)


;;; Точки с уникальными в пределах слоя именами.
(defun lcm:geo-unique (points counts / out)
  (setq out '())
  (foreach p points
    (if (= 1 (cdr (assoc (car p) counts)))
      (setq out (cons p out))
    )
  )
  (reverse out)
)



;;; Точка по имени.
(defun lcm:geo-find (name points / found)
  (setq found nil)
  (foreach q points
    (if (and (not found) (= (car q) name))
      (setq found q)
    )
  )
  found
)


;;; Ближайшая и вторая по близости точки из списка.
;;; Возвращает (имя_ближайшей расстояние второе_расстояние) или nil.
(defun lcm:geo-nearest (p points / best best-name second d)
  (setq best nil)
  (setq best-name nil)
  (setq second nil)

  (foreach q points
    (setq d
      (distance
        (list (nth 1 p) (nth 2 p))
        (list (nth 1 q) (nth 2 q))
      )
    )
    (cond
      ((or (null best) (< d best))
       (setq second best)
       (setq best d)
       (setq best-name (car q))
      )
      ((or (null second) (< d second))
       (setq second d)
      )
    )
  )

  (if best
    (list best-name best second)
    nil
  )
)



;;; Расстояние между точками по имени (для отчёта).
(defun lcm:geo-dist (name-a name-b points-a points-b / pa pb)
  (setq pa (lcm:geo-find name-a points-a))
  (setq pb (lcm:geo-find name-b points-b))
  (if (and pa pb)
    (distance
      (list (nth 1 pa) (nth 2 pa))
      (list (nth 1 pb) (nth 2 pb))
    )
    nil
  )
)


;;; Расстояния до ближайшего соседа для списка точек (имя x y handle).
(defun lcm:geo-nn-list (points / out i j n d best a b)
  (setq out '())
  (setq n (length points))
  (setq i 0)
  (while (< i n)
    (setq a (nth i points))
    (setq best nil)
    (setq j 0)
    (while (< j n)
      (if (/= i j)
        (progn
          (setq b (nth j points))
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
      (setq j (1+ j))
    )
    (if best
      (setq out (cons best out))
    )
    (setq i (1+ i))
  )
  out
)


;;; Опорное расстояние слоя: 5-й процентиль расстояний до ближайшего
;;; соседа по точкам с уникальными именами. Устойчиво к совпадающим
;;; точкам и к дубликатам имён.
(defun lcm:geo-spacing-base (layer-name / pts uniq nn)
  (setq pts (lcm:geo-points (nth 2 (lcm:diag-scan-layer layer-name))))
  (setq uniq (lcm:geo-unique pts (lcm:geo-name-counts pts)))
  (setq nn (lcm:geo-nn-list uniq))
  (if nn
    (lcm:diag-percentile (vl-sort nn (function <)) 0.05)
    nil
  )
)


;;; То же для уже готового списка точек.
(defun lcm:geo-spacing-base-points (points / nn)
  (setq nn (lcm:geo-nn-list points))
  (if nn
    (lcm:diag-percentile (vl-sort nn (function <)) 0.05)
    nil
  )
)


;;; ------------------------------------------------------------
;;; Основное сопоставление
;;; Возвращает список из пяти элементов:
;;;   1) mappings   - ((from . имя)(to . имя)) для lcm:run
;;;   2) review     - (имя A имя B расстояние второй отношение причина)
;;;   3) unmatched-a - имена слоя A без пары
;;;   4) unmatched-b - имена слоя B без пары
;;;   5) details    - (имя A имя B расстояние способ)
;;; ------------------------------------------------------------

;;; Сопоставление двух готовых списков точек (имя x y handle).
;;; Возвращает (mappings review unmatched-a unmatched-b details r-use).
(defun lcm:geo-match-points
  (
    pts-a
    pts-b
    r-max
    /
    counts-a counts-b
    uniq-a uniq-b
    mappings details review
    used-a used-b
    rem-a rem-b
    table-b
    pa pb cand nb d second mutual
    accepted reason
    unmatched-a unmatched-b
    r-use min-a min-b
  )

  (setq counts-a (lcm:geo-name-counts pts-a))
  (setq counts-b (lcm:geo-name-counts pts-b))

  (setq uniq-a (lcm:geo-unique pts-a counts-a))
  (setq uniq-b (lcm:geo-unique pts-b counts-b))

  ;; --- порог: доля от 5-го процентиля расстояний до ближайшего соседа ---
  (setq r-use r-max)
  (if (or (null r-use) (<= r-use 0.0))
    (progn
      (setq min-a (lcm:geo-spacing-base-points uniq-a))
      (setq min-b (lcm:geo-spacing-base-points uniq-b))
      (setq r-use
        (* lcm:geo-r-factor
           (min (if min-a min-a 1.0) (if min-b min-b 1.0))
        )
      )
    )
  )

  ;; --- 1. совпадения по именам ---
  (setq mappings '())
  (setq details '())
  (setq review '())
  (setq used-a '())
  (setq used-b '())

  (foreach pa uniq-a
    (if (= 1 (if (assoc (car pa) counts-b) (cdr (assoc (car pa) counts-b)) 0))
      (progn
        (setq d (lcm:geo-dist (car pa) (car pa) pts-a pts-b))
        (if (and d (> d (* 2.0 r-use)))
          ;; имя совпало, но точки далеко друг от друга - на проверку
          (setq review
            (append review
              (list (list (car pa) (car pa) d nil
                          (if (> d 0.0) (/ (* 2.0 r-use) d) nil)
                          "имя совпало, но точки далеко"))
            )
          )
          (progn
            (setq mappings
              (append mappings
                (list
                  (list (cons 'from (car pa)) (cons 'to (car pa)))
                )
              )
            )
            (setq details
              (append details
                (list (list (car pa) (car pa) d "имя"))
              )
            )
            (setq used-a (cons (car pa) used-a))
            (setq used-b (cons (car pa) used-b))
          )
        )
      )
    )
  )

  ;; --- 2. остаток для геометрического сопоставления ---
  (setq rem-a '())
  (setq rem-b '())

  (foreach pa uniq-a
    (if (not (member (car pa) used-a))
      (setq rem-a (cons pa rem-a))
    )
  )
  (foreach pb uniq-b
    (if (not (member (car pb) used-b))
      (setq rem-b (cons pb rem-b))
    )
  )

  (setq rem-a (reverse rem-a))
  (setq rem-b (reverse rem-b))

  ;; --- 3. таблица лучших кандидатов для слоя B (для проверки взаимности) ---
  (setq table-b '())
  (foreach pb rem-b
    (setq cand (lcm:geo-nearest pb rem-a))
    (if cand
      (setq table-b (cons (cons (car pb) (car cand)) table-b))
    )
  )

  ;; --- 4. отбор пар ---
  (foreach pa rem-a
    (setq cand (lcm:geo-nearest pa rem-b))
    (setq accepted nil)
    (setq reason nil)

    (if cand
      (progn
        (setq nb (nth 0 cand))
        (setq d (nth 1 cand))
        (setq second (nth 2 cand))

        (if (<= d r-use)
          (progn
            (setq mutual (= (cdr (assoc nb table-b)) (car pa)))
            (cond
              ((not mutual)
               (setq reason "не взаимно")
              )
              ((and second (< second (* lcm:geo-ratio d)))
               (setq reason "неоднозначно: второй кандидат близко")
              )
              (T
               (setq accepted T)
              )
            )
          )
        )

        (if accepted
          (progn
            (setq mappings
              (append mappings
                (list (list (cons 'from (car pa)) (cons 'to nb)))
              )
            )
            (setq details
              (append details
                (list (list (car pa) nb d "коорд."))
              )
            )
            (setq used-a (cons (car pa) used-a))
            (setq used-b (cons nb used-b))
          )
          (if reason
            (setq review
              (append review
                (list (list (car pa) nb d second
                            (if (and second (> d 0.0)) (/ second d) nil)
                            reason))
              )
            )
          )
        )
      )
    )
  )

  ;; --- 5. что осталось без пары ---
  (setq unmatched-a '())
  (setq unmatched-b '())

  (foreach pa uniq-a
    (if (not (member (car pa) used-a))
      (setq unmatched-a (cons (car pa) unmatched-a))
    )
  )
  (foreach pb uniq-b
    (if (not (member (car pb) used-b))
      (setq unmatched-b (cons (car pb) unmatched-b))
    )
  )

  (list mappings review (reverse unmatched-a) (reverse unmatched-b) details r-use)
)


;;; Сопоставление двух слоёв: чтение точек и вызов lcm:geo-match-points.
(defun lcm:geo-match (layer-a layer-b r-max / scan-a scan-b)
  (setq scan-a (lcm:diag-scan-layer layer-a))
  (setq scan-b (lcm:diag-scan-layer layer-b))
  (lcm:geo-match-points
    (lcm:geo-points (nth 2 scan-a))
    (lcm:geo-points (nth 2 scan-b))
    r-max
  )
)


;;; Радиус поиска пары по координатам по умолчанию (единицы чертежа).
(if (not lcm:geo-default-radius)
  (setq lcm:geo-default-radius 5.0)
)


;;; ------------------------------------------------------------
;;; Простое сопоставление по координатам.
;;; Для каждой точки слоя A берётся ближайшая точка слоя B в радиусе r.
;;; Если на одну точку B претендуют несколько точек A, побеждает
;;; пара с меньшим расстоянием.
;;; Возвращает список (расстояние имя_A имя_B) по возрастанию расстояния.
;;; ------------------------------------------------------------

(defun lcm:geo-radius-pairs (pts-a pts-b r / cands out used-a used-b p q d item)
  (setq cands '())

  (foreach p pts-a
    (foreach q pts-b
      (setq d
        (distance
          (list (nth 1 p) (nth 2 p))
          (list (nth 1 q) (nth 2 q))
        )
      )
      (if (<= d r)
        (setq cands (cons (list d (car p) (car q)) cands))
      )
    )
  )

  (setq cands
    (vl-sort cands (function (lambda (x y) (< (car x) (car y))))))

  (setq out '())
  (setq used-a '())
  (setq used-b '())

  (foreach item cands
    (if (and (not (member (nth 1 item) used-a))
             (not (member (nth 2 item) used-b)))
      (progn
        (setq used-a (cons (nth 1 item) used-a))
        (setq used-b (cons (nth 2 item) used-b))
        (setq out (cons item out))
      )
    )
  )

  (reverse out)
)


;;; ------------------------------------------------------------
;;; Сопоставление двух слоёв по координатам.
;;; Возвращает ту же структуру, что lcm:geo-match:
;;;   (mappings review unmatched-a unmatched-b details r-use)
;;; При простом правиле "спорных" пар нет, review всегда пуст.
;;; ------------------------------------------------------------

(defun lcm:geo-match-radius-layer
  (layer-a layer-b r excl-a excl-b / scan-a scan-b pts-a pts-b counts-a counts-b
   uniq-a uniq-b r-use res item mappings details used-a used-b
   unmatched-a unmatched-b p)
  (setq r-use (if (and r (> r 0.0)) r lcm:geo-default-radius))

  (setq scan-a (lcm:diag-scan-layer layer-a))
  (setq scan-b (lcm:diag-scan-layer layer-b))
  (setq pts-a (lcm:geo-points (nth 2 scan-a)))
  (setq pts-b (lcm:geo-points (nth 2 scan-b)))

  (setq counts-a (lcm:geo-name-counts pts-a))
  (setq counts-b (lcm:geo-name-counts pts-b))
  (setq uniq-a (lcm:geo-unique pts-a counts-a))
  (setq uniq-b (lcm:geo-unique pts-b counts-b))

  ;; уже занятые точки (пары по именам, ручные) в поиске не участвуют
  (if excl-a
    (setq uniq-a
      (vl-remove-if (function (lambda (p) (member (car p) excl-a))) uniq-a)))
  (if excl-b
    (setq uniq-b
      (vl-remove-if (function (lambda (p) (member (car p) excl-b))) uniq-b)))

  (setq res (lcm:geo-radius-pairs uniq-a uniq-b r-use))

  (setq mappings '())
  (setq details '())
  (setq used-a '())
  (setq used-b '())

  (foreach item res
    (setq mappings
      (append mappings
        (list (list (cons 'from (nth 1 item)) (cons 'to (nth 2 item))))))
    (setq details
      (append details
        (list (list (nth 1 item) (nth 2 item) (car item) "коорд."))))
    (setq used-a (cons (nth 1 item) used-a))
    (setq used-b (cons (nth 2 item) used-b))
  )

  (setq unmatched-a '())
  (foreach p uniq-a
    (if (not (member (car p) used-a))
      (setq unmatched-a (cons (car p) unmatched-a))
    )
  )

  (setq unmatched-b '())
  (foreach p uniq-b
    (if (not (member (car p) used-b))
      (setq unmatched-b (cons (car p) unmatched-b))
    )
  )

  (list mappings '() (reverse unmatched-a) (reverse unmatched-b) details r-use)
)


;;; ------------------------------------------------------------
;;; Отчёт в CSV
;;; ------------------------------------------------------------

(defun lcm:geo-write-report
  (
    layer-a
    layer-b
    match
    /
    mappings review unmatched-a unmatched-b details r-use
    reports path fp item
  )

  (setq mappings (nth 0 match))
  (setq review (nth 1 match))
  (setq unmatched-a (nth 2 match))
  (setq unmatched-b (nth 3 match))
  (setq details (nth 4 match))
  (setq r-use (nth 5 match))

  (setq reports (lcm:diag-reports-folder))
  (setq path
    (strcat reports "\\lcm_geo_"
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
      (write-line "# Layer Cycle Manager - сопоставление по именам и координатам" fp)
      (write-line (strcat "# Чертеж: " (getvar "DWGNAME")) fp)
      (write-line (strcat "# Слой A: " layer-a) fp)
      (write-line (strcat "# Слой B: " layer-b) fp)
      (write-line (strcat "# Порог: " (lcm:diag-num r-use 4)) fp)
      (write-line (strcat "# Принято: " (itoa (length mappings))
                          " | Спорных: " (itoa (length review))
                          " | Без пары в A: " (itoa (length unmatched-a))
                          " | Без пары в B: " (itoa (length unmatched-b))
                  ) fp)
      (write-line "" fp)
      (write-line "# ПРИНЯТЫЕ ПАРЫ" fp)
      (write-line "# from;to;dist;method" fp)

      (foreach item details
        (write-line
          (strcat
            (lcm:diag-csv-field (nth 0 item)) ";"
            (lcm:diag-csv-field (nth 1 item)) ";"
            (if (nth 2 item) (lcm:diag-num (nth 2 item) 6) "") ";"
            (lcm:diag-csv-field (nth 3 item))
          )
          fp
        )
      )

      (write-line "" fp)
      (write-line "# СПОРНЫЕ ПАРЫ (не рисуются)" fp)
      (write-line "# from;to;dist;second;ratio;reason" fp)

      (foreach item review
        (write-line
          (strcat
            (lcm:diag-csv-field (nth 0 item)) ";"
            (lcm:diag-csv-field (nth 1 item)) ";"
            (if (nth 2 item) (lcm:diag-num (nth 2 item) 6) "") ";"
            (if (nth 3 item) (lcm:diag-num (nth 3 item) 6) "") ";"
            (if (nth 4 item) (lcm:diag-num (nth 4 item) 4) "") ";"
            (lcm:diag-csv-field (nth 5 item))
          )
          fp
        )
      )

      (write-line "" fp)
      (write-line "# БЕЗ ПАРЫ НА СЛОЕ A" fp)
      (foreach item unmatched-a
        (write-line (lcm:diag-csv-field item) fp)
      )

      (write-line "" fp)
      (write-line "# БЕЗ ПАРЫ НА СЛОЕ B" fp)
      (foreach item unmatched-b
        (write-line (lcm:diag-csv-field item) fp)
      )

      (close fp)
      path
    )
  )
)


;;; ------------------------------------------------------------
;;; Запуск: сопоставить, при необходимости нарисовать, записать отчёт
;;; Возвращает сводку списком: (matched by-name by-coord review r-max drawn report)
;;; ------------------------------------------------------------

(defun lcm:geo-run
  (
    layer-a
    layer-b
    r-max
    draw-flag
    /
    match mappings details review unmatched-a unmatched-b r-use
    scale color-mode color-data text-height
    drawn report by-name by-coord
  )

  (if (not lcm:diag-scan-layer)
    (progn
      (prompt "\nLCM ERROR: не загружен модуль lcm_diag.lsp (нужен для чтения точек).")
      nil
    )
    (progn
      (prompt (strcat "\nLCM: сопоставление слоёв '" layer-a "' и '" layer-b "'..."))

      (setq match (lcm:geo-match-radius-layer layer-a layer-b r-max nil nil))
      (setq mappings (nth 0 match))
      (setq review (nth 1 match))
      (setq unmatched-a (nth 2 match))
      (setq unmatched-b (nth 3 match))
      (setq details (nth 4 match))
      (setq r-use (nth 5 match))

      (setq by-name 0)
      (setq by-coord 0)
      (foreach item details
        (if (= (nth 3 item) "имя")
          (setq by-name (1+ by-name))
          (setq by-coord (1+ by-coord))
        )
      )

      (prompt (strcat "\nLCM: порог сопоставления: " (lcm:diag-num r-use 4)))
      (prompt (strcat "\nLCM: принято пар: " (itoa (length mappings))
                      " (по именам " (itoa by-name)
                      ", по координатам " (itoa by-coord) ")"))
      (prompt (strcat "\nLCM: спорных пар (не рисуются): " (itoa (length review))))
      (prompt (strcat "\nLCM: без пары: слой A " (itoa (length unmatched-a))
                      ", слой B " (itoa (length unmatched-b))))

      (if (> (length review) 0)
        (progn
          (prompt "\nLCM: спорные пары (первые 10):")
          (setq by-name 0)
          (foreach item review
            (if (< by-name 10)
              (prompt (strcat "\n  " (nth 0 item) " -> " (nth 1 item)
                              ", " (lcm:diag-num (nth 2 item) 3)
                              " (" (nth 5 item) ")"))
            )
            (setq by-name (1+ by-name))
          )
        )
      )

      (setq drawn 0)

      (if (and draw-flag (not lcm:run))
        (prompt "\nLCM: отрисовка недоступна: не загружен lcm_core.lsp. Выполняется только отчёт.")
      )

      (if (and draw-flag lcm:run)
        (progn
          (if (= (length mappings) 0)
            (prompt "\nLCM: нет пар для отрисовки.")
            (progn
              (setq scale (lcm:geo-setting "SCALE" lcm:geo-default-scale))
              (setq text-height
                (lcm:geo-setting "TEXT_HEIGHT" lcm:geo-default-text-height))
              (if (= 1 (lcm:geo-setting "BY_LAYER" 1))
                (progn
                  (setq color-mode "BYLAYER")
                  (setq color-data nil)
                )
                (progn
                  (setq color-mode "ACI")
                  (setq color-data (lcm:geo-setting "ACI" 1))
                )
              )
              (prompt (strcat "\nLCM: отрисовка " (itoa (length mappings))
                              " стрелок, масштаб " (lcm:diag-num scale 2) "..."))
              (lcm:run layer-a layer-b mappings scale color-mode color-data text-height)
              (setq drawn (length mappings))
              (if lcm:check-remember
                (lcm:check-remember layer-a layer-b mappings scale))
            )
          )
        )
        (prompt "\nLCM: режим только отчёт, отрисовка не выполняется.")
      )

      (setq report (lcm:geo-write-report layer-a layer-b match))

      (if report
        (prompt (strcat "\nLCM: отчёт: " report))
      )

      (list (length mappings) by-name by-coord (length review) r-use drawn report)
    )
  )
)


;;; ------------------------------------------------------------
;;; Команда LCMGEOFILL
;;; ------------------------------------------------------------

(defun C:LCMGEOFILL
  (
    /
    layer-a layer-b default-a default-b
    min-a min-b suggest r-input r-use
    ans draw-flag result
  )

  (setq default-a (lcm:geo-setting "LAYER_ZERO" "0"))
  (setq default-b (lcm:geo-setting "LAYER_LAST" "0"))

  (setq layer-a (getstring T (strcat "\nLCM: слой A (нулевой цикл) <" default-a ">: ")))
  (if (= layer-a "") (setq layer-a default-a))

  (setq layer-b (getstring T (strcat "\nLCM: слой B (последний цикл) <" default-b ">: ")))
  (if (= layer-b "") (setq layer-b default-b))

  (if (or (= layer-a "") (= layer-b ""))
    (prompt "\nLCM: нужно указать оба слоя.")
    (progn
      ;; предложить порог по минимальному расстоянию между соседями
      (setq suggest nil)
      (if lcm:diag-scan-layer
        (progn
          (setq min-a (lcm:geo-spacing-base layer-a))
          (setq min-b (lcm:geo-spacing-base layer-b))
          (if (and min-a min-b)
            (setq suggest (* lcm:geo-r-factor (min min-a min-b)))
          )
        )
      )

      (if suggest
        (prompt (strcat "\nLCM: опорное расстояние до соседей (p05): A "
                        (lcm:diag-num min-a 3) ", B " (lcm:diag-num min-b 3)))
      )

      (setq r-input
        (getreal
          (strcat "\nLCM: порог поиска пары"
                  (if suggest (strcat " <" (lcm:diag-num suggest 3) ">") "")
                  ": "
          )
        )
      )

      (setq r-use (if r-input r-input suggest))

      (initget "Отчет Рисовать")
      (setq ans (getkword "\nLCM: режим [Отчет/Рисовать] <Отчет>: "))

      (setq draw-flag (= ans "Рисовать"))

      (setq result (lcm:geo-run layer-a layer-b r-use draw-flag))

      (if result
        (prompt (strcat "\nLCM: готово. Принято пар: " (itoa (nth 0 result))
                        ", спорных: " (itoa (nth 3 result))
                        ", нарисовано стрелок: " (itoa (nth 5 result))))
        (prompt "\nLCM: сопоставление не выполнено.")
      )
    )
  )

  (princ)
)


(princ)
