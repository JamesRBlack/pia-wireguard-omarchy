#!/usr/bin/env python3
"""Flags a QML property bound twice in the same object, e.g. two
`font.pixelSize:` lines in one Text. The shell refuses to load such a file
("Property value set multiple times"), and qmllint without the shell's own
modules does not report it. Usage: tools/check-qml.py FILE.qml..."""
import re
import sys

BINDING = re.compile(r'^\s*([A-Za-z_][\w.]*)\s*:(?!:)')
# Lines that open a JavaScript block, whose contents are statements, not bindings.
JS_BLOCK = re.compile(r'(\bfunction\b|=>|^\s*on[A-Z]\w*\s*:\s*(function\b.*)?\{)')


def check(path):
    errors = 0
    stack = [{}]  # one dict of seen bindings per open object
    js_depth = []  # brace depths at which a JS block opened
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = re.sub(r'"(\\.|[^"\\])*"', '""', raw.split("//")[0])
        in_js = bool(js_depth)
        m = BINDING.match(line)
        if m and not in_js and len(stack) > 1:
            name = m.group(1)
            seen = stack[-1]
            if name in seen:
                print(f"{path}:{n}: '{name}' already set on line {seen[name]}")
                errors += 1
            else:
                seen[name] = n
        for ch in line:
            if ch == "{":
                if JS_BLOCK.search(line) or js_depth:
                    js_depth.append(len(stack))
                stack.append({})
            elif ch == "}":
                stack.pop()
                if js_depth and js_depth[-1] == len(stack):
                    js_depth.pop()
    return errors


sys.exit(1 if sum(check(p) for p in sys.argv[1:]) else 0)
