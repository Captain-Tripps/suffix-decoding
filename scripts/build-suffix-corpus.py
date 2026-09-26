#!/usr/bin/env python3
"""Build a --spec-suffix-corpus JSON file from text/markdown/json sources.

The suffix trie only grows and every entry is tokenized at model load, so feed it
only material that actually recurs in the target workload: prior model outputs
(previous chapter prose), the character/world bible, the house style guide,
frequently-used JSON schemas, stable tool-call templates.

Usage:
  python build-suffix-corpus.py -o corpus.json prev_chapter.md bible.md style.md
  python build-suffix-corpus.py -o corpus.json --glob "book/ch0*.md"

Accepts .txt/.md (whole file = one entry) and .json (a string, array of strings,
{"content": ...} or {"messages": [...]} — passed through as-is, flattened).
"""
from __future__ import annotations
import argparse, glob, json, sys
from pathlib import Path


def load_one(p: Path):
    if p.suffix.lower() == ".json":
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else [data]
    text = p.read_text(encoding="utf-8").strip()
    return [text] if text else []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sources", nargs="*", help="text/md/json files")
    ap.add_argument("--glob", action="append", default=[], help="glob pattern (repeatable)")
    ap.add_argument("-o", "--out", required=True, help="output corpus .json")
    ap.add_argument("--max-chars", type=int, default=0,
                    help="skip entries longer than this many chars (0 = no limit)")
    args = ap.parse_args()

    paths: list[Path] = [Path(s) for s in args.sources]
    for g in args.glob:
        paths += [Path(x) for x in glob.glob(g, recursive=True)]
    if not paths:
        ap.error("no sources given")

    entries: list = []
    for p in paths:
        if not p.is_file():
            print(f"skip (not a file): {p}", file=sys.stderr)
            continue
        for e in load_one(p):
            if args.max_chars and isinstance(e, str) and len(e) > args.max_chars:
                print(f"skip (>{args.max_chars} chars): {p}", file=sys.stderr)
                continue
            entries.append(e)
        print(f"added {p}", file=sys.stderr)

    Path(args.out).write_text(json.dumps(entries, ensure_ascii=False), encoding="utf-8")
    n_chars = sum(len(e) for e in entries if isinstance(e, str))
    print(f"wrote {args.out}: {len(entries)} entries, ~{n_chars:,} chars "
          f"(~{n_chars // 4:,} tokens rough)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
