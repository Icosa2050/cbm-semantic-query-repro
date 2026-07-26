#!/usr/bin/env python3
"""Normalise `cli search_graph` output across releases.

v0.9.0 emits flat objects:
    {"total": N, "results": [{...}], "semantic_results": [{"name":..,"score":..}]}

Later builds emit a column-oriented tree model:
    {"total": N, "cols": [...], "groups": [{"file":..,"rows":[[...]]}],
     "semantic": {"cols":["qn","label","file","score"], "rows": [[...]]}}

Both are reduced to the same shape and printed as TSV so shell callers do not
need to know which server they are talking to.

    <mode>  = semantic | results | total
    stdout  = one row per line: name<TAB>file<TAB>score      (semantic)
              one row per line: qualified_name<TAB>file      (results)
              a single integer                                (total)
"""
import json
import sys


def _rows(block):
    """Map a {cols, rows} block into a list of dicts."""
    cols = block.get("cols") or []
    return [dict(zip(cols, r)) for r in block.get("rows") or []]


def semantic(doc):
    if isinstance(doc.get("semantic_results"), list):          # v0.9.0
        return [
            (d.get("name", ""), d.get("file_path", ""), d.get("score", 0.0))
            for d in doc["semantic_results"]
        ]
    block = doc.get("semantic")                                 # newer
    if isinstance(block, dict):
        out = []
        for d in _rows(block):
            qn = d.get("qn", "")
            out.append((qn.rsplit(".", 1)[-1], d.get("file", ""), d.get("score", 0.0)))
        return out
    return []


def results(doc):
    if isinstance(doc.get("results"), list):                    # v0.9.0
        return [
            (d.get("qualified_name", ""), d.get("file_path", ""))
            for d in doc["results"]
        ]

    out = []
    for g in doc.get("groups") or []:                           # newer, grouped
        prefix, f = g.get("qn_prefix", ""), g.get("file", "")
        cols = doc.get("cols") or []
        for r in g.get("rows") or []:
            d = dict(zip(cols, r))
            out.append((f"{prefix}.{d.get('name','')}", f))
    if out:
        return out

    # newer, ungrouped: BM25 answers arrive as a flat top-level cols/rows table
    # carrying fully-qualified names and their own file column.
    for d in _rows(doc):
        qn = d.get("qn") or d.get("name") or ""
        if qn:
            out.append((qn, d.get("file", "")))
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "semantic"
    raw = sys.stdin.read()
    start = raw.find("{")
    if start < 0:
        return 1
    try:
        doc = json.loads(raw[start:])
    except json.JSONDecodeError:
        return 1

    if mode == "total":
        print(doc.get("total", 0))
    elif mode == "results":
        for qn, f in results(doc):
            print(f"{qn}\t{f}")
    else:
        for name, f, score in semantic(doc):
            print(f"{name}\t{f}\t{score}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
