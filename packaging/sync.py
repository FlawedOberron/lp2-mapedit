#!/usr/bin/env python3
"""Copy the editor (Godot project) and the Python tools it runs into this repo:

  packaging/sync.py [--editor DIR] [--tools DIR]     (defaults ~/Projects/lp2-editor, ~/Projects/lp2-tools)

tools/ gets only what the editor needs: the scripts it runs (ENTRY) and everything they import or start
(module imports, "name.py" subprocesses, data files next to them), found by reading the sources.
"""
import argparse, os, re, shutil, sys

ENTRY = ["runtool", "lp2col", "lp2colview", "lp2library", "lp2light", "lp2mapc", "lp2mesh", "lp2pieces",
         "lp2preview", "lp2sky", "lp2project", "lp2convert"]
EDITOR_FILES = re.compile(r".*\.(gd|gdshader|uid|tscn|godot|svg|png)$|^README\.md$|^run\.sh$|^export_presets\.cfg$")


def closure(tools):
    mods = {f[:-3] for f in os.listdir(tools) if f.endswith(".py")}
    todo, seen, data = list(ENTRY), set(), set()
    while todo:
        m = todo.pop()
        if m in seen:
            continue
        seen.add(m)
        s = open(os.path.join(tools, m + ".py")).read()
        for line in re.findall(r"^\s*(?:import|from)\s+([\w., ]+)", s, re.M):
            todo += [x for x in re.split(r"[ ,]+", line.split(" import")[0]) if x in mods]
        todo += [x for x in re.findall(r'"(\w+)\.py"', s) if x in mods]
        data |= {x for x in re.findall(r'HERE,\s*"([^"]+)"', s) if not x.endswith(".py")}
    return sorted(m + ".py" for m in seen) + sorted(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--editor", default=os.path.expanduser("~/Projects/lp2-editor"))
    ap.add_argument("--tools", default=os.path.expanduser("~/Projects/lp2-tools"))
    a = ap.parse_args()
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for sub, src, files in (("editor", a.editor, [f for f in os.listdir(a.editor) if EDITOR_FILES.match(f) and os.path.isfile(os.path.join(a.editor, f))]),
                            ("tools", a.tools, closure(a.tools))):
        out = os.path.join(repo, sub)
        keep = {"export_presets.cfg", "icon.png"} if sub == "editor" else set()
        if os.path.isdir(out):
            for f in os.listdir(out):
                if f not in keep and os.path.isfile(os.path.join(out, f)):
                    os.remove(os.path.join(out, f))
        os.makedirs(out, exist_ok=True)
        for f in files:
            shutil.copy2(os.path.join(src, f), os.path.join(out, f))
        print(f"{sub}/: {len(files)} files")


if __name__ == "__main__":
    sys.exit(main())
