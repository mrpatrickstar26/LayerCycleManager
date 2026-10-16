;;; ============================================================
;;; Layer Cycle Manager
;;; File: lcm_chain.lsp
;;; Этап 2: цепочка по циклам и таблица идентичности точек
;;; ============================================================
;;;
;;; Зачем нужен этот модуль.
;;;
;;; Прямое сопоставление "нулевой цикл -> последний" работает, пока
;;; накопленное отклонение меньше половины расстояния между соседними
;;; точками. На длинной серии (десятки циклов) запас становится малым,
;;; а точки могут пропадать на несколько циклов и возвращаться.
;;;
;;; Как работает.
;;;
;;; Идентичность точки протягивается по циклам последовательно:
;;; каждый следующий цикл сопоставляется не с нулевым, а с последним
;;; известным положением точки из таблицы идентичности. Поэтому шаг
;;; сопоставления - это отклонение за один цикл, а не накопленное.
;;; Пропуск циклов не рвёт цепочку: у точки сохраняется её последнее
;;; известное положение. Стрелки, как и раньше, рисуются от нулевого
;;; цикла к последнему - по накопленному отклонению.
;;;
;;; Таблица идентичности хранится в settings/lcm_aliases_<чертеж>.csv
;;; и переиспользуется в следующих запусках (можно продолжить серию).
;;;
;;; Требуется: lcm_diag.lsp, lcm_geo.lsp и (для отрисовки) lcm_core.lsp.
;;;
;;; Команды:
;;;   LCMCHAIN - диалоговая команда: пройти цепочку циклов
;;;
;;; Функция для скриптов и ИИ-агента:
;;;   (lcm:chain-run '("Уч.4 Цикл 0" "Уч.4 Цикл 1" ...) nil)  - только отчёт
;;;   (lcm:chain-run layers T)                                - отчёт и отрисовка
;;; ============================================================

(vl-load-com)


;;; ------------------------------------------------------------
;;; Параметры
;;; ------------------------------------------------------------

;;; Доля от 5-го процентиля расстояний до соседей внутри цикла.
(if (not lcm:chain-r-factor)
  (setq lcm:chain-r-factor 0.5)
)


;;; ------------------------------------------------------------
;;; Вспомогательные функции
;;; ------------------------------------------------------------

;;; Разбить строку по символу ";".
(defun lcm:chain-split (s / pos out)
  (setq out '())
  (while (setq pos (vl-string-search ";" s))
    (setq out (append out (list (substr s 1 pos))))
    (setq s (substr s (+ pos 2)))
  )
  (append out (list s))
)


;;; Число из строки (десятичная запятая).
(defun lcm:chain-num (s)
  (if (and s (/= s ""))
    (atof (vl-string-subst "." "," s))
    nil
  )
)


;;; Символ - цифра.
(defun lcm:chain-digit (ch)
  (and ch (= (strlen ch) 1) (>= (ascii ch) 48) (<= (ascii ch) 57))
)


;;; Базовое имя слоя без номера цикла: "Уч.4 Цикл 51" -> "Уч.4 Цикл ".
(defun lcm:chain-base (layer / i)
  (setq i (strlen layer))
  (while (and (> i 0) (lcm:chain-digit (substr layer i 1)))
    (setq i (1- i))
  )
  (substr layer 1 i)
)


;;; Есть ли строка в списке.
(defun lcm:chain-in-list (value lst / found)
  (setq found nil)
  (foreach x lst
    (if (and (not found) (= x value))
      (setq found T)
    )
  )
  found
)


;;; Найти точку по имени: (имя x y handle).
(defun lcm:chain-find-point (name points / found)
  (setq found nil)
  (foreach p points
    (if (and (not found) (= (car p) name))
      (setq found p)
    )
  )
  found
)


;;; Папка settings.
(defun lcm:chain-ensure-folder ( / folder)
  (setq folder (strcat (lcm:diag-folder) "\\settings"))
  (if (not (vl-file-directory-p folder))
    (vl-mkdir folder)
  )
  folder
)


;;; Путь к таблице идентичности (своя для каждого чертежа).
(defun lcm:chain-file ( / )
  (strcat (lcm:chain-ensure-folder) "\\lcm_aliases_"
          (lcm:diag-safe-name (getvar "DWGNAME")) ".csv")
)


;;; ------------------------------------------------------------
;;; Чтение и запись таблицы идентичности
;;; Запись: (canonical name-a name-b layer-a layer-b x y seen)
;;; ------------------------------------------------------------

(defun lcm:chain-load (path / fp line parts out)
  (setq out '())
  (setq fp (open path "r"))

  (if fp
    (progn
      (while (setq line (read-line fp))
        (if (and (/= line "") (/= (substr line 1 1) "#"))
          (progn
            (setq parts (lcm:chain-split line))
            (if (>= (length parts) 8)
              (setq out
                (cons
                  (list (nth 0 parts) (nth 1 parts) (nth 2 parts)
                        (nth 3 parts) (nth 4 parts)
                        (lcm:chain-num (nth 5 parts))
                        (lcm:chain-num (nth 6 parts))
                        (atoi (nth 7 parts)))
                  out
                )
              )
            )
          )
        )
      )
      (close fp)
    )
  )

  (reverse out)
)


(defun lcm:chain-save (path aliases / fp rec)
  (setq fp (open path "w"))

  (if (not fp)
    (progn
      (prompt (strcat "\nLCM ERROR: не удалось записать таблицу: " path))
      nil
    )
    (progn
      (write-line "# Layer Cycle Manager - таблица идентичности точек" fp)
      (write-line (strcat "# Чертеж: " (getvar "DWGNAME")) fp)
      (write-line (strcat "# Обновлено: " (lcm:diag-timestamp)) fp)
      (write-line "# canonical;name_a;name_b;layer_a;layer_b;x;y;seen" fp)

      (foreach rec aliases
        (write-line
          (strcat
            (lcm:diag-csv-field (nth 0 rec)) ";"
            (lcm:diag-csv-field (nth 1 rec)) ";"
            (lcm:diag-csv-field (nth 2 rec)) ";"
            (lcm:diag-csv-field (nth 3 rec)) ";"
            (lcm:diag-csv-field (nth 4 rec)) ";"
            (lcm:diag-num (nth 5 rec) 6) ";"
            (lcm:diag-num (nth 6 rec) 6) ";"
            (itoa (nth 7 rec))
          )
          fp
        )
      )

      (close fp)
      path
    )
  )
)


;;; ------------------------------------------------------------
;;; Изменение записей таблицы
;;; ------------------------------------------------------------

;;; Обновить совпавшую точку: последнее положение, текущее имя,
;;; номер цикла. На первом слое серии обновляется и "имя A".
(defun lcm:chain-update
  (aliases canon measured-name layer x y first-layer / out rec done)
  (setq out '())
  (setq done nil)

  (foreach rec aliases
    (if (and (not done) (= (nth 0 rec) canon))
      (progn
        (setq out
          (cons
            (list (nth 0 rec)
                  (if (= layer first-layer) measured-name (nth 1 rec))
                  measured-name
                  (if (= layer first-layer) layer (nth 3 rec))
                  layer
                  x y
                  (1+ (nth 7 rec)))
            out
          )
        )
        (setq done T)
      )
      (setq out (cons rec out))
    )
  )

  (reverse out)
)


;;; Новая идентичность: точка впервые встретилась в этом цикле.
(defun lcm:chain-new (aliases name first-layer current-layer x y)
  (append aliases
    (list
      (list name
            (if (= first-layer current-layer) name "")
            name
            (if (= first-layer current-layer) current-layer "")
            current-layer
            x y
            1)
    )
  )
)


;;; ------------------------------------------------------------
;;; Проход по цепочке циклов
;;; Возвращает сводку:
;;;   (слоёв точек-в-последнем пар спорных пропусков отчёт путь-таблицы)
;;; ------------------------------------------------------------

(defun lcm:chain-run
  (
    layers
    draw-flag
    /
    aliases path first-layer last-layer
    layer scan pts measured refs
    match mappings review r-auto
    matched-canon matched-from review-names
    p rec name canon
    new-count miss-count
    rows row
    pairs pair
    scale color-mode color-data text-height
    drawn report
    points-last
  )

  (if (or (not lcm:diag-scan-layer) (not lcm:geo-match-points))
    (progn
      (prompt "\nLCM ERROR: не загружены модули lcm_diag.lsp или lcm_geo.lsp.")
      nil
    )
    (if (= (length layers) 0)
      (progn
        (prompt "\nLCM ERROR: список слоёв пуст.")
        nil
      )
      (progn
        (setq first-layer (car layers))
        (setq last-layer (last layers))
        (setq path (lcm:chain-file))
        (setq aliases (lcm:chain-load path))

        (prompt (strcat "\nLCM: цепочка циклов: слоёв " (itoa (length layers))
                        ", в таблице идентичности точек: " (itoa (length aliases))))

        (setq rows '())

        (foreach layer layers

          (setq scan (lcm:diag-scan-layer layer))
          (setq pts (lcm:geo-points (nth 2 scan)))
          (setq measured (lcm:geo-unique pts (lcm:geo-name-counts pts)))

          (setq new-count 0)
          (setq miss-count 0)
          (setq mappings '())
          (setq review '())

          (if (= (length aliases) 0)

            ;; --- первый слой: создаём идентичности по всем точкам ---
            (foreach p measured
              (setq aliases
                (lcm:chain-new aliases (car p) first-layer layer (nth 1 p) (nth 2 p)))
              (setq new-count (1+ new-count))
            )

            ;; --- остальные слои: сопоставление с последними положениями ---
            (progn

              (setq r-auto
                (* lcm:chain-r-factor (lcm:geo-spacing-base-points measured)))

              (setq refs '())
              (foreach rec aliases
                (setq refs
                  (cons (list (nth 0 rec) (nth 5 rec) (nth 6 rec) (nth 0 rec)) refs))
              )

              (setq match (lcm:geo-match-points measured refs r-auto))
              (setq mappings (nth 0 match))
              (setq review (nth 1 match))

              (setq matched-canon '())
              (setq matched-from '())
              (foreach m mappings
                (setq matched-canon (cons (cdr (assoc 'to m)) matched-canon))
                (setq matched-from (cons (cdr (assoc 'from m)) matched-from))
              )

              ;; обновляем совпавшие точки
              (foreach m mappings
                (setq name (cdr (assoc 'from m)))
                (setq canon (cdr (assoc 'to m)))
                (setq p (lcm:chain-find-point name measured))
                (if p
                  (setq aliases
                    (lcm:chain-update aliases canon name layer
                                      (nth 1 p) (nth 2 p) first-layer))
                )
              )

              ;; спорные имена - их не создаём заново и не рисуем
              (setq review-names '())
              (foreach m review
                (setq review-names (cons (nth 0 m) review-names))
              )

              ;; остальные точки текущего цикла - новые идентичности
              (foreach p measured
                (if (not (or (member (car p) matched-from)
                             (member (car p) review-names)))
                  (progn
                    (setq aliases
                      (lcm:chain-new aliases (car p) first-layer layer
                                     (nth 1 p) (nth 2 p)))
                    (setq new-count (1+ new-count))
                  )
                )
              )

              ;; точки, которых нет в этом цикле (пропуск измерения)
              (foreach rec aliases
                (if (not (or (= (nth 4 rec) layer)
                             (member (nth 0 rec) matched-canon)))
                  (setq miss-count (1+ miss-count))
                )
              )
            )
          )

          (setq row
            (list layer (length measured) (length mappings) new-count miss-count
                  (length review)))
          (setq rows (append rows (list row)))

          (prompt (strcat "\n  " layer ": точек " (itoa (length measured))
                          ", сопоставлено " (itoa (length mappings))
                          ", новых " (itoa new-count)
                          ", пропусков " (itoa miss-count)
                          ", спорных " (itoa (length review))))
        )

        ;; --- пары для отрисовки: от первого слоя серии к последнему ---
        (setq pairs '())
        (foreach rec aliases
          (if (and (= (nth 3 rec) first-layer)
                   (= (nth 4 rec) last-layer)
                   (/= (nth 1 rec) "")
                   (/= (nth 2 rec) ""))
            (setq pairs
              (append pairs
                (list (list (cons 'from (nth 1 rec)) (cons 'to (nth 2 rec))))))
          )
        )

        (prompt (strcat "\nLCM: пар для отрисовки ("
                        first-layer " -> " last-layer "): " (itoa (length pairs))))

        ;; --- отчёт ---
        (setq report (lcm:chain-report first-layer last-layer rows pairs aliases))

        ;; --- отрисовка ---
        (setq drawn 0)
        (if (and draw-flag lcm:run (> (length pairs) 0))
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
            (prompt (strcat "\nLCM: отрисовка " (itoa (length pairs)) " стрелок..."))
            (lcm:run first-layer last-layer pairs scale color-mode color-data text-height)
            (setq drawn (length pairs))
            (if lcm:check-remember
              (lcm:check-remember first-layer last-layer pairs scale))
          )
        )

        ;; --- сохранить таблицу идентичности ---
        (lcm:chain-save path aliases)

        (setq points-last (length (lcm:geo-points (nth 2 (lcm:diag-scan-layer last-layer)))))

        (list (length layers) points-last (length pairs) 0 0 0 drawn report path)
      )
    )
  )
)


;;; ------------------------------------------------------------
;;; Отчёт по цепочке
;;; ------------------------------------------------------------

(defun lcm:chain-report
  (
    first-layer
    last-layer
    rows
    pairs
    aliases
    /
    reports path fp row rec item seen-a seen-b
    points total-pairs
  )

  (setq reports (lcm:diag-reports-folder))
  (setq path
    (strcat reports "\\lcm_chain_"
            (lcm:diag-safe-name first-layer) "__"
            (lcm:diag-safe-name last-layer) "_"
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
      (write-line "# Layer Cycle Manager - цепочка по циклам" fp)
      (write-line (strcat "# Чертеж: " (getvar "DWGNAME")) fp)
      (write-line (strcat "# Первый слой: " first-layer) fp)
      (write-line (strcat "# Последний слой: " last-layer) fp)
      (write-line "" fp)
      (write-line "# ЦИКЛЫ" fp)
      (write-line "# layer;points;matched;new;missing;review" fp)

      (foreach row rows
        (write-line
          (strcat (lcm:diag-csv-field (nth 0 row)) ";"
                  (itoa (nth 1 row)) ";"
                  (itoa (nth 2 row)) ";"
                  (itoa (nth 3 row)) ";"
                  (itoa (nth 4 row)) ";"
                  (itoa (nth 5 row)))
          fp
        )
      )

      (write-line "" fp)
      (write-line "# ПАРЫ ДЛЯ ОТРИСОВКИ (имя в первом слое -> имя в последнем)" fp)
      (write-line "# from;to" fp)

      (foreach item pairs
        (write-line
          (strcat (lcm:diag-csv-field (cdr (assoc 'from item))) ";"
                  (lcm:diag-csv-field (cdr (assoc 'to item))))
          fp
        )
      )

      (write-line "" fp)
      (write-line "# ИДЕНТИЧНОСТЬ ТОЧЕК (canonical;первое имя;последнее имя;наблюдений)" fp)

      (foreach rec aliases
        (write-line
          (strcat (lcm:diag-csv-field (nth 0 rec)) ";"
                  (lcm:diag-csv-field (nth 1 rec)) ";"
                  (lcm:diag-csv-field (nth 2 rec)) ";"
                  (itoa (nth 7 rec)))
          fp
        )
      )

      (close fp)

      (prompt (strcat "\nLCM: отчёт по цепочке: " path))
      path
    )
  )
)


;;; ------------------------------------------------------------
;;; Команда LCMCHAIN
;;; ------------------------------------------------------------

(defun C:LCMCHAIN
  (
    /
    default-zero default-last base base-in
    start-n end-n i
    name layers skipped
    ans draw-flag result
  )

  (if (not (or lcm:diag-scan-layer lcm:geo-match-points))
    (prompt "\nLCM: не загружены модули lcm_diag.lsp или lcm_geo.lsp.")
    (progn
      (setq default-zero (lcm:geo-setting "LAYER_ZERO" "Уч.4 Цикл 0"))
      (setq default-last (lcm:geo-setting "LAYER_LAST" "Уч.4 Цикл 52"))

      (setq base (lcm:chain-base default-zero))
      (setq base-in
        (getstring T (strcat "\nLCM: базовое имя слоёв циклов <" base ">: ")))
      (if (/= base-in "") (setq base base-in))

      (setq start-n (getint "\nLCM: номер первого цикла <0>: "))
      (if (not start-n) (setq start-n 0))

      (setq end-n (getint "\nLCM: номер последнего цикла <52>: "))
      (if (not end-n) (setq end-n 52))

      (setq layers '())
      (setq skipped 0)
      (setq i start-n)

      (while (<= i end-n)
        (setq name (strcat base (itoa i)))
        (if (tblsearch "LAYER" name)
          (setq layers (append layers (list name)))
          (setq skipped (1+ skipped))
        )
        (setq i (1+ i))
      )

      (prompt (strcat "\nLCM: слоёв найдено " (itoa (length layers))
                      (if (> skipped 0)
                        (strcat ", пропущено (нет слоя) " (itoa skipped))
                        ""
                      )))

      (if (= (length layers) 0)
        (prompt "\nLCM: не найдено ни одного слоя цикла.")
        (progn
          (initget "Отчет Рисовать")
          (setq ans (getkword "\nLCM: режим [Отчет/Рисовать] <Отчет>: "))
          (setq draw-flag (= ans "Рисовать"))

          (setq result (lcm:chain-run layers draw-flag))

          (if result
            (progn
              (prompt (strcat "\nLCM: циклов пройдено: " (itoa (nth 0 result))
                              ", точек в последнем: " (itoa (nth 1 result))
                              ", пар: " (itoa (nth 2 result))
                              ", нарисовано: " (itoa (nth 6 result))))
              (prompt (strcat "\nLCM: отчёт: " (nth 7 result)))
              (prompt (strcat "\nLCM: таблица идентичности: " (nth 8 result)))
            )
            (prompt "\nLCM: цепочка не выполнена.")
          )
        )
      )
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; Слои между LAYER_ZERO и LAYER_LAST из настроек
;;; ------------------------------------------------------------

(defun lcm:chain-layers-from-settings ( / zero last base n1 n2 i name layers)
  (setq zero (lcm:geo-setting "LAYER_ZERO" ""))
  (setq last (lcm:geo-setting "LAYER_LAST" ""))

  (if (or (= zero "") (= last ""))
    nil
    (progn
      (setq base (lcm:chain-base zero))
      (setq n1 (atoi (substr zero (1+ (strlen base)))))
      (setq n2 (atoi (substr last (1+ (strlen base)))))
      (setq layers '())
      (setq i n1)
      (while (<= i n2)
        (setq name (strcat base (itoa i)))
        (if (tblsearch "LAYER" name)
          (setq layers (append layers (list name)))
        )
        (setq i (1+ i))
      )
      layers
    )
  )
)


;;; Печать сводки по цепочке
(defun lcm:chain-print-summary (result)
  (if result
    (progn
      (prompt (strcat "\nLCM: циклов пройдено: " (itoa (nth 0 result))
                      ", точек в последнем: " (itoa (nth 1 result))
                      ", пар: " (itoa (nth 2 result))
                      ", нарисовано: " (itoa (nth 6 result))))
      (prompt (strcat "\nLCM: отчёт: " (nth 7 result)))
      (prompt (strcat "\nLCM: таблица идентичности: " (nth 8 result)))
    )
    (prompt "\nLCM: цепочка не выполнена.")
  )
  (princ)
)


;;; ------------------------------------------------------------
;;; LCMAUTO: цепочка по настройкам, только отчёт (без изменений чертежа)
;;; ------------------------------------------------------------

(defun C:LCMAUTO ( / layers result)
  (setq layers (lcm:chain-layers-from-settings))

  (if (not layers)
    (prompt "\nLCM: в настройках нет слоёв LAYER_ZERO / LAYER_LAST. Сохраните настройки командой LCM.")
    (progn
      (prompt (strcat "\nLCMAUTO: циклов " (itoa (length layers))
                      ", режим только отчёт."))
      (setq result (lcm:chain-run layers nil))
      (lcm:chain-print-summary result)
    )
  )

  (princ)
)


;;; ------------------------------------------------------------
;;; LCMAUTODRAW: то же, но с отрисовкой стрелок
;;; ------------------------------------------------------------

(defun C:LCMAUTODRAW ( / layers result)
  (setq layers (lcm:chain-layers-from-settings))

  (if (not layers)
    (prompt "\nLCM: в настройках нет слоёв LAYER_ZERO / LAYER_LAST. Сохраните настройки командой LCM.")
    (progn
      (prompt (strcat "\nLCMAUTODRAW: циклов " (itoa (length layers))
                      ", режим с отрисовкой."))
      (setq result (lcm:chain-run layers T))
      (lcm:chain-print-summary result)
    )
  )

  (princ)
)


(princ "\n=== LCM Chain loaded: LCMCHAIN, LCMAUTO, LCMAUTODRAW ===")
(princ)
