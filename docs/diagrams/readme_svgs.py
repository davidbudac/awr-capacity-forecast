#!/usr/bin/env python3
"""Copy the docs pages' inline diagrams into standalone SVG files for README.md.

GitHub strips inline <svg> from Markdown, so README.md shows these diagrams as
images: docs/diagrams/readme/<name>.svg. Each file is the <svg> element of a
docs page plus the docs/assets/style.css rules its classes use, with the light
and dark tokens inlined (prefers-color-scheme picks one). Edit the diagram in
its page, then run this script; --check exits 1 when a file is stale.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/diagrams/readme"
CSS = ROOT / "docs/assets/style.css"

# name -> (page, a string that occurs only in the wanted <svg ...> start tag)
DIAGRAMS = {
    "forecast": ("docs/index.html", 'class="herochart"'),
    "dataflow": ("docs/index.html", 'class="archflow"'),
    "deploy": ("docs/start.html", 'aria-labelledby="dd-deploy-title'),
    "consumers": ("docs/concepts.html", 'aria-label="Every consumer reads'),
    "alert-lifecycle": ("docs/concepts.html", 'aria-label="Alert states written'),
    "nightly": ("docs/usage.html", 'aria-labelledby="dd-jobs-title'),
}
ROOT_CLASSES = ("herochart", "archflow", "dd", "dg")


def css_rules(text):
    """Yield (selector, body) for each top-level rule; @media yields its rules
    with selector prefixed '@dark ' when the query is prefers-color-scheme:dark."""
    text = re.sub(r"/\*.*?\*/|@import[^\n]*\n", "", text, flags=re.S)
    i = 0
    while True:
        j = text.find("{", i)
        if j < 0:
            return
        sel = text[i:j].strip()
        depth, k = 1, j + 1
        while depth:
            depth += {"{": 1, "}": -1}.get(text[k], 0)
            k += 1
        body = text[j + 1:k - 1]
        if sel.startswith("@media"):
            if "prefers-color-scheme:dark" in sel.replace(" ", ""):
                for s, b in css_rules(body):
                    yield "@dark " + s, b
        elif not sel.startswith("@"):
            yield sel, body
        i = k


def tokens(rules):
    light = next(b for s, b in rules if s == ":root")
    dark = next(b for s, b in rules if s == '@dark :root:not([data-theme="light"])')
    keep = lambda b: ";".join(d.strip() for d in b.split(";") if d.strip().startswith("--"))
    return keep(light), keep(dark)


def rules_for(cls, rules):
    light, dark = [], []
    for sel, body in rules:
        is_dark = sel.startswith("@dark ")
        sel = sel.removeprefix("@dark ").replace(':root:not([data-theme="light"]) ', "")
        if "data-theme" in sel:
            continue
        parts = [p.strip() for p in sel.split(",")]
        if not all(p.startswith(f".{cls} ") for p in parts):
            continue
        body = " ".join(body.split())
        (dark if is_dark else light).append(f"{','.join(parts)}{{{body}}}")
    return light, dark


def standalone(svg, rules):
    start = svg[: svg.index(">") + 1]
    cls = re.search(r'class="([^"]+)"', start).group(1)
    assert cls in ROOT_CLASSES, cls
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', start).group(1).split()]
    light_tok, dark_tok = tokens(rules)
    light, dark = rules_for(cls, rules)
    if cls == "dd":  # its root rule sets --dd-soft; the dark one is a nested rule
        light_tok += ";--dd-soft:#6b7280"
        dark_tok += ";--dd-soft:#8a93a1"
    style = "\n".join(
        [f".{cls}{{{light_tok}}}", *light,
         "@media (prefers-color-scheme:dark){", f".{cls}{{{dark_tok}}}", *dark, "}"])
    new_start = re.sub(r"\s+", " ", start).replace(
        "<svg ", f'<svg xmlns="http://www.w3.org/2000/svg" width="{vb[2]:g}" height="{vb[3]:g}" ', 1)
    bg = f'<rect x="{vb[0]:g}" y="{vb[1]:g}" width="{vb[2]:g}" height="{vb[3]:g}" style="fill:var(--bg)"/>'
    return f"{new_start}\n<style>\n{style}\n</style>\n{bg}\n{svg[len(start):].strip()}\n"


def extract(page, marker):
    html = (ROOT / page).read_text()
    at = html.index(marker)
    s = html.rindex("<svg", 0, at)
    e = html.index("</svg>", at) + len("</svg>")
    assert html.count(marker) == 1, (page, marker)
    return html[s:e]


def main():
    check = "--check" in sys.argv[1:]
    rules = list(css_rules(CSS.read_text()))
    OUT.mkdir(exist_ok=True)
    stale = []
    for name, (page, marker) in DIAGRAMS.items():
        path = OUT / f"{name}.svg"
        text = standalone(extract(page, marker), rules)
        if check:
            if not path.exists() or path.read_text() != text:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(text)
    extra = {p.stem for p in OUT.glob("*.svg")} - DIAGRAMS.keys()
    stale += [f"docs/diagrams/readme/{n}.svg (not in DIAGRAMS)" for n in sorted(extra)]
    if stale:
        print("stale, run python3 docs/diagrams/readme_svgs.py:\n  " + "\n  ".join(stale))
        sys.exit(1)
    print(f"{len(DIAGRAMS)} README diagrams {'current' if check else 'written'}")


if __name__ == "__main__":
    main()
