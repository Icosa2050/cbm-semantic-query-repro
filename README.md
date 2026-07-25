# Minimal reproduction — `semantic_query` ranking is dominated by language builtins

Context for [DeusData/codebase-memory-mcp#915](https://github.com/DeusData/codebase-memory-mcp/issues/915),
on **v0.9.0** (the issue was filed against v0.8.1).

This repository is synthetic throwaway code: a parcel delivery service with
three deliberately unrelated domains — pricing, telemetry, routing — so every
query below has one obviously correct answer.

- **84 nodes.** Neither finding needs a large graph.
- Three file kinds on purpose: Python (gets vectors), plus JSON Schema and
  Markdown (produce `Variable` / `Section` nodes that appear to get none).

## Reproduce

```bash
git clone https://github.com/<owner>/cbm-semantic-query-repro
cd cbm-semantic-query-repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full
codebase-memory-mcp cli search_graph --project repro --semantic-query '["battery temperature sensor"]' --limit 5
codebase-memory-mcp cli search_graph --project repro --semantic-query '["discount tariff currency"]'   --limit 5
```

## Finding 1 — builtins are embedded and outrank project code

This is in `semantic_results`, which per `cli search_graph --help` is the
documented destination for `semantic_query` output.

`["battery temperature sensor"]` is correct:

| symbol | file | score |
| --- | --- | --- |
| `refrigeration_breached` | `src/telemetry.py` | 0.068 |
| `battery_is_critical` | `src/telemetry.py` | 0.065 |
| `summarize_sensor_alarms` | `src/telemetry.py` | 0.062 |

`["discount tariff currency"]` returns **no pricing code at all** — five Python
builtins, each scoring higher than the best correct hit above:

| symbol | file | score |
| --- | --- | --- |
| `print` | `<python-builtins>` | 0.123 |
| `append` | `<python-builtins>` | 0.114 |
| `pop` | `<python-builtins>` | 0.108 |
| `upper` | `<python-builtins>` | 0.100 |
| `lower` | `<python-builtins>` | 0.097 |

`src/pricing.py` defines `compute_bulk_discount`, `apply_currency_surcharge`,
`invoice_total` and a `Tariff` dataclass. None are returned.

`["waypoint graph shortest path"]` likewise misses `shortest_route` — the
Dijkstra implementation, and the only correct answer — while returning
`builtins.len`.

Scores stay in a 0.01–0.12 band throughout, which looks low for exact-topic
matches and may indicate a normalization issue alongside the stub pollution.

**Expected:** builtin/stub nodes excluded from semantic ranking, or scored in
the same normalized space as project symbols.

## Finding 2 — `results` is unranked and identical across queries

Possibly working as intended; recorded because it is what #915 reports.

When `semantic_query` is the only argument, `results` comes back byte-for-byte
identical for every query, alphabetical by `name`, with `total` equal to the
full node count:

```json
{
  "total": 84,
  "results": [
    { "name": "\"Deferred Until\" Conditions", "label": "Section",  "file_path": "docs/decisions.md" },
    { "name": "$defs",                          "label": "Variable", "file_path": "schemas/parcel.schema.json" },
    { "name": "$id",                            "label": "Variable", "file_path": "schemas/parcel.schema.json" },
    { "name": "$ref",                           "label": "Variable", "file_path": "schemas/parcel.schema.json" },
    { "name": "$schema",                        "label": "Variable", "file_path": "schemas/parcel.schema.json" }
  ],
  "has_more": true
}
```

Three unrelated queries — `["battery temperature sensor"]`,
`["discount tariff currency"]`, `["waypoint graph shortest path"]` — produce
exactly these five rows.

Reading `--help`, this may be correct: semantic output is documented to land in
`semantic_results`, and with no `query` / `name_pattern` / `label` supplied
there is nothing to filter `results` by, so it degenerates to "every node,
alphabetical." If so, #915's diagnosis (`LEFT JOIN node_vectors` with NULLs
sorting first) may be aimed at the wrong field.

Either way the API is easy to misread: `total: 84` alongside a populated
`results` array reads as "84 matches," and every visible row is a node that
should have no vector. Worth either filtering `results` when `semantic_query`
is the sole argument, or documenting the split more loudly.

Verbose CLI logging shows the vector search does run and produce candidates,
which are then absent from `results`:

```
level=info msg=vector_search.exec kw_count=1 fetch_limit=15 project=repro
level=info msg=vector_search.done candidates=15
{"total":84,"results":[ ... 84 nodes, alphabetical ... ]}
```

## Control — the index is sound

BM25 over the same phrase is exactly right:

```bash
codebase-memory-mcp cli search_graph --project repro --query "discount tariff currency" --limit 5
```

```json
{
  "total": 3,
  "search_mode": "bm25",
  "results": [
    { "name": "compute_bulk_discount",    "file_path": "src/pricing.py" },
    { "name": "apply_currency_surcharge", "file_path": "src/pricing.py" },
    { "name": "Tariff",                   "file_path": "src/pricing.py" }
  ]
}
```

`name_pattern` is likewise unaffected. Only `semantic_query` misbehaves.

## Not reproduced here

On a larger private graph (~44k nodes) the same path returned rows whose `name`
did not correspond to their own `qualified_name` / `file_path` — e.g.
`name: "$defs"` carrying `qualified_name: ...ValidationChangeType.removed`.
That does **not** occur in this 84-node repro, where every `name` matches its
`qualified_name`. Recorded only in case it shares a root cause; it needs its
own reproduction.

## Environment

- `codebase-memory-mcp` 0.9.0
- macOS 15 (Darwin 25.5.0), arm64
- Index mode: `full`
