---
name: lcm-arrows-report
description: Полный цикл LayerCycleManager в AutoCAD — нарисовать стрелки отклонений между двумя циклами, построить ведомость отклонений (LCMDEV) и заполнить Excel «Уч. 6 шпунт.xlsx». Использовать на просьбы «отрисуй стрелки», «построй ведомость», «заполни таблицу отклонений», «сделай полный цикл».
---

# LayerCycleManager: стрелки → ведомость → Excel

Процедура проверена 30.10.2026 на чертеже «Уч.6 тест.dwg» (11 стрелок → 11 марок в таблице и в Excel).
10.11.2026 пройдена целиком через `tools/bridge.py` трижды; Excel теперь дописывает блоки справа, а не перезаписывает.

## Где что лежит

Проект: `C:\Users\Durkin.RI\Desktop\Project DSH Test\LayerCycleManager` (далее `$W`).

| Файл | Назначение |
|---|---|
| `tools/bridge.py` | запуск моста в песочнице: `py -3 tools\bridge.py <глагол> …` (прокси к `cad_bridge.ps1`) |
| `tools/cad_bridge.ps1` | сам мост к запущенному AutoCAD (`status`, `eval`, `load`, `shot`, `undo`, `report`) |
| `lcm_table.lsp` | ведомость отклонений: `(lcm:dev-table слойA слойB радиус)` |
| `tools/lcm_table_to_xlsx.py` | перенос таблицы в Excel: новый блок вплотную справа от существующих |
| `tools/lcm_cells_to_json.py` | ячейки ведомости из `_tmp/tbl_cells.txt` → `reports/_table_cells.json` |
| `reports/_table_cells.json` | промежуточная выгрузка ячеек таблицы |
| `tools/lcm_cycle.py` | весь цикл одной командой: `draw`, `table`, `xlsx`, `all`; настройки читает из `_tmp\lcm_run.cfg` |
| `..\_tmp\lcm_run.cfg` | временные настройки прогона (слои, масштаб, цвет, книга); создаётся под задачу, удаляется в шаге 10 |

## Как обращаться к AutoCAD

Все команды к AutoCAD — `py -3 "$W\tools\bridge.py" …`. Прямой вызов `.ps1` из песочницы DSH падает с `AuthorizationManager check failed` (процессы низкой целостности не исполняют сценарии), поэтому мост запускается обёрткой — подробности в `docs/research/04-cad-bridge.md`.

