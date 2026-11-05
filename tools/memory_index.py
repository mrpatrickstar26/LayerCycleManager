# -*- coding: utf-8 -*-
"""memory_index.py — полнотекстовая память проекта LayerCycleManager (SQLite FTS5).

Идея взята из ObsidianDataWeave (scripts/memory_index.py), но заточена под наш
корпус: markdown-документация, LISP-модули в Windows-1251, CSV-отчёты и история
git — всё в одном индексе. Зависимостей нет: только stdlib (sqlite3).

База лежит ВНЕ репозитория:
    %LOCALAPPDATA%\\cache\\lcm-memory\\<slug>-<hash>.db
Каталог можно переопределить переменной LCM_MEMORY_DIR — это нужно, когда
запись вне рабочей папки запрещена (песочница DSH: только workspace-write).

Команды (в Windows вызывать через py -3, если python — заглушка Store):
    py -3 tools/memory_index.py build              # полная пересборка
    py -3 tools/memory_index.py update             # догон по mtime/size
    py -3 tools/memory_index.py status             # что в индексе
    py -3 tools/memory_index.py search "запрос" [--limit 8] [--kind md] [--json]

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
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# По умолчанию база вне репозитория. LCM_MEMORY_DIR позволяет увести её в
# доступный на запись каталог (например, <репозиторий>\.dsh\memory в песочнице).
DB_DIR = Path(
    os.environ.get("LCM_MEMORY_DIR")
    or (Path(os.environ.get("LOCALAPPDATA", Path.home())) / "cache" / "lcm-memory")
)

# Негромкие предупреждения для CLI: «индекс не обновлён», «база только для чтения».
NOTES: dict[str, str] = {}

# Что индексируем и с каким «видом»
PATTERNS = {
    "*.md": "md",
    "*.lsp": "lsp",
    "*.dcl": "dcl",
    "*.py": "py",
    "*.ps1": "ps1",
    "*.cjs": "js",
    "reports/*.csv": "csv",
}

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".dsh",
             ".idea", ".vscode", ".pytest_cache"}

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
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in (".md", ".lsp", ".py", ".ps1", ".cjs"):
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        rel_s = str(rel).replace("\\", "/")
        if rel_s in docs:
            continue
        kind = {".md": "md", ".lsp": "lsp", ".py": "py", ".ps1": "ps1", ".cjs": "js"}[path.suffix.lower()]
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
        commits = git_docs()
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


def search(query: str, limit: int = 8, kind: str = "", folder: str = "",
           prefix: bool = False, auto_update: bool = True,
           any_term: bool = False) -> list[dict]:
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
        rows = conn.execute(tail, [build_query(query, prefix=prefix, any_term=any_term),
                                   *params_tail]).fetchall()
        # Живая формулировка вопроса («что решили про допуск…») не всегда
        # содержит все слова сразу — ослабляем до ИЛИ и пробуем ещё раз.
        if not rows and not any_term:
            rows = conn.execute(tail, [build_query(query, prefix=prefix, any_term=True),
                                       *params_tail]).fetchall()
    finally:
        conn.close()
    return [{"path": p, "folder": f, "kind": k, "title": t,
             "snippet": " ".join(s.split()), "score": round(-r, 3)}
            for p, f, k, t, s, r in rows]


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
            "last_update": last, "readonly": readonly}


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
    s = sub.add_parser("search", help="полнотекстовый поиск")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=8)
    s.add_argument("--kind", default="", help="md|lsp|csv|py|ps1|git")
    s.add_argument("--folder", default="", help="ограничить папкой, напр. docs")
    s.add_argument("--prefix", action="store_true")
    s.add_argument("--json", action="store_true", dest="as_json")
    s.add_argument("--no-update", action="store_true")
    s.add_argument("--any", action="store_true", dest="any_term",
                   help="любое из слов (ИЛИ) вместо всех сразу")
    args = parser.parse_args()

    try:
        if args.cmd == "build":
            update_index(full=True)
        elif args.cmd == "update":
            update_index()
        elif args.cmd == "status":
            print(json.dumps(status(), ensure_ascii=False, indent=2))
        else:
            results = search(args.query, limit=args.limit, kind=args.kind,
                             folder=args.folder, prefix=args.prefix,
                             auto_update=not args.no_update)
            if NOTES.get("update"):
                print(f"· индекс не обновлён ({NOTES['update']}); выдача может быть неполной",
                      file=sys.stderr)
            if args.as_json:
                print(json.dumps(results, ensure_ascii=False, indent=2))
            elif not results:
                print("ничего не найдено")
            else:
                for r in results:
                    print(f"{r['score']:>7}  [{r['kind']:<4}] {r['path']}\n         {r['snippet']}")
    except (ValueError, RuntimeError) as exc:
        print(f"ОШИБКА: {exc}", file=sys.stderr)
        return 1
    except sqlite3.OperationalError as exc:
        print(f"ОШИБКА FTS5: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
