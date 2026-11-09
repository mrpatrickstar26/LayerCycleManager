# -*- coding: utf-8 -*-
"""Проверки перед коммитом для LayerCycleManager.

Один запуск — одна сводка: кодировки и переводы строк, остатки конфликтов
слияния, дубли команд C:, валидность memory.json и три штатные проверки
репозитория (tools/lisp_check.py, tools/ref_check.py, tools/memory_check.py).

    py -3 tools/check_all.py           # всё
    py -3 tools/check_all.py --fast    # без memory_check --deep (быстрый цикл)
    py -3 tools/check_all.py --full    # печатать вывод подпроверок целиком
    py -3 tools/check_all.py --install-hook    # включить git-хук pre-commit
    py -3 tools/check_all.py --uninstall-hook  # выключить его

Код возврата: 0 — можно коммитить, 1 — есть проблемы.

Границы проверки. Здесь ловится «файл цел и не сломан»: кодировка, переводы
строк, баланс скобок, существование вызываемых функций, ссылки в памяти.
Правильность геометрии и чисел так не проверить — это только прогон в AutoCAD.

Правила кодировок взяты из AGENTS.md и проверяются по содержимому файла:
  .lsp / .dcl    Windows-1251 (AutoCAD читает их как ANSI);
  .ps1           UTF-8 с BOM (PowerShell 5.1 без BOM портит кириллицу);
  .md .txt .json .py .cjs .csv, .gitignore   UTF-8 без BOM;
  tools/hooks/*  LF (sh-скрипты, CRLF их ломает);
  остальное      CRLF.

Файлы берутся из индекса git, поэтому новый файл проверяется сразу после
`git add` — до коммита.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

LISP_SUFFIXES = {".lsp", ".dcl"}
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".cuix", ".dwg",
                   ".xlsx", ".db", ".fas", ".vlx", ".zip", ".pdf"}
HOOK_PREFIX = "tools/hooks/"


# ── список файлов ────────────────────────────────────────────────────────────

def files_from_git() -> list[str]:
    """Файлы индекса git: то, что попадёт в следующий коммит."""
    try:
        proc = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "--cached"],
            capture_output=True,
        )
    except OSError:
        return []
    if proc.returncode != 0:
        return []
    return [n for n in proc.stdout.decode("utf-8", "replace").split("\0") if n]


def all_files() -> list[str]:
    names = files_from_git()
    if names:
        return names
    return sorted(p.relative_to(ROOT).as_posix() for p in ROOT.rglob("*")
                  if p.is_file() and ".git" not in p.parts)


# ── кодировки, переводы строк, маркеры ───────────────────────────────────────

def rule_for(rel: str) -> str:
    """Ожидаемая кодировка файла: cp1251 / utf-8 / utf-8-bom."""
    suffix = Path(rel).suffix.lower()
    if suffix in LISP_SUFFIXES:
        return "cp1251"
    if suffix == ".ps1":
        return "utf-8-bom"
    return "utf-8"


def check_file(rel: str) -> tuple[str, list[str]]:
    """Категория файла ('text' / 'binary') и список найденных проблем."""
    path = ROOT / rel
    try:
        data = path.read_bytes()
    except OSError as exc:
        return "text", [f"{rel}: не читается ({exc.__class__.__name__})"]

    suffix = Path(rel).suffix.lower()
    if suffix in BINARY_SUFFIXES or b"\0" in data[:8000]:
        return "binary", []

    problems: list[str] = []
    kind = rule_for(rel)

    # BOM
    has_bom = data[:3] == b"\xef\xbb\xbf"
    if kind == "utf-8-bom":
        if not has_bom:
            problems.append(f"{rel}: нет BOM — PowerShell 5.1 испортит кириллицу")
        body = data[3:] if has_bom else data
    else:
        if has_bom:
            problems.append(f"{rel}: BOM не нужен — уберите (AutoCAD читает .lsp как ANSI)")
        body = data

    # кодировка
    if kind == "cp1251":
        if any(byte >= 0x80 for byte in body):
            try:
                body.decode("utf-8")
            except UnicodeDecodeError:
                pass
            else:
                problems.append(
                    f"{rel}: файл в UTF-8, а AutoCAD читает .lsp/.dcl как ANSI — "
                    "пересохраните в Windows-1251")
        try:
            text = body.decode("cp1251")
        except UnicodeDecodeError as exc:
            problems.append(f"{rel}: не читается как Windows-1251 (байт {exc.start})")
            text = body.decode("cp1251", "replace")
    else:
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError as exc:
            problems.append(f"{rel}: не UTF-8 (байт {exc.start}) — ожидается UTF-8")
            text = body.decode("utf-8", "replace")
        if "\ufffd" in text:
            problems.append(f"{rel}: содержит U+FFFD — текст уже был испорчен")

    # переводы строк
    crlf = body.count(b"\r\n")
    lf_only = body.count(b"\n") - crlf
    cr_only = body.count(b"\r") - crlf
    if rel.startswith(HOOK_PREFIX):
        if crlf:
            problems.append(f"{rel}: CRLF в sh-скрипте — git не выполнит хук, нужен LF")
    else:
        if lf_only:
            problems.append(f"{rel}: {lf_only} строк с одиночным LF — нужны CRLF")
        if cr_only:
            problems.append(f"{rel}: {cr_only} строк с одиночным CR — нужны CRLF")

    # остатки конфликта слияния (только маркеры git, не декоративные линии)
    if re.search(r"^(<<<<<<<|>>>>>>>)", text, re.MULTILINE):
        problems.append(f"{rel}: остался маркер конфликта слияния")

    return "text", problems


# ── дубли команд ─────────────────────────────────────────────────────────────

DEFUN_RE = re.compile(r"^\s*\(defun\s+c:([A-Za-z0-9_\-]+)", re.IGNORECASE | re.MULTILINE)


def check_commands(names: list[str]) -> tuple[int, list[str]]:
    owners: dict[str, list[str]] = {}
    for rel in names:
        if Path(rel).suffix.lower() not in LISP_SUFFIXES:
            continue
        text = (ROOT / rel).read_bytes().decode("cp1251", "replace")
        for match in DEFUN_RE.finditer(text):
            owners.setdefault(match.group(1).upper(), []).append(rel)

    problems = [f"команда C:{cmd} определена дважды: {', '.join(paths)}"
                for cmd, paths in sorted(owners.items()) if len(paths) > 1]
    return sum(len(v) for v in owners.values()), problems


# ── memory.json ──────────────────────────────────────────────────────────────

def check_memory_json() -> list[str]:
    path = ROOT / "memory.json"
    if not path.is_file():
        return ["memory.json не найден"]
    try:
        cfg = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        return [f"memory.json: не разбирается ({exc})"]
    return [f"memory.json: нет ключа '{key}'"
            for key in ("patterns", "skip_dirs", "git_history", "db_dir")
            if key not in cfg]


# ── штатные проверки ─────────────────────────────────────────────────────────

def run_tool(args: list[str]) -> tuple[bool, str]:
    try:
        proc = subprocess.run([sys.executable, *args], cwd=str(ROOT), capture_output=True)
    except OSError as exc:
        return False, f"не запустилось: {exc.__class__.__name__}"
    out = proc.stdout.decode("utf-8", "replace") + proc.stderr.decode("utf-8", "replace")
    return proc.returncode == 0, out.strip()


# ── git-хук ──────────────────────────────────────────────────────────────────

def git(*args: str) -> int:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True).returncode


def hook_state() -> str:
    proc = subprocess.run(["git", "-C", str(ROOT), "config", "--get", "core.hooksPath"],
                          capture_output=True)
    value = proc.stdout.decode("utf-8", "replace").strip()
    return f"включён: {value}" if value else "выключен"


def set_hook(enabled: bool) -> int:
    if enabled:
        if git("config", "core.hooksPath", "tools/hooks") != 0:
            print("не удалось записать core.hooksPath")
            return 1
        print("Хук включён: core.hooksPath = tools/hooks.\n"
              "Проверки запускаются при каждом git commit.\n"
              "Важно: git-хуки работают через sh.exe. В песочнице DSH sh не "
              "стартует,\nпоэтому коммит из-под агента идёт с --no-verify, а скрипт "
              "запускается вручную.\n")
    else:
        git("config", "--unset", "core.hooksPath")
    print(f"Хук: {hook_state()}.")
    return 0


# ── вывод ────────────────────────────────────────────────────────────────────

def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    args = sys.argv[1:]
    if "--install-hook" in args:
        return set_hook(True)
    if "--uninstall-hook" in args:
        return set_hook(False)

    fast = "--fast" in args
    full = "--full" in args
    names = all_files()

    results: list[tuple[str, bool, list[str], str]] = []

    problems: list[str] = []
    text_count = binary_count = 0
    for rel in names:
        category, found = check_file(rel)
        if category == "binary":
            binary_count += 1
            continue
        text_count += 1
        problems.extend(found)
    results.append((
        f"кодировки и переводы строк (текстовых {text_count}, бинарных {binary_count})",
        not problems, problems, ""))

    problems = check_memory_json()
    results.append(("memory.json", not problems, problems, ""))

    total_cmds, problems = check_commands(names)
    results.append((f"дубли команд C: (всего {total_cmds})", not problems, problems, ""))

    lisp = [n for n in names if Path(n).suffix.lower() in LISP_SUFFIXES]
    ok, out = run_tool(["tools/lisp_check.py", *lisp])
    results.append((f"lisp_check.py ({len(lisp)} файлов)", ok, [], out))

    ok, out = run_tool(["tools/ref_check.py"])
    results.append(("ref_check.py", ok, [], out))

    if fast:
        results.append(("memory_check.py --deep — пропущено (--fast)", True, [], ""))
    else:
        ok, out = run_tool(["tools/memory_check.py", "--deep"])
        results.append(("memory_check.py --deep", ok, [], out))

    print(f"LayerCycleManager — проверки перед коммитом (хук git: {hook_state()}):")
    print()
    for title, ok, found, output in results:
        print(f"  {'OK  ' if ok else 'FAIL'}  {title}")
        for line in found:
            print(f"        ! {line}")
        if output and (full or not ok):
            for line in output.splitlines():
                print(f"        {line}")
    print()

    if any(not ok for _, ok, _, _ in results):
        print("ИТОГ: коммит заблокирован. Исправьте ошибки выше и запустите снова; "
              "осознанный обход — git commit --no-verify.")
        return 1
    print("ИТОГ: проблем нет, коммит разрешён.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
