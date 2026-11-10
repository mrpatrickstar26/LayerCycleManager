#!/usr/bin/env python3
"""Ячейки ведомости LCMDEV -> JSON для lcm_table_to_xlsx.py.

На входе — файл `_tmp/tbl_cells.txt`, который пишет LISP-выражение из скилла
`lcm-arrows-report` (шаг 6): по строке на ячейку вида `строка;столбец;текст`.
На выходе — `reports/_table_cells.json`: массив строк, по 4 значения в каждой.

Запуск:
    py -3 tools/lcm_cells_to_json.py _tmp/tbl_cells.txt reports/_table_cells.json
"""

import json
import pathlib
import sys

COLUMNS = 4


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    source = pathlib.Path(sys.argv[1])
    target = pathlib.Path(sys.argv[2])
    if not source.is_file():
        print("не найден файл ячеек: %s" % source)
        return 1

    cells = {}
    for line in source.read_text(encoding="cp1251").splitlines():
        if not line.strip():
            continue
        row, column, text = line.split(";", 2)
        cells.setdefault(int(row), {})[int(column)] = text

    count = max(cells) + 1 if cells else 0
    table = [[cells.get(r, {}).get(c, "") for c in range(COLUMNS)] for r in range(count)]
    target.write_text(json.dumps(table, ensure_ascii=False), encoding="utf-8")
    print("строк: %d -> %s" % (count, target))
    return 0


if __name__ == "__main__":
    sys.exit(main())
