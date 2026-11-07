#!/usr/bin/env python3
"""Проверка «памяти проекта»: размер AGENTS.md и структура docs/research/.

Зачем: файлы памяти — это инструкции, которые агент исполняет, и они вклеиваются
в контекст каждой сессии. Без проверки они расползаются: AGENTS.md растёт, а
решения снова превращаются в простыню буллетов в STATE.md.

Что проверяется:
  1. AGENTS.md существует, не больше LIMIT_AGENTS байт и ссылается на индекс.
  2. docs/research/INDEX.md существует, и все его ссылки ведут на живые файлы.
  3. Каждый docs/research/NN-*.md имеет заголовок, «**Статус:**», «**Решение:**»,
     раздел «## Детали» и упомянут в INDEX.md.
  4. memory.json разбирается как JSON и содержит обязательные ключи.

Глубокая проверка (`--deep`) ловит устаревшие утверждения: упомянутые в тексте
файлы должны существовать, символы `lcm:*` и команды `LCM*` — быть в исходниках.

Запуск: py -3 tools/memory_check.py [--deep] [--json]
Код возврата: 0 — всё в порядке, 1 — есть ошибки.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENTS = ROOT / "AGENTS.md"
RESEARCH = ROOT / "docs" / "research"
INDEX = RESEARCH / "INDEX.md"
STATE = ROOT / "docs" / "STATE.md"
CONFIG = ROOT / "memory.json"

LIMIT_AGENTS = 12288          # 12 КБ: столько вклеивается в каждую сессию
LIMIT_STATE = 40960           # 40 КБ: STATE.md — справочник, а не свалка
REQUIRED_FIELDS = ("**Статус:**", "**Решение:**")
LINK_RE = re.compile(r"\]\(([^)#]+\.md)\)")
NAME_RE = re.compile(r"^\d{2}-[a-z0-9-]+\.md$")


def setup_stdout() -> None:
    """Русская Windows: Python пишет cp1251 в терминал, ожидающий UTF-8."""
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def read(path: Path) -> str:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", errors="replace")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1251", errors="replace")


SKIP_PARTS = {".git", ".memory", "reports", "__pycache__", "node_modules", ".venv", ".idea", ".vscode"}
LOCALISH = re.compile(
    r"(^|/)(reports|settings|\.memory)/|docs/LAST_SESSION\.md|\.(dwg|xlsx|cfg|bak|tmp|pyc)$",
    re.IGNORECASE,  # имена ниже приводятся к нижнему регистру — иначе исключение не срабатывает
)
MENTION_RE = re.compile(r"((?:[\w.-]+/)*[\w.-]+\.(?:lsp|dcl|py|ps1|cjs|json|md))\b")
SYMBOL_RE = re.compile(r"\blcm:[a-z0-9][a-z0-9-]*")
COMMAND_RE = re.compile(r"\bLCM[A-Z][A-Z0-9]{2,}\b")
REMOVED_RE = re.compile(r"удал|убра|снят|несуществ|removed", re.IGNORECASE)


def repo_names() -> set[str]:
    """Имена файлов и относительные пути репозитория в нижнем регистре."""
    names: set[str] = set()
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in SKIP_PARTS for part in path.parts):
            continue
        names.add(path.name.lower())
        try:
            names.add(path.relative_to(ROOT).as_posix().lower())
        except ValueError:
            pass
    return names


def lisp_corpus() -> str:
    """Все lcm_*.lsp одним текстом (кодировка — по содержимому)."""
    chunks = []
    for path in sorted(ROOT.glob("lcm_*.lsp")):
        raw = path.read_bytes()
        try:
            chunks.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            chunks.append(raw.decode("cp1251", errors="replace"))
    return "\n".join(chunks).lower()


def deep_checks() -> tuple[list[str], dict[str, int]]:
    """Сверяет упоминания в тексте памяти с фактическим содержимым репозитория.

    Ссылка ищется относительно самого документа (docs/ → research/01-…md), затем
    от корня. Строки, где речь идёт об удалённом («удалены», «убрано»), пропускаются:
    память обязана помнить и то, чего в коде уже нет.
    """
    errors: list[str] = []
    known = repo_names()
    lisp = lisp_corpus()
    docs = sorted((ROOT / "docs" / "research").glob("*.md"))
    docs += [ROOT / "docs" / "STATE.md", ROOT / "docs" / "LOG.md", AGENTS]

    seen: set[tuple[str, str]] = set()
    counts = {"files": 0, "symbols": 0, "commands": 0}

    def resolves(doc: Path, mention: str) -> bool:
        if (doc.parent / mention).is_file() or (ROOT / mention).is_file():
            return True
        return mention.lower() in known

    for doc in docs:
        if not doc.is_file():
            continue
        body = read(doc)
        rel = doc.relative_to(ROOT).as_posix()

        for mention in MENTION_RE.findall(body):
            name = mention.strip("./")
            low = name.lower()
            if (LOCALISH.search("/" + low) or "NN-" in name or "<" in name
                    or low.startswith("_")):
                continue
            key = (rel, low)
            if key in seen:
                continue
            seen.add(key)
            counts["files"] += 1
            if not resolves(doc, name):
                errors.append(f"{rel}: упомянут «{name}», но такого файла нет")

        for line in body.splitlines():
            if REMOVED_RE.search(line):
                continue
            for symbol in sorted(set(SYMBOL_RE.findall(line))):
                key = (rel, symbol)
                if key in seen:
                    continue
                seen.add(key)
                counts["symbols"] += 1
                if symbol.lower() not in lisp:
                    errors.append(f"{rel}: упомянут «{symbol}», но в lcm_*.lsp его нет")
            for command in sorted(set(COMMAND_RE.findall(line))):
                key = (rel, command)
                if key in seen:
                    continue
                seen.add(key)
                counts["commands"] += 1
                if ("c:" + command).lower() not in lisp:
                    errors.append(f"{rel}: упомянута команда «{command}», но «(defun c:{command} …)» нет")

    return errors, counts


def main() -> int:
    setup_stdout()
    errors: list[str] = []
    notices: list[str] = []

    # 1. AGENTS.md
    if not AGENTS.is_file():
        errors.append("AGENTS.md не найден")
        agents_size = 0
    else:
        agents_size = AGENTS.stat().st_size
        text = read(AGENTS)
        if agents_size > LIMIT_AGENTS:
            errors.append(
                f"AGENTS.md {agents_size} байт > {LIMIT_AGENTS}: вынесите конкретику "
                "в docs/ и оставьте здесь правило (см. правило 10)"
            )
        if "docs/research/INDEX.md" not in text:
            errors.append("AGENTS.md не ссылается на docs/research/INDEX.md")

    # 2. INDEX.md и его ссылки
    index_text = ""
    if not INDEX.is_file():
        errors.append("docs/research/INDEX.md не найден")
    else:
        index_text = read(INDEX)
        for target in LINK_RE.findall(index_text):
            if not (RESEARCH / target).is_file():
                errors.append(f"INDEX.md ссылается на несуществующий {target}")

    # 3. файлы research/
    files = sorted(p for p in RESEARCH.glob("*.md") if p.name != "INDEX.md") if RESEARCH.is_dir() else []
    if not files and RESEARCH.is_dir():
        notices.append("docs/research/ пуст — решений пока нет")
    for path in files:
        body = read(path)
        if not NAME_RE.match(path.name):
            errors.append(f"{path.name}: имя должно быть NN-тема.md")
        if not body.lstrip().startswith("# "):
            errors.append(f"{path.name}: нет заголовка '# '")
        for field in REQUIRED_FIELDS:
            if field not in body:
                errors.append(f"{path.name}: нет поля «{field}»")
        if "## Детали" not in body:
            errors.append(f"{path.name}: нет раздела '## Детали'")
        if index_text and path.name not in index_text:
            errors.append(f"{path.name}: не упомянут в INDEX.md")

    # 4. STATE.md и memory.json
    state_size = STATE.stat().st_size if STATE.is_file() else 0
    if not STATE.is_file():
        errors.append("docs/STATE.md не найден")
    elif state_size > LIMIT_STATE:
        errors.append(f"STATE.md {state_size} байт > {LIMIT_STATE}: разнесите историю по docs/research/")
    if not CONFIG.is_file():
        errors.append("memory.json не найден")
    else:
        try:
            cfg = json.loads(read(CONFIG))
        except json.JSONDecodeError as exc:
            errors.append(f"memory.json: не разбирается ({exc})")
            cfg = {}
        for key in ("patterns", "skip_dirs", "git_history", "db_dir"):
            if key not in cfg:
                errors.append(f"memory.json: нет ключа '{key}'")

    deep_stats = None
    if "--deep" in sys.argv[1:]:
        deep_errors, deep_stats = deep_checks()
        errors.extend(deep_errors)

    report = {
        "agents_bytes": agents_size,
        "agents_limit": LIMIT_AGENTS,
        "state_bytes": state_size,
        "research_files": len(files),
        "research_bytes": sum(p.stat().st_size for p in files),
        "deep": deep_stats,
        "errors": errors,
        "notices": notices,
    }
    if "--json" in sys.argv[1:]:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"AGENTS.md   : {agents_size:>6} / {LIMIT_AGENTS} байт")
        print(f"STATE.md    : {state_size:>6} / {LIMIT_STATE} байт")
        print(f"docs/research: {len(files)} файлов, {report['research_bytes']} байт")
        if deep_stats is not None:
            print(
                "deep        : файлов {}, символов {}, команд {}".format(
                    deep_stats["files"], deep_stats["symbols"], deep_stats["commands"]
                )
            )
        for note in notices:
            print(f"  ~ {note}")
        if errors:
            print("\nОШИБКИ:")
            for err in errors:
                print(f"  ! {err}")
        else:
            print("\nПамять в порядке.")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
