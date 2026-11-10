# -*- coding: utf-8 -*-
"""memory_index.py — полнотекстовая память проекта LayerCycleManager (SQLite FTS5).

Идея взята из ObsidianDataWeave (scripts/memory_index.py), но заточена под наш
корпус: markdown-документация, LISP-модули в Windows-1251, CSV-отчёты и история
git — всё в одном индексе. Зависимостей нет: только stdlib (sqlite3).

База лежит в каталоге db_dir из memory.json — по умолчанию .memory/ в корне
проекта (каталог в .gitignore, индекс производный и не коммитится):
    .memory/<slug>-<hash>.db
Каталог переопределяют LCM_MEMORY_DIR или db_dir в конфиге; если запись
запрещена (песочница DSH), search/status открывают базу только для чтения.

Команды (в Windows вызывать через py -3, если python — заглушка Store):
    py -3 tools/memory_index.py build              # полная пересборка
    py -3 tools/memory_index.py update             # догон по mtime/size
    py -3 tools/memory_index.py status             # что в индексе
    py -3 tools/memory_index.py search "запрос" [--limit 8] [--kind md] [--json]
    py -3 tools/memory_index.py defuns [имя]        # LISP-функции: аргументы, кого зовут
    py -3 tools/memory_index.py callers "имя"       # кто вызывает LISP-функцию

Поиск и status умеют работать с базой ТОЛЬКО ДЛЯ ЧТЕНИЯ: если каталог базы
недоступен на запись, они открывают её в режиме read-only (индекс не свежеет,
CLI честно об этом предупреждает). Пересборка (build/update) требует записи.

Кодировки: .md/.py/.cjs/.ps1 — UTF-8 (BOM или без), .lsp/.dcl — Windows-1251,
.csv — UTF-8 с BOM (fallback 1251). Определяются по содержимому, а не по имени.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ── конфигурация: memory.json в корне проекта ────────────────────────────────
# Скрипт переносимый: что индексировать и что пропускать задаётся конфигом, а не
# кодом. Без конфига работают значения по умолчанию (они же пишутся командой
# init), поэтому в новом проекте достаточно скопировать tools/memory_index.py
# и выполнить `init`.

CONFIG_NAME = "memory.json"

DEFAULT_CONFIG = {
    "patterns": {
        "*.md": "md",
        "*.lsp": "lsp",
        "*.dcl": "dcl",
        "*.py": "py",
        "*.ps1": "ps1",
        "*.cjs": "js",
        "reports/*.csv": "csv",
    },
    "skip_dirs": [".git", "node_modules", "__pycache__", ".venv", "venv",
                  ".dsh", ".idea", ".vscode", ".pytest_cache"],
    "git_history": True,
    "db_dir": "",
}


def config_path() -> Path:
    """Путь к конфигу: LCM_MEMORY_CONFIG или memory.json в корне проекта."""
    return Path(os.environ.get("LCM_MEMORY_CONFIG") or (ROOT / CONFIG_NAME))


def load_config() -> dict:
    """Значения по умолчанию, поверх них — memory.json (если он есть)."""
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    path = config_path()
    if path.is_file():
        try:
            # utf-8-sig: Notepad и PowerShell пишут BOM, обычный utf-8 на нём падает
            raw = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as exc:
            print(f"· {path.name}: не читается ({exc}) — взяты значения по умолчанию",
                  file=sys.stderr)
            raw = {}
        if isinstance(raw, dict):
            for key in ("patterns", "skip_dirs", "git_history", "db_dir"):
                if key in raw:
                    cfg[key] = raw[key]
    return cfg


def write_default_config(force: bool = False) -> Path:
    """Записать memory.json со значениями по умолчанию (для нового проекта)."""
    path = config_path()
    if path.exists() and not force:
        raise RuntimeError(f"{path} уже существует — перезапись: init --force")
    try:
        path.write_text(json.dumps(DEFAULT_CONFIG, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(
            f"не удалось записать {path} ({exc.__class__.__name__}: {exc}).\n"
            "  В песочнице DSH файлы проекта правит инструмент агента, а не скрипт:\n"
            "  создайте memory.json вручную или запустите init вне песочницы."
        ) from exc
    return path


CONFIG = load_config()
PATTERNS = dict(CONFIG["patterns"])
SKIP_DIRS = set(CONFIG["skip_dirs"])

# По умолчанию база вне репозитория. LCM_MEMORY_DIR (или db_dir в конфиге)
# позволяет увести её в доступный на запись каталог — нужно в песочнице DSH.
DB_DIR = Path(
    os.environ.get("LCM_MEMORY_DIR")
    or CONFIG.get("db_dir")
    or (Path(os.environ.get("LOCALAPPDATA", Path.home())) / "cache" / "lcm-memory")
)

# Относительный db_dir считается от корня проекта, а не от текущего каталога:
# иначе запуск из другого каталога увёл бы индекс в чужое место, а скопированный
# проект потерял бы свою базу.
if not DB_DIR.is_absolute():
    DB_DIR = Path(__file__).resolve().parent.parent / DB_DIR

# Негромкие предупреждения для CLI: «индекс не обновлён», «база только для чтения».
NOTES: dict[str, str] = {}

# PATTERNS и SKIP_DIRS приходят из конфига (см. выше, memory.json).

def suffix_kinds() -> dict[str, str]:
    """Расширение → вид, собранное из простых шаблонов вида «*.ext»."""
    return {pat[1:].lower(): kind for pat, kind in PATTERNS.items()
            if pat.startswith("*.") and "/" not in pat}

_FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n?", re.DOTALL)
_HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$", re.MULTILINE)


# ── служебное ────────────────────────────────────────────────────────────────

def read_text(path: Path) -> str:
    """Читает файл, подбирая кодировку по содержимому."""
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", errors="replace")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1251", errors="replace")


def db_path() -> Path:
    digest = hashlib.sha1(str(ROOT).encode("utf-8")).hexdigest()[:10]
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", ROOT.name).strip("-") or "project"
    return DB_DIR / f"{slug}-{digest}.db"


def open_db(path: Path, readonly: bool = False) -> sqlite3.Connection:
    """Открывает базу.

    readonly=True — когда каталог индекса недоступен на запись (песочница,
    чужой профиль): SQLite открывает файл без журнала и без правки заголовка.
    """
    if not readonly:
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    last: Exception | None = None
    for suffix in ("?mode=ro", "?mode=ro&immutable=1"):
        try:
            conn = sqlite3.connect("file:" + path.as_posix() + suffix, uri=True)
            conn.execute("PRAGMA busy_timeout=5000")
            conn.execute("SELECT count(*) FROM meta").fetchone()  # проверка, что читается
            return conn
        except sqlite3.Error as exc:  # WAL без прав на -shm и т.п.
            last = exc
    raise RuntimeError(f"не удалось открыть базу только для чтения: {last}")


def open_read(path: Path) -> tuple[sqlite3.Connection, bool]:
    """Открывает базу для чтения: сначала с записью, при отказе — read-only.

    Возвращает (соединение, только_чтение).
    """
    try:
        return open_db(path), False
    except (sqlite3.Error, OSError):
        return open_db(path, readonly=True), True


def no_write_hint(path: Path, exc: Exception) -> str:
    """Понятное объяснение, когда каталог индекса недоступен на запись."""
    return (
        f"нет записи в каталог индекса {path.parent} "
        f"({exc.__class__.__name__}: {exc}).\n"
        "  В ограниченном режиме DSH запись вне рабочей папки запрещена,\n"
        "  а обычные процессы не пишут и внутрь неё. Варианты:\n"
        "  1) разовое расширение доступа на саму команду (danger-full-access);\n"
        "  2) временная база в доступном каталоге — пересборка занимает секунды:\n"
        '       $env:LCM_MEMORY_DIR = "$env:TEMP\\lcm-memory"\n'
        "       py -3 tools/memory_index.py build\n"
        "  Поиск (search) и status при этом работают и с базой только для чтения."
    )


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("CREATE TABLE IF NOT EXISTS files ("
                 " path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL,"
                 " kind TEXT NOT NULL)")
    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5("
        " title, headings, tags, body, path UNINDEXED, folder UNINDEXED, kind UNINDEXED,"
        " tokenize=\"unicode61 remove_diacritics 2\", prefix='2 3')"
    )
    conn.commit()


# ── разбор документов ────────────────────────────────────────────────────────

def parse_markdown(path: Path, rel: str) -> dict:
    text = read_text(path)
    tags: list[str] = []
    body = text
    m = _FRONTMATTER_RE.match(text)
    if m:
        body = text[m.end():]
        for line in m.group(1).splitlines():
            if line.strip().lower().startswith("tags:"):
                tags = re.findall(r"[A-Za-zА-Яа-я0-9_-]+", line.split(":", 1)[1])
    headings = " ".join(_HEADING_RE.findall(body))
    h1 = _HEADING_RE.search(body)
    title = path.stem
    if h1 and h1.group(1).strip() and h1.group(1).strip() != title:
        title = f"{title} {h1.group(1).strip()}"
    return {"title": title, "headings": headings, "tags": " ".join(tags), "body": body}


def parse_plain(path: Path, rel: str, kind: str) -> dict:
    """LISP/CSV/прочее: заголовок — имя файла, тело — текст как есть."""
    text = read_text(path)
    title = rel.replace("\\", "/")
    # в LISP многострочные комментарии и строки с кириллицей полезны целиком
    return {"title": title, "headings": "", "tags": kind, "body": text}


def git_docs(limit: int = 400) -> list[dict]:
    """История коммитов как документы: удобно искать «когда/почему появилось»."""
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "log", f"-n{limit}", "--date=short",
             "--pretty=format:%h|%ad|%s"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
    except OSError:
        return []
    if out.returncode != 0:
        return []
    docs = []
    for line in out.stdout.splitlines():
        parts = line.split("|", 2)
        if len(parts) != 3:
            continue
        sha, day, subject = parts
        docs.append({
            "title": subject,
            "headings": "",
            "tags": "git",
            "body": f"{subject} ({day}, {sha})",
            "path": f"git/{sha}",
            "folder": "git",
            "kind": "git",
            "mtime": 0.0,
            "size": len(subject),
        })
    return docs


# ── разбор LISP: определения функций и кто кого вызывает ────────────────────
# Индекс FTS5 отвечает «где встречается слово», но не «какие функции внутри и
# кто их зовёт». Для вопросов о структуре кода — отдельный проход по *.lsp без
# базы: build не нужен, всегда видны текущие файлы. Кодировку разбирает
# read_text(), поэтому cp1251-модули читаются правильно.

_LISP_DEFUN_RE = re.compile(r"\(\s*defun\s+([^\s()]+)", re.IGNORECASE)
_LISP_CALL_RE = re.compile(r"\(\s*([A-Za-z0-9_:*+\-<>=?!$%&~^./]+)")
_LISP_QUOTED_RE = re.compile(r"'([A-Za-z0-9_:\-]+)")


def mask_lisp(text: str) -> str:
    """Строки и комментарии → пробелы; длины и переводы строк сохраняются.

    Нужно, чтобы скобки и «defun» внутри строк и комментариев не попадали в
    разбор. Смещения символов не меняются, поэтому по ним считается строка.
    """
    out = list(text)
    i, n = 0, len(text)
    in_str = in_block = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_str:
            if ch == "\\":
                out[i] = " "
                i += 1
                if i < n and text[i] != "\n":
                    out[i] = " "
                    i += 1
                continue
            if ch == '"':
                in_str = False
            if ch != "\n":
                out[i] = " "
            i += 1
            continue
        if in_block:
            if ch == "|" and nxt == ";":
                out[i] = " "
                out[i + 1] = " "
                i += 2
                in_block = False
                continue
            if ch != "\n":
                out[i] = " "
            i += 1
            continue
        if ch == '"':
            in_str = True
            out[i] = " "
            i += 1
            continue
        if ch == ";":
            if nxt == "|":
                out[i] = " "
                out[i + 1] = " "
                i += 2
                in_block = True
                continue
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


def lisp_parens(masked: str) -> dict[int, int]:
    """Пары «открывающая → закрывающая» скобка для замаскированного текста."""
    stack: list[int] = []
    pairs: dict[int, int] = {}
    for i, ch in enumerate(masked):
        if ch == "(":
            stack.append(i)
        elif ch == ")" and stack:
            pairs[stack.pop()] = i
    return pairs


def lisp_defuns(path: Path, rel: str) -> list[dict]:
    """Все (defun …) файла: имя, аргументы, локальные, счётчик вызовов."""
    text = read_text(path)
    masked = mask_lisp(text)
    pairs = lisp_parens(masked)
    out: list[dict] = []
    for m in _LISP_DEFUN_RE.finditer(masked):
        open_pos = m.start()
        defun_close = pairs.get(open_pos)
        args_open = masked.find("(", m.end())
        args_close = pairs.get(args_open) if args_open != -1 else None
        if defun_close is None or args_close is None or args_close > defun_close:
            continue
        name = m.group(1)
        args_raw = " ".join(masked[args_open + 1:args_close].split())
        args_part, _, locals_part = args_raw.partition("/")
        body = masked[args_close + 1:defun_close]
        calls = Counter(m2.group(1).lower() for m2 in _LISP_CALL_RE.finditer(body))
        # функции проекта часто передаются котировкой: (vl-catch-all-apply 'lcm:x …)
        for q in _LISP_QUOTED_RE.finditer(body):
            if q.group(1).lower().startswith(("lcm:", "c:")):
                calls[q.group(1).lower()] += 1
        out.append({
            "name": name,
            "file": rel,
            "line": text.count("\n", 0, open_pos) + 1,
            "args": args_part.split(),
            "locals": locals_part.split(),
            "calls": calls,
        })
    return out


def all_lisp_defuns() -> list[dict]:
    """Разбор всех *.lsp проекта (кроме служебных каталогов)."""
    defs: list[dict] = []
    for path in sorted(ROOT.rglob("*.lsp")):
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        try:
            defs.extend(lisp_defuns(path, str(rel).replace("\\", "/")))
        except OSError:
            continue
    return defs


def _project_calls(defun: dict) -> dict[str, int]:
    """Вызовы функций проекта (lcm:…, C:…), без встроенных AutoLISP."""
    return {k: v for k, v in defun["calls"].items() if k.startswith(("lcm:", "c:"))}


def _defun_callers(defs: list[dict], target: str) -> list[dict]:
    """Кто вызывает функцию (без учёта регистра), с числом вхождений."""
    rows = []
    for d in defs:
        n = d["calls"].get(target)
        if n:
            rows.append({"caller": d["name"], "file": d["file"],
                         "line": d["line"], "count": n})
    rows.sort(key=lambda r: (-r["count"], r["caller"].lower()))
    return rows


def cmd_defuns(name: str = "", as_json: bool = False) -> None:
    """`defuns` — список всех функций; `defuns <имя>` — разбор одной."""
    defs = all_lisp_defuns()
    if not defs:
        raise RuntimeError("файлы *.lsp не найдены в проекте")

    if not name:
        rows = [{"name": d["name"], "file": d["file"], "line": d["line"],
                 "calls": sum(d["calls"].values())} for d in defs]
        rows.sort(key=lambda r: r["name"].lower())
        if as_json:
            print(json.dumps(rows, ensure_ascii=False, indent=2))
            return
        width = max(len(r["name"]) for r in rows)
        print(f"{'ФУНКЦИЯ':<{width}}  ГДЕ                      ВЫЗОВОВ")
        for r in rows:
            print(f"{r['name']:<{width}}  {r['file']}:{r['line']:<7} {r['calls']}")
        print(f"\nвсего определений: {len(rows)} "
              f"в {len({r['file'] for r in rows})} файлах")
        return

    target = name.lower()
    matches = [d for d in defs if d["name"].lower() == target]
    if not matches:
        raise RuntimeError(f"функция «{name}» не найдена — список: defuns")

    callers = _defun_callers(defs, target)
    if as_json:
        payload = []
        for d in matches:
            payload.append({
                "name": d["name"], "file": d["file"], "line": d["line"],
                "args": d["args"], "locals": d["locals"],
                "calls_total": sum(d["calls"].values()),
                "calls_project": _project_calls(d),
                "callers": callers,
            })
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    for d in matches:
        proj = _project_calls(d)
        print(f"{d['name']} — {d['file']}:{d['line']}")
        print(f"  аргументы: {' '.join(d['args']) or '—'}")
        if d["locals"]:
            print(f"  локальные: {' '.join(d['locals'])}")
        print(f"  всего вызовов в теле: {sum(d['calls'].values())}")
        if proj:
            print("  вызывает функции проекта:")
            for fn, cnt in sorted(proj.items(), key=lambda kv: (-kv[1], kv[0])):
                print(f"    {fn:<34} ×{cnt}")
        rest = {k: v for k, v in d["calls"].items() if k not in proj}
        top = sorted(rest.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
        if top:
            print("  чаще всего встроенные/COM: "
                  + ", ".join(f"{k} ×{v}" for k, v in top))
        if callers:
            print("  кто вызывает:")
            for r in callers:
                print(f"    {r['caller']:<34} ×{r['count']}  "
                      f"({r['file']}:{r['line']})")
        else:
            print("  кто вызывает: никто (входная команда или пока не используется)")
        print()


def cmd_callers(name: str, as_json: bool = False) -> None:
    """Кто вызывает LISP-функцию и где она определена."""
    defs = all_lisp_defuns()
    target = name.lower()
    defined = [d for d in defs if d["name"].lower() == target]
    if not defined:
        raise RuntimeError(f"функция «{name}» не найдена — список: defuns")
    rows = _defun_callers(defs, target)
    if as_json:
        print(json.dumps({"function": defined[0]["name"],
                          "defined": [{"file": d["file"], "line": d["line"]}
                                      for d in defined],
                          "callers": rows}, ensure_ascii=False, indent=2))
        return
    print(f"{defined[0]['name']} определена в: "
          + ", ".join(f"{d['file']}:{d['line']}" for d in defined))
    if not rows:
        print("вызовов из других функций проекта нет")
        return
    width = max(len(r["caller"]) for r in rows)
    print(f"{'КТО ЗОВЁТ':<{width}}  ГДЕ                      РАЗ")
    for r in rows:
        print(f"{r['caller']:<{width}}  {r['file']}:{r['line']:<7} {r['count']}")
    print(f"\nвсего вызовов: {sum(r['count'] for r in rows)} "
          f"из {len(rows)} функций")


def scan_disk() -> dict[str, dict]:
    """Собирает документы с диска: rel-path -> разобранный документ + сигнатура."""
    docs: dict[str, dict] = {}
    for pattern, kind in PATTERNS.items():
        for path in ROOT.glob(pattern):
            if not path.is_file():
                continue
            rel = path.relative_to(ROOT)
            if any(part in SKIP_DIRS for part in rel.parts):
                continue
            rel_s = str(rel).replace("\\", "/")
            try:
                st = path.stat()
            except OSError:
                continue
            parsed = parse_markdown(path, rel_s) if kind == "md" else parse_plain(path, rel_s, kind)
            parsed.update({
                "path": rel_s,
                "folder": str(Path(rel_s).parent).replace("\\", "/"),
                "kind": kind,
                "mtime": st.st_mtime,
                "size": st.st_size,
            })
            docs[rel_s] = parsed
    # вложенные подпапки (docs/, SKILLS/**) — отдельным проходом
    by_suffix = suffix_kinds()
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in by_suffix:
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        rel_s = str(rel).replace("\\", "/")
        if rel_s in docs:
            continue
        kind = by_suffix[path.suffix.lower()]
        try:
            st = path.stat()
        except OSError:
            continue
        parsed = parse_markdown(path, rel_s) if kind == "md" else parse_plain(path, rel_s, kind)
        parsed.update({
            "path": rel_s,
            "folder": str(Path(rel_s).parent).replace("\\", "/"),
            "kind": kind,
            "mtime": st.st_mtime,
            "size": st.st_size,
        })
        docs[rel_s] = parsed
    return docs


# ── индексация ───────────────────────────────────────────────────────────────

def update_index(full: bool = False, quiet: bool = False) -> dict:
    path = db_path()
    try:
        conn = open_db(path)
    except (sqlite3.Error, OSError) as exc:
        raise RuntimeError(no_write_hint(path, exc)) from exc
    try:
        if full:
            conn.execute("DROP TABLE IF EXISTS notes_fts")
            conn.execute("DROP TABLE IF EXISTS files")
        ensure_schema(conn)

        docs = scan_disk()
        commits = git_docs() if CONFIG.get("git_history", True) else []
        known = {p: (m, s) for p, m, s in
                 conn.execute("SELECT path, mtime, size FROM files WHERE kind <> 'git'")}
        git_known = {p for (p,) in conn.execute("SELECT path FROM files WHERE kind = 'git'")}

        added = changed = 0
        for rel, doc in docs.items():
            sig = (doc["mtime"], doc["size"])
            if rel in known and abs(known[rel][0] - sig[0]) < 1e-6 and known[rel][1] == sig[1]:
                continue
            if rel in known:
                changed += 1
            else:
                added += 1
            conn.execute("DELETE FROM notes_fts WHERE path = ?", (rel,))
            conn.execute(
                "INSERT INTO notes_fts(title, headings, tags, body, path, folder, kind)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (norm_yo(doc["title"]), norm_yo(doc["headings"]), doc["tags"],
                 norm_yo(doc["body"]),
                 doc["path"], doc["folder"], doc["kind"]),
            )
            conn.execute(
                "INSERT INTO files(path, mtime, size, kind) VALUES (?, ?, ?, ?)"
                " ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime,"
                " size=excluded.size, kind=excluded.kind",
                (rel, doc["mtime"], doc["size"], doc["kind"]),
            )

        removed = 0
        for rel in list(known):
            if rel not in docs:
                conn.execute("DELETE FROM notes_fts WHERE path = ?", (rel,))
                conn.execute("DELETE FROM files WHERE path = ?", (rel,))
                removed += 1

        for doc in commits:
            if doc["path"] in git_known:
                continue
            conn.execute(
                "INSERT INTO notes_fts(title, headings, tags, body, path, folder, kind)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (norm_yo(doc["title"]), norm_yo(doc["headings"]), doc["tags"],
                 norm_yo(doc["body"]),
                 doc["path"], doc["folder"], doc["kind"]),
            )
            conn.execute("INSERT OR REPLACE INTO files(path, mtime, size, kind) VALUES (?,0,0,'git')",
                         (doc["path"],))
            added += 1

        conn.execute("INSERT INTO meta(key, value) VALUES('last_update', ?)"
                     " ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                     (str(int(time.time())),))
        conn.commit()
        total = conn.execute("SELECT count(*) FROM files").fetchone()[0]
    finally:
        conn.close()

    stats = {"db": str(path), "added": added, "changed": changed,
             "removed": removed, "total": total}
    if not quiet:
        mode = "пересобран" if full else "обновлён"
        print(f"Индекс {mode}: +{added} новых, ~{changed} изменённых, -{removed} удалённых, "
              f"всего {total}\nБаза: {path}")
    return stats


# ── поиск ────────────────────────────────────────────────────────────────────

# Служебные слова, которые ломают поиск (FTS5 требует все термы)
STOPWORDS = {
    "а", "без", "бы", "был", "была", "были", "было", "быть", "в", "вам", "вас",
    "весь", "во", "вот", "все", "всё", "вы", "где", "да", "даже", "для", "до",
    "его", "ее", "её", "если", "есть", "еще", "ещё", "же", "за", "здесь", "и",
    "из", "или", "им", "их", "к", "как", "кая", "какие", "каких", "каким", "какую", "какое", "какой", "каком", "когда", "кто", "чем", "чему", "также", "чтобы",
    "ли", "мне", "может", "мы", "на", "над", "надо", "наш", "не", "него", "нее",
    "нет", "ни", "них", "но", "ну", "о", "об", "он", "она", "они", "оно", "от",
    "по", "под", "при", "про", "с", "сам", "свой", "себе", "так", "там", "те",
    "тем", "то", "того", "тоже", "той", "только", "том", "ты", "у", "уже",
    "чего", "чей", "чем", "что", "чтобы", "эта", "эти", "это", "этот", "я",
    "the", "a", "an", "is", "are", "was", "of", "to", "in", "on", "for", "and",
    "or", "what", "how", "why", "which", "do", "does", "did", "we", "i",
}


def norm_yo(text: str) -> str:
    """ё/Ё -> е/Е: в русских текстах пишут по-разному, поиск не должен рваться."""
    return text.replace("ё", "е").replace("Ё", "Е")


def build_query(query: str, prefix: bool = False, any_term: bool = False) -> str:
    terms = [t for t in norm_yo(query).split() if t]
    if not terms:
        raise ValueError("пустой запрос")
    meaningful = [t for t in terms if t.lower() not in STOPWORDS] or terms
    quoted = ['"' + t.replace('"', '""') + '"' for t in meaningful]
    if prefix:
        quoted[-1] += "*"
    joiner = " OR " if any_term else " "
    return joiner.join(quoted)


# ── навигация: строка, раздел и выдача ровно нужного куска ───────────────────
# Расход: читать файл целиком дорого (README.md — 35 тыс. символов), а нужен
# обычно один раздел. Поэтому search сообщает строку и раздел, а show печатает
# от заголовка раздела до следующего заголовка того же или верхнего уровня.

def _file_lines(rel: str) -> list[str] | None:
    path = ROOT / rel
    if not path.is_file():
        return None
    try:
        return read_text(path).splitlines()
    except OSError:
        return None


def heading_at(lines: list[str], line_no: int) -> str:
    """Заголовок раздела, в котором лежит строка (1-based)."""
    for i in range(min(line_no, len(lines)) - 1, -1, -1):
        if lines[i].startswith("#"):
            return lines[i].lstrip("#").strip()
    return ""


def section_bounds(lines: list[str], line_no: int) -> tuple[int, int]:
    """Границы markdown-раздела вокруг строки: (первая строка, последняя), 1-based."""
    start, level = 0, 0
    for i in range(min(line_no, len(lines)) - 1, -1, -1):
        if lines[i].startswith("#"):
            start = i
            level = len(lines[i]) - len(lines[i].lstrip("#"))
            break
    end = len(lines)
    if start:
        for j in range(start + 1, len(lines)):
            s = lines[j]
            if s.startswith("#") and (len(s) - len(s.lstrip("#"))) <= level:
                end = j
                break
    else:
        for j in range(max(line_no, 1), len(lines)):
            if lines[j].startswith("#"):
                end = j
                break
    return start + 1, end


def locate(rel: str, query: str) -> tuple[int, str]:
    """Первая строка файла с любым словом запроса и её раздел."""
    lines = _file_lines(rel)
    if not lines:
        return 0, ""
    terms = [t.lower() for t in norm_yo(query).split() if t]
    for i, line in enumerate(lines, 1):
        low = norm_yo(line).lower()
        if any(t in low for t in terms):
            return i, heading_at(lines, i)
    return 0, ""


def _find_line(lines: list[str], needle: str, section_only: bool = False) -> int:
    """Номер первой строки с подстрокой; section_only — искать только в заголовках."""
    target = norm_yo(needle).lower()
    for i, line in enumerate(lines, 1):
        if section_only and not line.startswith("#"):
            continue
        if target in norm_yo(line).lower():
            return i
    return 0


def show(rel: str, at: str = "", line_range: str = "",
         max_lines: int = 160, context: int = 15,
         section_only: bool = False) -> tuple[str, dict]:
    """Кусок файла: раздел с попаданием, диапазон строк или начало файла."""
    lines = _file_lines(rel)
    if lines is None:
        raise RuntimeError(f"файл не найден в репозитории: {rel}")
    start, end = 1, min(len(lines), max_lines)
    note = ""
    if line_range:
        a, _, b = line_range.partition(":")
        start = max(1, int(a or 1))
        end = min(len(lines), int(b) if b else start + max_lines - 1)
    elif at:
        hit = _find_line(lines, at, section_only=section_only)
        if not hit:
            hint = " (заголовки: --section)" if section_only else ""
            raise RuntimeError(f"в {rel} нет строки с «{at}»{hint}")
        head = heading_at(lines, hit)
        if head:
            # markdown: печатаем раздел целиком — от заголовка до следующего
            start, end = section_bounds(lines, hit)
            note = f"раздел «{head}», строка {hit}"
        else:
            # у LISP/CSV заголовков нет — окно вокруг попадания
            start = max(1, hit - context)
            end = min(len(lines), hit + context)
            note = f"попадание в строке {hit}, ±{context} строк"
    span = end - start + 1
    if span > max_lines:
        end = start + max_lines - 1
        note = (note + ", " if note else "") + f"обрезано: строки {start}–{end} из {span}"
    body = "\n".join(f"{n:4d} {lines[n - 1]}" for n in range(start, end + 1))
    meta = {"file": rel, "from": start, "to": end,
            "file_lines": len(lines), "note": note}
    return body, meta


def search(query: str, limit: int = 8, kind: str = "", folder: str = "",
           prefix: bool = False, auto_update: bool = True,
           any_term: bool = False, raw: bool = False) -> list[dict]:
    path = db_path()
    if not path.exists():
        raise RuntimeError(f"индекс не построен ({path}) — запустите: build")
    if auto_update:
        try:
            update_index(quiet=True)
        except Exception as exc:  # noqa: BLE001 — поиск не должен падать из-за индексации
            text = str(exc)
            if "нет записи в каталог индекса" in text:
                NOTES["update"] = "нет прав на запись базы, она открыта только для чтения"
            else:
                first = text.splitlines()[0]
                NOTES["update"] = (first[:110] + "…") if len(first) > 110 else first

    # Документация и код важнее отчётов: у csv вес понижен, иначе 90 файлов
    # отчётов глушат markdown и lisp в выдаче.
    weight = ("CASE kind WHEN 'csv' THEN 0.70 WHEN 'git' THEN 0.95 "
              "WHEN 'md' THEN 1.05 ELSE 1.0 END")
    sql = ("SELECT path, folder, kind, title,"
           " snippet(notes_fts, 3, '«', '»', '…', 14) AS snip,"
           f" bm25(notes_fts, 10.0, 4.0, 6.0, 1.0) * ({weight}) AS rank"
           " FROM notes_fts WHERE notes_fts MATCH ?")
    tail = sql
    params_tail: list = []
    if kind:
        tail += " AND kind = ?"
        params_tail.append(kind)
    if folder:
        tail += " AND (folder = ? OR folder LIKE ?)"
        params_tail += [folder, folder.rstrip("/") + "%"]
    tail += " ORDER BY rank LIMIT ?"
    params_tail.append(max(1, limit))

    conn, readonly = open_read(path)
    if readonly:
        NOTES["readonly"] = "1"
    try:
        expr = query if raw else build_query(query, prefix=prefix, any_term=any_term)
        rows = conn.execute(tail, [expr, *params_tail]).fetchall()
        # Живая формулировка вопроса («что решили про допуск…») не всегда
        # содержит все слова сразу — ослабляем до ИЛИ и пробуем ещё раз.
        if not rows and not any_term:
            rows = conn.execute(tail, [build_query(query, prefix=prefix, any_term=True),
                                       *params_tail]).fetchall()
    finally:
        conn.close()
    out = []
    for p, f, k, t, s, r in rows:
        line, head = locate(p, query) if k != "git" else (0, "")
        out.append({"path": p, "folder": f, "kind": k, "title": t,
                    "snippet": " ".join(s.split()), "score": round(-r, 3),
                    "line": line, "heading": head})
    return out


def _print_hit(r: dict) -> None:
    loc = f":{r['line']}" if r.get("line") else ""
    head = f"  [{r['heading']}]" if r.get("heading") else ""
    print(f"{r['score']:>7}  [{r['kind']:<4}] {r['path']}{loc}{head}")
    print(f"         {r['snippet']}")


def status() -> dict:
    path = db_path()
    if not path.exists():
        return {"db": str(path), "exists": False}
    conn, readonly = open_read(path)
    try:
        total = conn.execute("SELECT count(*) FROM files").fetchone()[0]
        by_kind = dict(conn.execute("SELECT kind, count(*) FROM files GROUP BY kind"))
        meta = dict(conn.execute("SELECT key, value FROM meta"))
    finally:
        conn.close()
    last = meta.get("last_update", "never")
    try:
        last = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(last)))
    except (TypeError, ValueError, OSError):
        pass
    return {"db": str(path), "exists": True, "documents": total, "by_kind": by_kind,
            "size_kb": path.stat().st_size // 1024,
            "last_update": last, "readonly": readonly,
            "config": str(config_path()), "patterns": len(PATTERNS),
            "git_history": bool(CONFIG.get("git_history", True))}


# ── CLI ──────────────────────────────────────────────────────────────────────

def setup_stdout() -> None:
    """UTF-8 для вывода.

    В русской Windows Python по умолчанию пишет в консоль cp1251, а PowerShell 7
    и терминал DSH читают вывод как UTF-8 — русский текст превращается в мусор.
    Принудительный UTF-8 делает вывод читаемым и агенту, и человеку в Windows
    Terminal; для классической консоли нужен `chcp 65001`.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def main() -> int:
    setup_stdout()
    parser = argparse.ArgumentParser(description="FTS5-память проекта LayerCycleManager")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build", help="полная пересборка индекса")
    sub.add_parser("update", help="догон изменённых файлов")
    sub.add_parser("status", help="состояние индекса")
    p_init = sub.add_parser("init", help="записать memory.json со значениями по умолчанию")
    p_init.add_argument("--force", action="store_true", help="перезаписать существующий")
    p_defs = sub.add_parser("defuns", help="LISP-функции: список или разбор одной")
    p_defs.add_argument("name", nargs="?", default="",
                        help="имя функции, напр. lcm:draw-arrow")
    p_defs.add_argument("--json", action="store_true", dest="as_json")
    p_call = sub.add_parser("callers", help="кто вызывает LISP-функцию")
    p_call.add_argument("name", help="имя функции, напр. lcm:run")
    p_call.add_argument("--json", action="store_true", dest="as_json")
    s = sub.add_parser("search", help="полнотекстовый поиск")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=8)
    s.add_argument("--kind", default="", help="md|lsp|csv|py|ps1|git")
    s.add_argument("--folder", default="", help="ограничить папкой, напр. docs")
    s.add_argument("--prefix", action="store_true")
    s.add_argument("--raw", action="store_true",
                   help="передать запрос как есть (синтаксис FTS5: OR, NOT, NEAR)")
    s.add_argument("--json", action="store_true", dest="as_json")
    s.add_argument("--no-update", action="store_true")
    s.add_argument("--any", action="store_true", dest="any_term",
                   help="любое из слов (ИЛИ) вместо всех сразу")
    p_show = sub.add_parser("show", help="показать нужный кусок файла")
    p_show.add_argument("path", help="путь из выдачи search, напр. README.md")
    p_show.add_argument("--at", default="",
                        help="подстрока: печатает раздел, в котором она встретилась")
    p_show.add_argument("--lines", default="", help="диапазон строк, напр. 40:80")
    p_show.add_argument("--max", type=int, default=160, dest="max_lines",
                        help="предел строк (по умолчанию 160)")
    p_show.add_argument("--context", type=int, default=15,
                        help="±строк вокруг попадания, если у файла нет заголовков")
    p_show.add_argument("--section", action="store_true",
                        help="искать --at только среди заголовков разделов")
    p_show.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args()

    try:
        if args.cmd == "build":
            update_index(full=True)
        elif args.cmd == "update":
            update_index()
        elif args.cmd == "status":
            print(json.dumps(status(), ensure_ascii=False, indent=2))
        elif args.cmd == "init":
            print(f"конфиг записан: {write_default_config(force=args.force)}")
        elif args.cmd == "defuns":
            cmd_defuns(args.name, as_json=args.as_json)
        elif args.cmd == "callers":
            cmd_callers(args.name, as_json=args.as_json)
        elif args.cmd == "show":
            body, meta = show(args.path, at=args.at, line_range=args.lines,
                              max_lines=args.max_lines, context=args.context,
                              section_only=args.section)
            if args.as_json:
                print(json.dumps({"meta": meta, "text": body}, ensure_ascii=False, indent=2))
            else:
                if meta["note"]:
                    print(f"# {meta['file']} — {meta['note']}", file=sys.stderr)
                print(body)
        else:
            results = search(args.query, limit=args.limit, kind=args.kind,
                             folder=args.folder, prefix=args.prefix, raw=args.raw,
                             auto_update=not args.no_update, any_term=args.any_term)
            if NOTES.get("update"):
                print(f"· индекс не обновлён ({NOTES['update']}); выдача может быть неполной",
                      file=sys.stderr)
            if args.as_json:
                print(json.dumps(results, ensure_ascii=False, indent=2))
            elif not results:
                print("ничего не найдено")
            else:
                for r in results:
                    _print_hit(r)
    except (ValueError, RuntimeError) as exc:
        print(f"ОШИБКА: {exc}", file=sys.stderr)
        return 1
    except sqlite3.OperationalError as exc:
        print(f"ОШИБКА FTS5: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