- Вызовы к живому AutoCAD требуют полного доступа к системе: либо режим сессии с полным доступом / «Auto review», либо разовое расширение (`sandbox_permissions: danger-full-access`) с пояснением.
- Команды без AutoCAD (`report`) работают и без расширения.
- **Длинные LISP-выражения** пишутся файлом в `_tmp\` и передаются как `eval "@$W\..\_tmp\имя.lsp"`: кавычки внутри не экранируются, командная строка их не рвёт.

## Быстрый режим: настройки в файле, цикл одной командой

С 10.11.2026 шаги 0–8 умеет выполнять `tools/lcm_cycle.py`, а параметры он берёт из
**временного файла** `_tmp\lcm_run.cfg` в корне рабочего пространства. Агент делает два
действия вместо восьми: пишет файл под задачу и запускает скрипт без аргументов.

`C:\Users\Durkin.RI\Desktop\Project DSH Test\_tmp\lcm_run.cfg`:

```ini
layer_a=Уч.4 Цикл 0
layer_b=Уч.4 Цикл 58
radius=5
scale=70
text_height=2
color=10          ; 1..255 — номер цвета ACI, by_layer — цвет по слою
force=1
excel=Уч.4 шпунт.xlsx
cycle=58
```

```powershell
py -3 "$W\tools\lcm_cycle.py" all
py -3 "$W\tools\lcm_cycle.py" all --show-config     # что прочитано, без AutoCAD
py -3 "$W\tools\lcm_cycle.py" all --dry-run         # только отчёт, без отрисовки
```

| Ключ файла | Смысл | По умолчанию |
|---|---|---|
| `layer_a`, `layer_b` | слои нулевого и последнего цикла | обязательны |
| `radius` | радиус сопоставления пар | 5 |
| `scale` | масштаб стрелок | значение LCM |
| `text_height` | высота текста | значение LCM |
| `color` | номер ACI (`10` — красный) или `by_layer` | `by_layer` |
| `force` | перерисовывать, если слой B занят (`1`/`0`) | `0` |
| `excel` | книга для блока ведомости | «Уч. 6 шпунт.xlsx» |
| `cycle` | номер цикла в шапке нового блока Excel | следующий за последним блоком |

Правила: аргументы командной строки **важнее** файла (`--scale 400` перебьёт `scale=70`);
файл создаётся под задачу и удаляется в шаге 10; если его нет — скрипт работает только
от аргументов, как раньше. Временный файл — не настройки LCM: диалог `LCM` он не меняет.

| Фаза | Что делает |
|---|---|
| `status` | AutoCAD запущен, чертёж, загружен ли LCM |
| `draw` | сопоставить и нарисовать; `--dry-run` — только отчёт, `--force` — перерисовать |
| `table` | удалить старую и построить ведомость `LCMDEV` |
| `xlsx` | ячейки → блок в Excel (по умолчанию «Уч. 6 шпунт.xlsx», `--excel путь` — другая книга) |
| `all` | `draw` → `table` → `xlsx`; при сбое шага следующие не выполняются |

Внутри: проверка слоёв, отказ при занятом слое B (без `--force`), `undo mark`/`undo back`
при расхождении числа стрелок, восстановление `SCALE`/`TEXT_HEIGHT`/`BY_LAYER`, сверка
`LINE`/`TEXT`/`SOLID` с числом пар, резервная копия Excel и проверка блоков.


## Шаг 0. Проверить обстановку

```powershell
$W = "C:\Users\Durkin.RI\Desktop\Project DSH Test\LayerCycleManager"
py -3 "$W\tools\bridge.py" status
```

Ожидается: AutoCAD запущен, открыт нужный DWG, `LCMVersion` не пустой. Если LCM не загружен — `py -3 "$W\tools\bridge.py" load "$W\lcm_main.lsp"`.

Слои берутся из чертежа как есть: в «Уч.6» это `Уч 6 Цикл 0` и `Уч 6 Цикл 1` — **без точки** после «Уч» (точка есть только в имени файла чертежа).

## Шаг 1. Параметры

Спросить у пользователя, если не названы. Затем записать их в `_tmp\lcm_run.cfg` (см.
«Быстрый режим») — это и есть входные данные прогона. Значения по умолчанию (типичные
для «Уч.6»):

| Параметр | Значение | Ключ настройки LCM |
|---|---|---|
| Слои | `Уч 6 Цикл 0` → `Уч 6 Цикл 1` | `LAYER_ZERO`, `LAYER_LAST` |
| Режим | по координатам, радиус 5 | аргумент `r-max` |
| Масштаб стрелок | 400 | `SCALE` |
| Высота текста | 2 | `TEXT_HEIGHT` |
| Цвет | по слою | `BY_LAYER` = 1 |

## Шаг 2. Маркер отката

```powershell
py -3 "$W\tools\bridge.py" undo mark
```

## Шаг 3. Отрисовка стрелок

Настройки подменяются только в памяти: файл настроек не сохраняется, после отрисовки значения возвращаются.

`_tmp\draw.lsp`:

```lisp
(progn (setq lcm:old-scale (lcm:config-get "SCALE") lcm:old-th (lcm:config-get "TEXT_HEIGHT") lcm:old-bl (lcm:config-get "BY_LAYER")) (lcm:config-set "SCALE" 400.0) (lcm:config-set "TEXT_HEIGHT" 2.0) (lcm:config-set "BY_LAYER" 1) (lcm:geo-run "Уч 6 Цикл 0" "Уч 6 Цикл 1" 5.0 T))
```

`_tmp\restore.lsp`:

```lisp
(progn (lcm:config-set "SCALE" lcm:old-scale) (lcm:config-set "TEXT_HEIGHT" lcm:old-th) (lcm:config-set "BY_LAYER" lcm:old-bl) "restored")
```

```powershell
py -3 "$W\tools\bridge.py" eval "@C:\...\_tmp\draw.lsp"
py -3 "$W\tools\bridge.py" eval "@C:\...\_tmp\restore.lsp"
```

Результат отрисовки — список, где первый элемент = число нарисованных пар.

**Если на слое B уже есть стрелки** (`LINE`/`TEXT`/`SOLID` > 0), сначала уточнить у пользователя, перерисовывать ли. При «да» — удалить старые стрелки (только `LINE`, `TEXT`, `SOLID` этого слоя, `POINT` не трогать) либо откатиться на маркер `undo` от прошлой отрисовки.

## Шаг 4. Проверить, что стрелки нарисованы

`_tmp\counts.lsp`:

```lisp
(progn (setq r nil) (foreach L (list "Уч 6 Цикл 0" "Уч 6 Цикл 1") (setq r (cons (cons L (mapcar (function (lambda (ty) (if (setq s (ssget "_X" (list (cons 0 ty) (cons 8 L)))) (sslength s) 0))) (list "POINT" "LINE" "TEXT" "SOLID"))) r))) r)
```

```powershell
py -3 "$W\tools\bridge.py" eval "@C:\...\_tmp\counts.lsp"
```

`TEXT`, `LINE`, `SOLID` слоя B должны совпадать по количеству и быть равны числу пар. Слой A содержит `TEXT` — это подписи точек, они там были до отрисовки.

## Шаг 5. Ведомость отклонений

Старую таблицу удалить, новую построить — `_tmp\table.lsp`:

```lisp
(progn (setq n 0) (if (setq s (ssget "_X" (list (cons 0 "ACAD_TABLE")))) (progn (setq i 0) (while (< i (sslength s)) (entdel (ssname s i)) (setq i (1+ i) n (1+ n))))) (lcm:dev-table "Уч 6 Цикл 0" "Уч 6 Цикл 1" 5.0))
```

```powershell
py -3 "$W\tools\bridge.py" eval "@C:\...\_tmp\table.lsp"
```

Возврат `(число марок с отклонениями, всего марок, точка вставки)`.

## Шаг 6. Выгрузить ячейки таблицы

`_tmp\export.lsp` — пишет ячейки в `_tmp\tbl_cells.txt` (строка `r;c;текст`):

```lisp
(progn (setq e (ssname (ssget "_X" (list (cons 0 "ACAD_TABLE"))) 0) o (vlax-ename->vla-object e) f (open "C:/ПУТЬ/К/ПРОЕКТУ/_tmp/tbl_cells.txt" "w") r 0) (repeat (vla-get-Rows o) (setq c 0) (repeat 4 (write-line (strcat (itoa r) ";" (itoa c) ";" (vla-GetText o r c)) f) (setq c (1+ c))) (setq r (1+ r))) (close f) (list r "ok"))
```

```powershell
py -3 "$W\tools\bridge.py" eval "@C:\...\_tmp\export.lsp"
py -3 "$W\tools\lcm_cells_to_json.py" "C:\...\_tmp\tbl_cells.txt" "$W\reports\_table_cells.json"
```

Путь в `open` внутри LISP — прямой слэш и кириллица недопустимы: писать ASCII-путь.

## Шаг 7. Заполнить Excel

```powershell
$py = "C:\Users\Durkin.RI\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
Copy-Item "$W\Уч. 6 шпунт.xlsx" "$W\reports\_backup_uch6_shpunt.xlsx" -Force
& $py "$W\tools\lcm_table_to_xlsx.py"
```

Скрипт: **дописывает новый блок вплотную справа от существующих** — первый свободный участок из 4 столбцов (`A:D` → `E:H` → `I:L` → `M:P`), существующие блоки не трогает. В шапке номер цикла на 1 больше последнего блока, дата — сегодняшняя. Отклонения подставляет по маркам из таблицы AutoCAD, где данных нет — прочерк, `D` — формула по столбцам своего блока.

## Шаг 8. Проверить результат

```powershell
& $py -c "import openpyxl; ws=openpyxl.load_workbook(r'$W\Уч. 6 шпунт.xlsx').active; print(ws.dimensions, sorted(str(m) for m in ws.merged_cells.ranges)); print([(ws.cell(r,c).value, ws.cell(r,c+1).value) for c in range(5, ws.max_column, 4) for r in range(4, ws.max_row+1) if ws.cell(r,c).value not in (None,'-')])"
```

Ожидается: у каждого блока объединения вида `<X>1:<X>3`, `<X+1>1:<X+3>1`, `<X+1>2:<X+3>2`; марок с числами в новом блоке столько же, сколько стрелок.

## Шаг 9. Завершение

- **Чертёж не сохранять** — это делает пользователь сам.
- Сообщить: сколько стрелок нарисовано, сколько марок заполнено, в каком блоке, какой цикл и дата в Excel.
- Откат отрисовки — `py -3 "$W\tools\bridge.py" undo back`.
- Визуальная проверка: `py -3 "$W\tools\bridge.py" shot -Out "$W\reports\_tmp_arrows.png"`.

## Шаг 10. Убрать за собой (обязательно)

`reports/` — рабочая свалка агента: скриншоты, временный JSON, резервные копии Excel. После выполнения задачи её нужно чистить, иначе папка за несколько прогонов вырастает в мегабайты.

```powershell
# 1. временные файлы агента — удалить все (включая _tmp проекта)
Remove-Item "..\_tmp\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$W\reports\*.png" -Force -ErrorAction SilentlyContinue
Remove-Item "$W\reports\_table_cells.json" -Force -ErrorAction SilentlyContinue
Remove-Item "$W\reports\*.tmp" -Force -ErrorAction SilentlyContinue
Remove-Item "$W\reports\_write_test.txt" -Force -ErrorAction SilentlyContinue
Remove-Item "$W\reports\agent_dump*.csv" -Force -ErrorAction SilentlyContinue

