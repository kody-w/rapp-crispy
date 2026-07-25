#!/usr/bin/env python3
"""Enforce a personal dictionary on a transcript read from stdin.

Prompt biasing alone gets "Kody" right and still lands "OpenRapter", so the
canonical spelling is enforced after decoding as well. Mirrors what RAPP Voice
does in Lua, including `heard => Term` rewrite lines for true homophones.

usage: dictfix.py <dictionary.txt>   (transcript on stdin, result on stdout)
"""
import re
import sys


def bounded(s: str) -> str:
    """Word-bounded pattern, omitting a boundary on an edge that is not a word
    char — otherwise terms like C++ or F# can never match."""
    pat = re.escape(s)
    if s[:1].isalnum():
        pat = r"\b" + pat
    if s[-1:].isalnum():
        pat = pat + r"\b"
    return pat


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: dictfix.py <dictionary.txt>\n")
        return 2
    terms, subs = [], []
    try:
        lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
    except OSError:
        sys.stdout.write(sys.stdin.read())
        return 0
    for line in lines:
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        if "=>" in t:
            heard, meant = t.split("=>", 1)
            heard, meant = heard.strip(), meant.strip()
            if heard:
                subs.append((heard, meant))
                terms.append(meant)
        else:
            terms.append(t)

    text = sys.stdin.read()
    # most specific rewrite first
    for heard, meant in sorted(subs, key=lambda x: -len(x[0])):
        text = re.sub(bounded(heard), lambda m, r=meant: r, text, flags=re.I)
    for term in terms:
        text = re.sub(bounded(term), lambda m, r=term: r, text, flags=re.I)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
