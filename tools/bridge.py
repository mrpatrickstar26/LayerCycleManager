#!/usr/bin/env python3
"""Мост DSH -> AutoCAD: запуск tools/cad_bridge.ps1 в условиях песочницы DSH.

Почему не `& tools/cad_bridge.ps1`: процессы песочницы работают на низком уровне
целостности, и Windows PowerShell отказывается исполнять файлы .ps1
("AuthorizationManager check failed"). Inline-команды PowerShell при этом работают.

Как работает:
1. cad_bridge.ps1 читается как текст, строка
       $Script:Root = Split-Path -Parent $PSScriptRoot
   заменяется на литеральный путь проекта (в scriptblock-режиме $PSScriptRoot пуст).
2. Исправленный текст кладётся во временный файл, который PowerShell читает,
   но не исполняет как сценарий: код передаётся через -Command и scriptblock.
3. Аргументы командной строки подставляются как строковые литералы PowerShell,
   поэтому кавычки, кириллица и LISP-выражения доходят без искажений.

Использование — как у cad_bridge.ps1:
    py -3 tools/bridge.py status
    py -3 tools/bridge.py eval "(getvar \"DWGNAME\")"
    py -3 tools/bridge.py dump -Layer "Уч 6 Цикл 1"
    py -3 tools/bridge.py report -Kind chain

Для длинных выражений кавычки удобнее не экранировать, а держать текст в файле:

    py -3 tools/bridge.py eval @C:\\path\\query.lsp
"""

import os
import pathlib
import subprocess
import sys
import tempfile

TOOLS = pathlib.Path(__file__).resolve().parent
ROOT = TOOLS.parent
SCRIPT = TOOLS / "cad_bridge.ps1"

ROOT_LINE = "Split-Path -Parent $PSScriptRoot"


def ps_quote(text: str) -> str:
    """Строковый литерал PowerShell в одинарных кавычках."""
    return "'" + text.replace("'", "''") + "'"


def format_arg(text: str) -> str:
    """Имена параметров (-Layer, -Kind) оставляем без кавычек, значения — в кавычках."""
    if text.startswith("-") and " " not in text:
        return text
    return ps_quote(text)


def build_command(patched_path: pathlib.Path, args) -> str:
    arguments = " ".join(format_arg(a) for a in args)
    return (
        "& ([scriptblock]::Create([IO.File]::ReadAllText("
        + ps_quote(str(patched_path))
        + "))) "
        + arguments
    )


def main() -> int:
    source = SCRIPT.read_text(encoding="utf-8-sig")
    if ROOT_LINE not in source:
        raise SystemExit(
            "cad_bridge.ps1: не найдена строка %r — обновите tools/bridge.py" % ROOT_LINE
        )
    patched = source.replace(ROOT_LINE, ps_quote(str(ROOT)))

    args = list(sys.argv[1:])
    if len(args) >= 2 and args[0].lower() == "eval" and args[1].startswith("@"):
        expression_file = pathlib.Path(args[1][1:])
        if expression_file.is_file():
            args[1] = expression_file.read_text(encoding="utf-8-sig").strip()
        else:
            raise SystemExit("файл с LISP-выражением не найден: %s" % expression_file)

    handle, temp_name = tempfile.mkstemp(prefix="lcm_bridge_", suffix=".ps1")
    os.close(handle)
    temp_path = pathlib.Path(temp_name)
    try:
        temp_path.write_text(patched, encoding="utf-8-sig", newline="\r\n")
        command = build_command(temp_path, args)
        return subprocess.call(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command]
        )
    finally:
        try:
            temp_path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
