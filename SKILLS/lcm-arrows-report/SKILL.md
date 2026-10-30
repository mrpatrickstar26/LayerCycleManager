---
name: lcm-arrows-report
description: Полный цикл LayerCycleManager в AutoCAD — нарисовать стрелки отклонений между двумя циклами, построить ведомость отклонений (LCMDEV) и заполнить Excel «Уч. 6 шпунт.xlsx». Использовать на просьбы «отрисуй стрелки», «построй ведомость», «заполни таблицу отклонений», «сделай полный цикл».
---

# LayerCycleManager: стрелки → ведомость → Excel

Процедура проверена 30.10.2026 на чертеже «Уч.6 тест.dwg» (11 стрелок → 11 марок в таблице и в Excel).

## Где что лежит

Проект: `C:\Users\Durkin.RI\Desktop\Project DSH Test\LayerCycleManager` (далее `$W`).

| Файл | Назначение |
|---|---|
| `tools/cad_bridge.ps1` | мост к запущенному AutoCAD (`status`, `eval`, `load`, `shot`, `undo`) |
| `lcm_table.lsp` | ведомость отклонений: `(lcm:dev-table слойA слойB радиус)` |
| `tools/lcm_table_to_xlsx.py` | перенос таблицы в Excel (блок E:H) |
| `reports/_table_cells.json` | промежуточная выгрузка ячеек таблицы |

Все команды запускать через `pwsh` с `sandbox_permissions: danger-full-access` (COM к AutoCAD и запись в проект).

## Шаг 0. Проверить обстановку

```powershell
$W = "C:\Users\Durkin.RI\Desktop\Project DSH Test\LayerCycleManager"
& "$W\tools\cad_bridge.ps1" status
```

Ожидается: AutoCAD запущен, открыт нужный DWG, `LCMVersion` не пустой. Если LCM не загружен — `& "$W\tools\cad_bridge.ps1" load "$W\lcm_main.lsp"`.

## Шаг 1. Параметры

Спросить у пользователя, если не названы. Значения по умолчанию (типичные для «Уч.6»):

| Параметр | Значение | Ключ настройки LCM |
|---|---|---|
| Слои | `Уч 6 Цикл 0` → `Уч 6 Цикл 1` | `LAYER_ZERO`, `LAYER_LAST` |
| Режим | по координатам, радиус 5 | аргумент `r-max` |
| Масштаб стрелок | 400 | `SCALE` |
| Высота текста | 2 | `TEXT_HEIGHT` |
| Цвет | по слою | `BY_LAYER` = 1 |

## Шаг 2. Маркер отката

```powershell
& "$W\tools\cad_bridge.ps1" undo mark
```

## Шаг 3. Отрисовка стрелок

Настройки подменяются только в памяти: файл настроек не сохраняется, после отрисовки значения возвращаются.

```powershell
& "$W\tools\cad_bridge.ps1" eval '(progn (setq lcm:old-scale (lcm:config-get "SCALE") lcm:old-th (lcm:config-get "TEXT_HEIGHT") lcm:old-bl (lcm:config-get "BY_LAYER")) (lcm:config-set "SCALE" 400.0) (lcm:config-set "TEXT_HEIGHT" 2.0) (lcm:config-set "BY_LAYER" 1) (lcm:geo-run "Уч 6 Цикл 0" "Уч 6 Цикл 1" 5.0 T))'
& "$W\tools\cad_bridge.ps1" eval '(progn (lcm:config-set "SCALE" lcm:old-scale) (lcm:config-set "TEXT_HEIGHT" lcm:old-th) (lcm:config-set "BY_LAYER" lcm:old-bl) "restored")'
```

Результат вызова — список, где первый элемент = число нарисованных пар.

**Если на слое B уже есть стрелки** (`LINE`/`TEXT`/`SOLID` > 0), сначала уточнить у пользователя, перерисовывать ли. При «да» — удалить старые стрелки (только `LINE`, `TEXT`, `SOLID` этого слоя, `POINT` не трогать) либо откатиться на маркер `undo` от прошлой отрисовки.

## Шаг 4. Проверить, что стрелки нарисованы

```powershell
& "$W\tools\cad_bridge.ps1" eval '(mapcar (function (lambda (typ) (cons typ (if (setq s (ssget "_X" (list (cons 0 typ) (cons 8 "Уч 6 Цикл 1")))) (sslength s) 0)))) (list "POINT" "TEXT" "LINE" "SOLID"))'
```

`TEXT`, `LINE`, `SOLID` должны совпадать по количеству и быть равны числу пар.

## Шаг 5. Ведомость отклонений

Старую таблицу удалить, новую построить:

