#!/usr/bin/env python3
"""lcm_cycle.py — один вызов вместо цепочки шагов скилла lcm-arrows-report.

Зачем: раньше агент делал 8 отдельных вызовов (status, два файла .lsp,
undo mark, eval, restore, counts) и 16–18 на полный цикл. Здесь те же шаги
выполняет скрипт: он держит промежуточные данные (число пар, число объектов,
пути) и сам решает, продолжать ли дальше, поэтому модели достаточно одного
вызова.

Фазы:

    status  — AutoCAD запущен, какой чертёж, загружен ли LCM
    draw    — сопоставить и нарисовать стрелки (--dry-run: только отчёт)
    table   — удалить старую и построить ведомость отклонений (LCMDEV)
    xlsx    — ячейки таблицы -> новый блок в «Уч. 6 шпунт.xlsx»
    all     — draw -> table -> xlsx

Настройки:

    по умолчанию — _tmp/lcm_run.cfg в папке рядом с проектом (плоский
    key=value, комментарии с # или ;). Ключи: layer_a, layer_b, radius,
    scale, text_height, color, force, excel. Аргументы командной строки
    важнее файла; --config PATH — другой файл, --show-config — показать
    итоговые значения и выйти, не обращаясь к AutoCAD.

Безопасность:

    * перед изменениями ставится undo mark, при расхождении количеств — undo back;
    * SCALE / TEXT_HEIGHT / BY_LAYER / ACI подменяются только в памяти и
      возвращаются через unwind-protect, даже если отрисовка упала;
    * Excel пишется только после успешной проверки; перед записью — резервная копия;
    * стрелки на слое B при --force удаляются (LINE/TEXT/SOLID), точки (POINT) не трогаются.

Примеры:

    py -3 tools/lcm_cycle.py status
    py -3 tools/lcm_cycle.py draw  --layer-a "Уч 6 Цикл 0" --layer-b "Уч 6 Цикл 1" --dry-run
    py -3 tools/lcm_cycle.py all   --layer-a "Уч 6 Цикл 0" --layer-b "Уч 6 Цикл 1" --force

Коды возврата: 0 — успех, 1 — остановка (проверка не прошла), 2 — ошибка запуска.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
BRIDGE = TOOLS / "bridge.py"
REPORTS = ROOT / "reports"
TEMP = Path(tempfile.gettempdir()) / "lcm_cycle"
DEFAULT_CONFIG = ROOT.parent / "_tmp" / "lcm_run.cfg"
DEFAULT_CONFIG_LABEL = "_tmp/lcm_run.cfg"

ARROW_TYPES = ("LINE", "TEXT", "SOLID")


# ── оболочка: вывод и запуск моста ───────────────────────────────────────────

def setup_stdout() -> None:
    """UTF-8 для вывода: русская консоль иначе пишет cp1251 и ломает кириллицу."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def decode(raw: bytes) -> str:
    """Вывод PowerShell: UTF-8, затем cp1251/cp866 — что первым распозналось."""
    for encoding in ("utf-8", "cp1251", "cp866"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def run_bridge(*args: str, timeout: int = 240) -> tuple[int, str, str]:
    """Запуск tools/bridge.py; возвращает (код, stdout, stderr)."""
    command = [sys.executable, str(BRIDGE)] + [str(a) for a in args]
    try:
        result = subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 1, "", f"мост не ответил за {timeout} с — вероятно, AutoCAD занят диалогом"
    return result.returncode, decode(result.stdout).strip(), decode(result.stderr).strip()


def lisp_str(text: str) -> str:
    """Строковый литерал AutoLISP (кавычки экранируются)."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lisp_num(value: float) -> str:
    """Дробное число в виде, который понимает AutoLISP (точка, а не запятая)."""
    return repr(float(value))


def lisp_int(value: int) -> str:
    """Целое число для AutoLISP: ACI должен остаться целым, а не 10.0."""
    return str(int(value))


def eval_lisp(expression: str) -> tuple[int, str]:
    """Выполнить LISP-выражение через временный файл (длинные строки не рвутся)."""
    TEMP.mkdir(parents=True, exist_ok=True)
    path = TEMP / "expr.lsp"
    path.write_text(expression, encoding="utf-8")
    code, out, err = run_bridge("eval", f"@{path}")
    if code != 0:
        return code, (err or out or "ошибка моста")
    return 0, out


def head_numbers(text: str) -> list[float]:
    """Числа из начала ответа до первой закрывающей скобки.

    Строка отчёта в конце ответа (путь с цифрами) в разбор не попадает.
    """
    cut = text.split(")")[0]
    return [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", cut)]


def field(text: str, name: str) -> str:
    """Значение строки «Имя : значение» из вывода status."""
    for line in text.splitlines():
        if line.strip().lower().startswith(name.lower()):
            parts = line.split(":", 1)
            return parts[1].strip() if len(parts) > 1 else ""
    return ""


# ── настройки: файл _tmp/lcm_run.cfg и аргументы ────────────────────────────

KNOWN_CONFIG_KEYS = ("layer_a", "layer_b", "radius", "scale", "text_height",
                     "color", "force", "excel", "cycle")
TRUE_WORDS = {"1", "true", "yes", "да"}
FALSE_WORDS = {"0", "false", "no", "нет"}
_MISSING = object()


class ConfigProblem(Exception):
    """Ошибка файла настроек с готовым текстом «файл:строка: …»."""


class Settings:
    """Итоговые настройки: значения, источники, цвет и путь к файлу."""

    def __init__(self, label: str, found: bool) -> None:
        self.label = label
        self.found = found
        self.values: dict[str, object] = {}
        self.sources: dict[str, str] = {}
        self.by_layer = 1.0
        self.aci: int | None = None

    def value(self, name: str):
        return self.values.get(name)


def parse_color(value: str, filename: str, line: int) -> int | str:
    """color: by_layer / пусто -> by_layer, целое 1..255 -> ACI."""
    if not value or value.lower() == "by_layer":
        return "by_layer"
    if re.fullmatch(r"[+-]?\d+", value):
        number = int(value)
        if 1 <= number <= 255:
            return number
    raise ConfigProblem(
        f"{filename}:{line}: 'color' ожидает 1..255 или by_layer")


def read_config(path: Path, label: str) -> dict[str, object]:
    """Прочитать плоский key=value; ошибки — ConfigProblem без трейсбека."""
    try:
        text = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        raise ConfigProblem(f"{label}: файл не в кодировке UTF-8")
    except OSError as exc:
        raise ConfigProblem(f"{label}: не удалось прочитать файл ({exc})")

    values: dict[str, object] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if "=" not in line:
            raise ConfigProblem(
                f"{label}:{number}: неизвестный ключ '{line}'")
        raw_key, raw_value = line.split("=", 1)
        raw_key = raw_key.strip()
        key = raw_key.lower()
        if key not in KNOWN_CONFIG_KEYS:
            raise ConfigProblem(
                f"{label}:{number}: неизвестный ключ '{raw_key}'")
        value = raw_value.strip()
        if key in ("radius", "scale", "text_height"):
            try:
                values[key] = float(value)
            except ValueError:
                raise ConfigProblem(
                    f"{label}:{number}: '{key}' ожидает число, "
                    f"получено '{value}'")
        elif key == "color":
            values[key] = parse_color(value, label, number)
        elif key == "force":
            if value.lower() in TRUE_WORDS:
                values[key] = True
            elif value.lower() in FALSE_WORDS:
                values[key] = False
            else:
                raise ConfigProblem(
                    f"{label}:{number}: 'force' ожидает 1/0, true/false, "
                    f"yes/no, да/нет, получено '{value}'")
        elif key == "cycle":
            if not re.fullmatch(r"\d+", value):
                raise ConfigProblem(
                    f"{label}:{number}: 'cycle' ожидает номер цикла "
                    f"(0, 1, 58…), получено '{value}'")
            values[key] = int(value)
        else:
            values[key] = value
    return values


def resolve_settings(args) -> Settings:
    """Свести файл и аргументы: аргумент важнее файла, файл — умолчания."""
    explicit = getattr(args, "config", None)
    if explicit:
        path = Path(explicit)
        label = explicit
    else:
        path = DEFAULT_CONFIG
        label = DEFAULT_CONFIG_LABEL
    found = path.is_file()
    file_values = read_config(path, label) if found else {}
    settings = Settings(label, found)

    def pick(key: str, argument, default=_MISSING) -> None:
        if argument is not None:
            settings.values[key] = argument
            settings.sources[key] = "аргумент"
        elif key in file_values:
            settings.values[key] = file_values[key]
            settings.sources[key] = "файл"
        elif default is not _MISSING:
            settings.values[key] = default
            settings.sources[key] = "по умолчанию"
        else:
            settings.values[key] = None
            settings.sources[key] = "не задано"

    for key in ("layer_a", "layer_b"):
        argument = getattr(args, key, None)
        if argument:
            settings.values[key] = argument
            settings.sources[key] = "аргумент"
        elif file_values.get(key):
            settings.values[key] = file_values[key]
            settings.sources[key] = "файл"
        else:
            settings.values[key] = None
            settings.sources[key] = "не задано"

    pick("radius", getattr(args, "radius", None), 5.0)
    pick("scale", getattr(args, "scale", None), 400.0)
    pick("text_height", getattr(args, "text_height", None), 2.0)
    pick("force", getattr(args, "force", None), False)
    pick("cycle", getattr(args, "cycle", None))

    excel_arg = getattr(args, "excel", None)
    if excel_arg:
        settings.values["excel"] = excel_arg
        settings.sources["excel"] = "аргумент"
    elif file_values.get("excel"):
        settings.values["excel"] = file_values["excel"]
        settings.sources["excel"] = "файл"
    else:
        settings.values["excel"] = None
        settings.sources["excel"] = "по умолчанию"

    file_color = file_values.get("color", _MISSING)
    by_layer_arg = getattr(args, "by_layer", None)
    if by_layer_arg is not None:
        settings.by_layer = float(by_layer_arg)
        settings.sources["color"] = "аргумент"
        if settings.by_layer == 1:
            settings.values["color"] = "by_layer"
        elif isinstance(file_color, int):
            settings.aci = file_color
            settings.values["color"] = f"ACI {file_color}"
        else:
            settings.values["color"] = "ACI текущий"
    elif isinstance(file_color, int):
        settings.by_layer = 0.0
        settings.aci = file_color
        settings.values["color"] = f"ACI {file_color}"
        settings.sources["color"] = "файл"
    elif file_color == "by_layer":
        settings.by_layer = 1.0
        settings.values["color"] = "by_layer"
        settings.sources["color"] = "файл"
    else:
        settings.by_layer = 1.0
        settings.values["color"] = "by_layer"
        settings.sources["color"] = "по умолчанию"
    return settings


def apply_settings(args, settings: Settings) -> None:
    """Перенести итоговые значения в args: фазы читают их как раньше."""
    for key in ("layer_a", "layer_b", "radius", "scale", "text_height",
                "force", "excel", "cycle"):
        setattr(args, key, settings.values.get(key))
    args.by_layer = settings.by_layer
    args.aci = settings.aci


def print_settings_source(settings: Settings) -> None:
    if settings.found:
        print(f"настройки: {settings.label}")
    else:
        print("настройки: аргументы командной строки "
              f"(файл {settings.label} не найден)")


def number_text(value) -> str:
    number = float(value)
    return str(int(number)) if number.is_integer() else str(number)


def print_config(settings: Settings) -> None:
    """Показать итоговые значения и источник каждого ключа."""
    for key in ("layer_a", "layer_b"):
        value = settings.value(key) or "—"
        print(f"  {key} = {value} ({settings.sources[key]})")
    print(f"  radius = {number_text(settings.value('radius'))} "
          f"({settings.sources['radius']})")
    print(f"  scale = {number_text(settings.value('scale'))} "
          f"({settings.sources['scale']})")
    print(f"  text_height = {number_text(settings.value('text_height'))} "
          f"({settings.sources['text_height']})")
    print(f"  color = {settings.value('color')} "
          f"({settings.sources['color']})")
    force = "да" if settings.value("force") else "нет"
    print(f"  force = {force} ({settings.sources['force']})")
    excel = settings.value("excel") or "— (не задано)"
    print(f"  excel = {excel} ({settings.sources['excel']})")
    cycle = settings.value("cycle")
    if cycle is None:
        print("  cycle = по последнему блоку (по умолчанию)")
    else:
        print(f"  cycle = {cycle} ({settings.sources['cycle']})")


def missing_layers(args) -> list[str]:
    return [name for name in ("layer_a", "layer_b")
            if not getattr(args, name, None)]


def print_missing_layers(args, settings: Settings) -> None:
    names = " и ".join("--" + name.replace("_", "-")
                       for name in missing_layers(args))
    if settings.found:
        print(f"СТОП: в файле {settings.label} не заданы слои: {names}.")
        print("      Добавьте строки layer_a=… и layer_b=…"
              " или передайте --layer-a/--layer-b.")
    else:
        print(f"СТОП: не заданы слои: {names}.")
        print(f"      Создайте файл {settings.label} со строками"
              " layer_a=… и layer_b=… или передайте --layer-a/--layer-b.")


# ── фазы ─────────────────────────────────────────────────────────────────────

def phase_status() -> int:
    code, out, err = run_bridge("status")
    print(out or err)
    if code != 0:
        return 1
    if field(out, "AutoCAD") != "запущен":
        print("СТОП: AutoCAD не запущен — мост сам его не запускает.")
        return 1
    if not field(out, "LCMVersion"):
        print("СТОП: LCM не загружен. Загрузите: py -3 tools/bridge.py load lcm_main.lsp")
        return 1
    return 0


def check_layers(layer_a: str, layer_b: str) -> bool:
    expression = (
        f'(progn (list (if (tblsearch "LAYER" {lisp_str(layer_a)}) 1 0)'
        f' (if (tblsearch "LAYER" {lisp_str(layer_b)}) 1 0)))'
    )
    code, out = eval_lisp(expression)
    if code != 0:
        print(f"СТОП: не удалось проверить слои: {out}")
        return False
    found = head_numbers(out)
    if len(found) < 2 or found[0] != 1:
        print(f"СТОП: на чертеже нет слоя A «{layer_a}». Список: py -3 tools/bridge.py layers")
        return False
    if found[1] != 1:
        print(f"СТОП: на чертеже нет слоя B «{layer_b}». Список: py -3 tools/bridge.py layers")
        return False
    return True


def count_arrows(layer: str) -> int:
    types = " ".join(lisp_str(t) for t in ARROW_TYPES)
    expression = (
        f"(progn (setq n 0) (foreach ty '({types})"
        f" (if (setq s (ssget \"_X\" (list (cons 0 ty) (cons 8 {lisp_str(layer)}))))"
        " (setq n (+ n (sslength s))))) n)"
    )
    code, out = eval_lisp(expression)
    if code != 0:
        raise RuntimeError(f"не удалось посчитать объекты на слое «{layer}»: {out}")
    numbers = head_numbers(out)
    return int(numbers[0]) if numbers else 0


def delete_arrows(layer: str) -> int:
    types = " ".join(lisp_str(t) for t in ARROW_TYPES)
    expression = (
        f"(progn (setq n 0) (foreach ty '({types})"
        f" (if (setq s (ssget \"_X\" (list (cons 0 ty) (cons 8 {lisp_str(layer)}))))"
        " (progn (setq i 0) (while (< i (sslength s)) (entdel (ssname s i))"
        " (setq i (1+ i) n (1+ n)))))) n)"
    )
    code, out = eval_lisp(expression)
    if code != 0:
        raise RuntimeError(f"не удалось удалить старые стрелки: {out}")
    numbers = head_numbers(out)
    return int(numbers[0]) if numbers else 0


def layer_counts(layer: str) -> list[int]:
    types = " ".join(lisp_str(t) for t in ("POINT",) + ARROW_TYPES)
    expression = (
        f"(progn (setq r nil) (foreach ty '({types})"
        f" (setq r (cons (if (setq s (ssget \"_X\" (list (cons 0 ty) (cons 8 {lisp_str(layer)}))))"
        " (sslength s) 0) r))) (reverse r))"
    )
    code, out = eval_lisp(expression)
    if code != 0:
        raise RuntimeError(f"не удалось посчитать объекты: {out}")
    return [int(n) for n in head_numbers(out)]


def phase_draw(args) -> int:
    layer_a, layer_b = args.layer_a, args.layer_b
    if not check_layers(layer_a, layer_b):
        return 1

    existing = count_arrows(layer_b)

    if args.dry_run:
        expression = (
            f"(lcm:geo-run {lisp_str(layer_a)} {lisp_str(layer_b)}"
            f" {lisp_num(args.radius)} nil)"
        )
        code, out = eval_lisp(expression)
        print(out or "—")
        print("\nрежим --dry-run: чертёж не изменялся, стрелки не рисовались")
        return 0 if code == 0 else 1

    if existing and not args.force:
        print(f"СТОП: на слое B «{layer_b}» уже {existing} объектов LINE/TEXT/SOLID.")
        print("      Перерисовка — с флагом --force (старые стрелки будут удалены).")
        return 1

    code, out, err = run_bridge("undo", "mark")
    if code != 0:
        print(f"СТОП: не удалось поставить маркер отката: {err or out}")
        return 1

    if existing:
        removed = delete_arrows(layer_b)
        print(f"удалено старых объектов: {removed}")

    set_aci = ""
    if getattr(args, "aci", None) is not None:
        set_aci = f' (lcm:config-set "ACI" {lisp_int(args.aci)})'
    expression = (
        "(progn"
        ' (setq lcm:cyc-old'
        ' (list (lcm:config-get "SCALE") (lcm:config-get "TEXT_HEIGHT")'
        ' (lcm:config-get "BY_LAYER") (lcm:config-get "ACI")))'
        f' (lcm:config-set "SCALE" {lisp_num(args.scale)})'
        f' (lcm:config-set "TEXT_HEIGHT" {lisp_num(args.text_height)})'
        f' (lcm:config-set "BY_LAYER" {lisp_num(args.by_layer)})'
        + set_aci
        + " (setq lcm:cyc-res (vl-catch-all-apply 'lcm:geo-run"
        f" (list {lisp_str(layer_a)} {lisp_str(layer_b)} {lisp_num(args.radius)} T)))"
        ' (lcm:config-set "SCALE" (nth 0 lcm:cyc-old))'
        ' (lcm:config-set "TEXT_HEIGHT" (nth 1 lcm:cyc-old))'
        ' (lcm:config-set "BY_LAYER" (nth 2 lcm:cyc-old))'
        ' (lcm:config-set "ACI" (nth 3 lcm:cyc-old))'
        " (if (vl-catch-all-error-p lcm:cyc-res)"
        ' (strcat "ERROR: " (vl-catch-all-error-message lcm:cyc-res))'
        " lcm:cyc-res))"
    )
    code, out = eval_lisp(expression)
    if code != 0 or out.startswith("ERROR"):
        run_bridge("undo", "back")
        print(f"СТОП: отрисовка не выполнена, откат сделан.\n{out}")
        return 1

    numbers = head_numbers(out)
    matched = int(numbers[0]) if numbers else 0
    drawn = int(numbers[5]) if len(numbers) > 5 else matched

    if not matched:
        run_bridge("undo", "back")
        print("СТОП: подходящих пар не найдено — откат, ничего не нарисовано.")
        return 1
    if drawn != matched:
        run_bridge("undo", "back")
        print(f"СТОП: пар {matched}, нарисовано {drawn} — расхождение, откат сделан.")
        return 1

    counts = layer_counts(layer_b)
    points, lines, texts, solids = (counts + [0, 0, 0, 0])[:4]
    if not (lines == texts == solids == drawn):
        run_bridge("undo", "back")
        print(f"СТОП: проверка не прошла: LINE/TEXT/SOLID {lines}/{texts}/{solids}"
              f" при {drawn} стрелках — откат сделан.")
        return 1

    print(f"нарисовано стрелок: {drawn}")
    print(f"проверка слоя B: LINE {lines}, TEXT {texts}, SOLID {solids}, POINT {points}")
    print("отчёт: reports/lcm_geo_*.csv")
    return 0


def phase_table(args) -> int:
    if not check_layers(args.layer_a, args.layer_b):
        return 1
    expression = (
        "(progn (setq n 0)"
        ' (if (setq s (ssget "_X" (list (cons 0 "ACAD_TABLE"))))'
        "  (progn (setq i 0) (while (< i (sslength s))"
        "   (entdel (ssname s i)) (setq i (1+ i) n (1+ n)))))"
        f" (setq lcm:cyc-dev (lcm:dev-table {lisp_str(args.layer_a)}"
        f" {lisp_str(args.layer_b)} {lisp_num(args.radius)}))"
        " (list n (car lcm:cyc-dev) (cadr lcm:cyc-dev)))"
    )
    code, out = eval_lisp(expression)
    if code != 0:
        print(f"СТОП: ведомость не построена: {out}")
        return 1
    numbers = [int(n) for n in head_numbers(out)] if out else []
    removed = numbers[0] if numbers else 0
    marks = numbers[1] if len(numbers) > 1 else 0
    total = numbers[2] if len(numbers) > 2 else 0
    print(f"ведомость: марок с отклонениями {marks} из {total}")
    print(f"удалено старых таблиц: {removed}")
    return 0


def python_with_openpyxl() -> str | None:
    """Интерпретатор с openpyxl: свой, из LCM_PYTHON или рантайма DSH."""
    candidates = []
    env_python = os.environ.get("LCM_PYTHON")
    if env_python:
        candidates.append(env_python)
    candidates.append(sys.executable)
    candidates.append(
        str(Path.home() / ".dsh" / "dsh-runtimes" / "dsh-primary-runtime"
            / "dependencies" / "python" / "python.exe")
    )
    for candidate in candidates:
        if not Path(candidate).is_file():
            continue
        try:
            probe = subprocess.run([candidate, "-c", "import openpyxl"],
                                   capture_output=True, timeout=60)
        except OSError:
            continue
        if probe.returncode == 0:
            return candidate
    return None


def phase_xlsx(args) -> int:
    python = python_with_openpyxl()
    if python is None:
        print("СТОП: не найден Python с openpyxl (задайте LCM_PYTHON).")
        return 1
    if not getattr(args, "excel", None):
        print("СТОП: не указана книга Excel: добавьте excel=<файл.xlsx> "
              "в настройки или передайте --excel.")
        return 1
    book = Path(args.excel)
    if not book.is_file():
        print(f"СТОП: нет файла Excel: {book}")
        return 1

    TEMP.mkdir(parents=True, exist_ok=True)
    cells = TEMP / "tbl_cells.txt"
    cells_lisp = str(cells).replace("\\", "/")
    expression = (
        f'(setq e (ssname (ssget "_X" (list (cons 0 "ACAD_TABLE"))) 0)'
        " o (vlax-ename->vla-object e)"
        f' f (open "{cells_lisp}" "w") r 0)'
        "(repeat (vla-get-Rows o) (setq c 0)"
        ' (repeat 4 (write-line (strcat (itoa r) ";" (itoa c) ";"'
        " (vla-GetText o r c)) f) (setq c (1+ c)))"
        "(setq r (1+ r)))"
        '(close f) (list r "ok")'
    )
    code, out = eval_lisp(expression)
    if code != 0 or "ok" not in out:
        print(f"СТОП: не удалось выгрузить ячейки таблицы: {out}")
        return 1
    if not cells.is_file():
        print(f"СТОП: LISP не создал файл ячеек {cells}")
        return 1

    json_path = REPORTS / "_table_cells.json"
    result = subprocess.run(
        [python, str(TOOLS / "lcm_cells_to_json.py"), str(cells), str(json_path)],
        capture_output=True,
    )
    if result.returncode != 0:
        print(f"СТОП: ячейки не разобраны: {decode(result.stderr or result.stdout)}")
        return 1
    print(decode(result.stdout).strip())

    stamp = time.strftime("%Y%m%d_%H%M%S")
    backup = REPORTS / ("_backup_" + book.stem + "_" + stamp + ".xlsx")
    REPORTS.mkdir(exist_ok=True)
    shutil.copy2(book, backup)
    print(f"резервная копия: {backup.name}")

    args_xlsx = [python, str(TOOLS / "lcm_table_to_xlsx.py"), str(book),
                 str(json_path)]
    cycle = getattr(args, "cycle", None)
    if cycle is not None:
        args_xlsx += ["--cycle", str(cycle)]
    result = subprocess.run(args_xlsx, capture_output=True)
    if result.returncode != 0:
        print(f"СТОП: Excel не заполнен: {decode(result.stderr or result.stdout)}")
        return 1
    print(decode(result.stdout).strip())

    verify = TEMP / "verify_xlsx.py"
    verify.write_text(
        "import json, sys, openpyxl\n"
        "from openpyxl.utils import get_column_letter\n"
        "ws = openpyxl.load_workbook(sys.argv[1]).active\n"
        "blocks = []\n"
        "for col in range(5, ws.max_column + 1, 4):\n"
        "    filled = sum(1 for row in range(4, ws.max_row + 1)\n"
        "                 if isinstance(ws.cell(row, col + 1).value, (int, float)))\n"
        "    blocks.append([get_column_letter(col), filled])\n"
        "print(json.dumps({'dimensions': ws.dimensions, 'blocks': blocks},"
        " ensure_ascii=False))\n",
        encoding="utf-8",
    )
    result = subprocess.run([python, str(verify), str(book)], capture_output=True)
    if result.returncode != 0:
        print(f"предупреждение: проверить Excel не удалось: "
              f"{decode(result.stderr or result.stdout)}")
        return 0
    print("Excel: " + decode(result.stdout).strip())
    return 0


def phase_all(args) -> int:
    steps = [("отрисовка", phase_draw), ("ведомость", phase_table), ("Excel", phase_xlsx)]
    for title, step in steps:
        print(f"\n=== {title} ===")
        code = step(args)
        if code != 0:
            print(f"\nостановка на шаге «{title}»; следующие шаги не выполнялись.")
            return code
    print("\nцикл выполнен полностью")
    return 0


# ── аргументы ────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Цикл LayerCycleManager одним вызовом: draw / table / xlsx / all.",
    )
    sub = parser.add_subparsers(dest="phase", required=True)

    status = sub.add_parser("status", help="AutoCAD, чертёж, LCM")
    status.add_argument("--config", metavar="PATH", default=None,
                        help="файл настроек (status его не использует)")

    draw = sub.add_parser("draw", help="сопоставить и нарисовать стрелки")
    add_config_args(draw)
    check_layers_args(draw)
    draw.add_argument("--scale", type=float, default=None,
                      help="масштаб, по умолчанию 400")
    draw.add_argument("--text-height", type=float, default=None,
                      dest="text_height",
                      help="высота текста, по умолчанию 2")
    draw.add_argument("--by-layer", type=float, default=None, dest="by_layer",
                      help="1 — цвет по слою, 0 — ACI из настроек")
    draw.add_argument("--force", action="store_true", default=None,
                      help="перерисовать, удалив старые LINE/TEXT/SOLID слоя B")
    draw.add_argument("--dry-run", action="store_true", dest="dry_run",
                      help="только отчёт о сопоставлении, без изменений")

    table = sub.add_parser("table", help="построить ведомость отклонений")
    add_config_args(table)
    check_layers_args(table)

    xlsx = sub.add_parser("xlsx", help="дописать блок в Excel")
    add_config_args(xlsx)
    xlsx.add_argument("--excel", default=None,
                      help="книга Excel (обязательна, если не задана в настройках)")

    allp = sub.add_parser("all", help="draw -> table -> xlsx")
    add_config_args(allp)
    check_layers_args(allp)
    allp.add_argument("--scale", type=float, default=None,
                      help="масштаб, по умолчанию 400")
    allp.add_argument("--text-height", type=float, default=None,
                      dest="text_height",
                      help="высота текста, по умолчанию 2")
    allp.add_argument("--by-layer", type=float, default=None, dest="by_layer",
                      help="1 — цвет по слою, 0 — ACI из настроек")
    allp.add_argument("--force", action="store_true", default=None)
    allp.add_argument("--dry-run", action="store_true", dest="dry_run")
    allp.add_argument("--keep-temp", action="store_true", dest="keep_temp")
    allp.add_argument("--excel", default=None,
                      help="книга Excel (обязательна, если не задана в настройках)")

    draw.add_argument("--keep-temp", action="store_true", dest="keep_temp")
    table.add_argument("--keep-temp", action="store_true", dest="keep_temp")
    return parser


def add_config_args(target: argparse.ArgumentParser) -> None:
    """Общие аргументы файла настроек для рабочих фаз."""
    target.add_argument("--config", metavar="PATH", default=None,
                        help="файл настроек (по умолчанию _tmp/lcm_run.cfg)")
    target.add_argument("--show-config", action="store_true", dest="show_config",
                        help="показать настройки и выйти, не обращаясь к AutoCAD")


def check_layers_args(target: argparse.ArgumentParser) -> None:
    """Общие аргументы слоёв для фаз, которым они нужны."""
    target.add_argument("--layer-a", default=None, help="слой нулевого цикла")
    target.add_argument("--layer-b", default=None, help="слой последнего цикла")
    target.add_argument("--radius", type=float, default=None,
                        help="радиус пар, по умолчанию 5")


def main() -> int:
    setup_stdout()
    args = build_parser().parse_args()
    if args.phase != "status":
        try:
            settings = resolve_settings(args)
        except ConfigProblem as exc:
            print(f"СТОП: {exc}")
            return 2
        apply_settings(args, settings)
        print_settings_source(settings)
        requires_layers = args.phase in ("draw", "table", "all")
        if getattr(args, "show_config", False):
            print_config(settings)
            if requires_layers and missing_layers(args):
                print_missing_layers(args, settings)
                return 2
            return 0
        if requires_layers and missing_layers(args):
            print_missing_layers(args, settings)
            return 2

    phases = {
        "status": lambda: phase_status(),
        "draw": lambda: phase_draw(args),
        "table": lambda: phase_table(args),
        "xlsx": lambda: phase_xlsx(args),
        "all": lambda: phase_all(args),
    }
    try:
        code = phases[args.phase]()
    except RuntimeError as exc:
        print(f"СТОП: {exc}")
        return 1
    finally:
        if not getattr(args, "keep_temp", False):
            shutil.rmtree(TEMP, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
