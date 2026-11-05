# Проверка баланса скобок и строк в AutoLISP-файлах.
# Использование: py -3 tools/lisp_check.py lcm_*.lsp   (шаблон разворачивается и в PowerShell)
import glob, sys, os

def strip_code(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out), in_str

def check(path):
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8"); enc = "utf-8"
    except UnicodeDecodeError:
        text = raw.decode("cp1251"); enc = "cp1251"
    code, in_str = strip_code(text)
    depth = 0; min_depth = 0; line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < min_depth:
                min_depth = depth
    ok = (depth == 0 and min_depth == 0 and not in_str)
    print("%-22s enc=%-6s итоговая_глубина=%-3d мин_глубина=%-3d незакрытая_строка=%-5s строк=%d  %s"
          % (os.path.basename(path), enc, depth, min_depth, in_str, line, "OK" if ok else "ОШИБКА"))
    return ok

if __name__ == "__main__":
    # Русская Windows: Python пишет cp1251, а PowerShell 7 и терминал DSH читают
    # UTF-8 — без этого отчёт проверки выводится мусором.
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    bad = 0
    # PowerShell не раскрывает шаблоны сам (в отличие от bash), поэтому
    # `lcm_*.lsp` разворачиваем здесь — документированная команда работает в обеих оболочках.
    paths = []
    for arg in sys.argv[1:]:
        matched = glob.glob(arg)
        paths.extend(matched or [arg])
    for p in paths:
        if not check(p):
            bad += 1
    sys.exit(1 if bad else 0)