# 2. резервные копии Excel — оставить только самую свежую
Get-ChildItem "$W\reports\_backup_uch6_shpunt*.xlsx" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 | Remove-Item -Force

# 3. отчёты LCM — оставить по одному самому свежему на каждую пару слоёв и тип
$csv = Get-ChildItem "$W\reports\*.csv"
$csv | Group-Object { ($_.BaseName -replace '_\d{8,14}$','') } | ForEach-Object {
  $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1
} | Remove-Item -Force
```

Правила уборки (пользователь подтвердил 05.11.2026 — **все временные файлы и отчёты удаляются при завершении работы**):

1. **Удалять без вопросов:** `..\_tmp\*`, `reports/*.png`, `reports/_table_cells.json`, `reports/*.tmp`, `reports/_write_test.txt`, `reports/agent_dump*.csv` — это артефакты агента, восстанавливать нечего.
2. **Резервные копии Excel:** оставлять **одну** самую свежую `_backup_uch6_shpunt*.xlsx`, предыдущие удалять.
3. **Отчёты LCM** (`lcm_geo_*`, `lcm_chain_*`, `lcm_check_*`, `lcm_points_*`, `lcm_pair_*`) — временные: в конце работы оставить **по одному самому свежему на каждую пару слоёв и каждый тип**, дубли удалить.
4. Отчёты за текущую задачу, если пользователь их ещё не просмотрел, удалять не раньше, чем закончится задача.
5. В отчёте о работе указывать, сколько файлов удалено и сколько осталось — это подтверждает, что уборка прошла.
6. Если в сессии включена проверка авторизации, уборку надёжнее подтвердить формулировкой в самом запросе: «… и убери за собой» — иначе проверяющий спросит про удаление отдельно.

Целевое состояние папки после уборки: **~15–20 файлов, < 50 КБ** (свежие отчёты по парам + одна резервная копия Excel).

## Правила и грабли (проверено)

1. **Длинные LISP-выражения не отправлять в `SendCommand`** — командная строка обрывает их, и AutoCAD зависает, ожидая ввода. Держать `eval` короче ~500 символов; длинное писать файлом и передавать как `eval "@файл"`.
2. **`T` нельзя использовать как имя переменной** в AutoLISP — это константа (ошибка «неверный объект для внедрения: T»).
3. **Кодировки:** `.lsp` — Windows-1251 + CRLF; `.ps1` — UTF-8 с BOM; `.md`, `.py` — UTF-8, переводы строк CRLF.
4. **Не вызывать интерактивные** `LCM`, `LCMCHAIN`, `LCMGEOFILL` — они ждут ввода. Только функции: `lcm:geo-run`, `lcm:chain-run`, `lcm:dev-table`.
5. **Допуск примыкания стрелки к точке — 0.1** (`lcm:dev-tolerance`). При 1.0 соседняя марка забирала чужую стрелку.
6. **Отклонения берутся из нарисованных стрелок**, а не из памяти LCM: сканируется слой последнего цикла, `LINE` чьё начало совпадает с точкой слоя A; `D` — из подписи у острия.
7. **Ведомость строит строки по всем маркам слоя A**, у марок без стрелки — прочерк.
8. **Excel**: блоки идут вплотную справа (`A:D`, `E:H`, `I:L`, …), старые не перезаписываются, `D` — формула `=(F*F+G*G)^0.5` по своим столбцам, включён `fullCalcOnLoad`; резервная копия файла кладётся в `reports/`.
9. **Перед правкой модулей** — `py -3 tools/lisp_check.py lcm_*.lsp` и `py -3 tools/ref_check.py`; перед коммитом — `py -3 tools/check_all.py` (в русской Windows `python` в PATH часто заглушка Microsoft Store — `py -3` работает всегда).
10. **COM работает только с уже запущенным AutoCAD**: мост не запускает новый экземпляр (иначе появляется пустое «Чертеж1.dwg» и все вызовы уходят в него).
11. **`bridge.py` берёт корень проекта из своего расположения**: `$PSScriptRoot` внутри scriptblock пуст, обёртка подставляет путь сама. Переносить `cad_bridge.ps1` и `bridge.py` нужно вместе.
12. **Слои ищутся по точному имени**: `Уч 6 Цикл 0`, а не `Уч.6 Цикл 0`. Перед отрисовкой проверить список: `py -3 "$W\tools\bridge.py" layers`.
13. **`unwind-protect` в AutoLISP 2018 отсутствует** («no function definition»). Возврат настроек делать так: `(setq r (vl-catch-all-apply 'lcm:geo-run ...))`, сразу после — восстановить настройки, затем проверить `vl-catch-all-error-p`.
14. **Мост: файл результата может быть ещё открыт AutoCAD** — быстрые последовательные `eval` падали с «file is being used by another process». Исправлено в `cad_bridge.ps1`: чтение с повтором до 5 с.

## Быстрый режим («отрисуй стрелки»)

Если пользователь не уточняет параметры — брать слой A/B из настроек LCM (`LAYER_ZERO`, `LAYER_LAST`), радиус 5, масштаб 400, высота 2, цвет по слою, и выполнять шаги 2 → 8 без вопросов. Уборку (шаг 10) выполнять всегда, если пользователь не сказал её не делать.
