import glob, os, re

W = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = r"[A-Za-z][A-Za-z0-9:_>!?*+<>=/-]*"


def read(path):
    raw = open(path, "rb").read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1251")


def strip_code(text):
    out, i, n, in_str = [], 0, len(text), False
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
    return "".join(out)


files = sorted(glob.glob(os.path.join(W, "lcm_*.lsp")))
defined, code = set(), {}
for f in files:
    code[f] = strip_code(read(f))
    for m in re.finditer(r"\(defun\s+([^\s()]+)", code[f]):
        defined.add(m.group(1).lower())

problems = []
for f in files:
    for m in re.finditer(r"\(" + NAME, code[f]):
        name = m.group(0)[1:]
        low = name.lower().lstrip("'")
        if not (low.startswith("lcm:") or low.startswith("c:lcm")):
            continue
        if low in defined:
            continue
        problems.append((os.path.basename(f), name))

print("Модулей: %d | определено функций: %d" % (len(files), len(defined)))
if problems:
    print("ВЫЗОВЫ БЕЗ ОПРЕДЕЛЕНИЯ (%d):" % len(problems))
    for f, n in problems:
        print("   %-18s %s" % (f, n))
else:
    print("ВЫЗОВЫ БЕЗ ОПРЕДЕЛЕНИЯ: нет")

ui = [n for n in defined if n.startswith("lcm:ui-") or n.startswith("c:")]
print("\nПроверено команд и функций UI: %d" % len(ui))
print("Все команды LCM: " + ", ".join(sorted(n.upper() for n in defined if n.startswith("c:"))))