```powershell
& "$W\tools\cad_bridge.ps1" eval '(progn (setq n 0) (if (setq s (ssget "_X" (list (cons 0 "ACAD_TABLE")))) (progn (setq i 0) (while (< i (sslength s)) (entdel (ssname s i)) (setq i (1+ i) n (1+ n))))) (lcm:dev-table "Уч 6 Цикл 0" "Уч 6 Цикл 1" 5.0))'
```

Возврат `(число марок с отклонениями, всего марок, точка вставки)`.

## Шаг 6. Выгрузить ячейки таблицы

```powershell
$a = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
$ms = $a.ActiveDocument.ModelSpace
$tbl = $null; foreach ($e in $ms) { if ($e.ObjectName -eq 'AcDbTable') { $tbl = $e; break } }
$rows = $tbl.Rows; $out = @()
for ($r = 0; $r -lt $rows; $r++) { $row = @(); for ($c = 0; $c -lt 4; $c++) { $row += [string]$tbl.GetText($r, $c) }; $out += ,$row }
$out | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$W\reports\_table_cells.json" -Encoding UTF8
```

## Шаг 7. Заполнить Excel

```powershell
$py = "C:\Users\Durkin.RI\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
Copy-Item "$W\Уч. 6 шпунт.xlsx" "$W\reports\_backup_uch6_shpunt.xlsx" -Force
& $py "$W\tools\lcm_table_to_xlsx.py"
```

Скрипт: копирует первый блок вплотную справа (E:H), увеличивает номер цикла на 1, ставит сегодняшнюю дату, подставляет отклонения по маркам из таблицы AutoCAD, где данных нет — прочерк. Первый блок (A:D) не меняется.

## Шаг 8. Проверить результат

```powershell
& $py -c "import openpyxl; ws=openpyxl.load_workbook(r'$W\Уч. 6 шпунт.xlsx').active; print(ws.dimensions, sorted(str(m) for m in ws.merged_cells.ranges)); print([(ws.cell(r,5).value, ws.cell(r,6).value, ws.cell(r,7).value, ws.cell(r,8).value) for r in range(4, ws.max_row+1) if ws.cell(r,6).value not in (None,'-')])"
```

Ожидается: объединения `E1:E3`, `F1:H1`, `F2:H2`; заполненные строки совпадают с числом стрелок.

## Шаг 9. Завершение

- **Чертёж не сохранять** — это делает пользователь сам.
- Сообщить: сколько стрелок нарисовано, сколько марок заполнено, какой цикл и дата в Excel.
- Откат отрисовки — `& "$W\tools\cad_bridge.ps1" undo back`.
- Визуальная проверка: `& "$W\tools\cad_bridge.ps1" shot -Out "$W\reports\arrows_drawn.png"`.

## Правила и грабли (проверено)

1. **Длинные LISP-выражения не отправлять в `SendCommand`** — командная строка обрывает их, и AutoCAD зависает, ожидая ввода. Держать `eval` короче ~500 символов; длинное оформлять как функцию в модуле и вызывать коротко.
2. **`T` нельзя использовать как имя переменной** в AutoLISP — это константа (ошибка «неверный объект для внедрения: T»).
3. **Кодировки:** `.lsp` — Windows-1251 + CRLF; `.ps1` — UTF-8 с BOM; `.md` и `.py` — UTF-8.
4. **Не вызывать интерактивные** `LCM`, `LCMCHAIN`, `LCMGEOFILL` — они ждут ввода. Только функции: `lcm:geo-run`, `lcm:chain-run`, `lcm:dev-table`.
5. **Допуск примыкания стрелки к точке — 0.1** (`lcm:dev-tolerance`). При 1.0 соседняя марка забирала чужую стрелку.
6. **Отклонения берутся из нарисованных стрелок**, а не из памяти LCM: сканируется слой последнего цикла, `LINE` чьё начало совпадает с точкой слоя A; `D` — из подписи у острия.
7. **Ведомость строит строки по всем маркам слоя A**, у марок без стрелки — прочерк.
8. **Excel**: блок ставится вплотную (E:H), `D` — формула `=(F*F+G*G)^0.5`, включён `fullCalcOnLoad`; резервная копия файла кладётся в `reports/`.
9. **Перед правкой модулей** — `python tools/lisp_check.py lcm_*.lsp` и `python tools/ref_check.py`.
10. **COM работает только с уже запущенным AutoCAD**: мост не запускает новый экземпляр (иначе появляется пустое «Чертеж1.dwg» и все вызовы уходят в него).

## Быстрый режим («отрисуй стрелки»)

Если пользователь не уточняет параметры — брать слой A/B из настроек LCM (`LAYER_ZERO`, `LAYER_LAST`), радиус 5, масштаб 400, высота 2, цвет по слою, и выполнять шаги 2 → 8 без вопросов.
