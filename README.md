# Minimal reproduction — `semantic_query` returns builtins instead of project code

Context for [DeusData/codebase-memory-mcp#915](https://github.com/DeusData/codebase-memory-mcp/issues/915),
on **v0.9.0** (the issue was filed against v0.8.1).

Synthetic throwaway code: a parcel delivery service with three deliberately
unrelated domains — pricing, telemetry, routing — so every query below has one
obviously correct answer. **84 indexed nodes**; none of this needs a large graph.

Three file kinds on purpose: Python (gets vectors), plus JSON Schema and
Markdown (produce `Variable` / `Section` nodes that appear to get none).
`.cbmignore` excludes this README, because its prose contains the query terms
and would otherwise contaminate the corpus under test.

## Reproduce

```bash
git clone https://github.com/Icosa2050/cbm-semantic-query-repro
cd cbm-semantic-query-repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full
codebase-memory-mcp cli search_graph --project repro --semantic-query '["discount tariff currency"]' --limit 5
```

## Finding 1 — language builtins outrank all project code

Reproduced under every index configuration tried.

`["discount tariff currency"]` returns **no pricing code at all**:

| symbol | file | score |
| --- | --- | --- |
| `print` | `<python-builtins>` | 0.093 |
| `pop` | `<python-builtins>` | 0.079 |
| `append` | `<python-builtins>` | 0.079 |
| `upper` | `<python-builtins>` | 0.071 |
| `lower` | `<python-builtins>` | 0.068 |

`src/pricing.py` defines `compute_bulk_discount`, `apply_currency_surcharge`,
`invoice_total` and a `Tariff` dataclass. None appear at any limit.

`["waypoint graph shortest path"]` returns telemetry functions
(`tyre_pressure_low` 0.229, `battery_is_critical` 0.220,
`summarize_sensor_alarms` 0.217). `src/routing.py` defines `shortest_route`, a
Dijkstra implementation and the only correct answer. It is not returned.

**Expected:** builtin/stub nodes excluded from semantic ranking; project symbols
ranked by topical similarity.

## Finding 2 — negative cosine similarities are returned as top hits

`["battery temperature sensor"]`:

| symbol | file | score |
| --- | --- | --- |
| `invoice_total` | `src/pricing.py` | **-0.009** |
| `print` | `<python-builtins>` | **-0.012** |
| `append` | `<python-builtins>` | **-0.012** |

A per-keyword min-cosine gate — which `--help` describes — should not surface
negative similarities at all, and the whole observed score range across queries
is roughly -0.02 … 0.23. That band looks low for exact-topic matches and may
indicate a normalization problem independent of Finding 1.

## Finding 3 — `results` ignores `semantic_query`

This is what #915 reports. It may be intended.

With `semantic_query` as the only argument, `results` is byte-for-byte identical
for every query, alphabetical by `name`, `total` equal to the full node count:

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

Per `cli search_graph --help`, semantic output is documented to land in
`semantic_results`; with no `query` / `name_pattern` / `label` supplied there is
nothing to filter `results` by. If that is the intent, #915's
`LEFT JOIN node_vectors` diagnosis may be aimed at the wrong field — worth a
maintainer ruling either way.

It still misleads: `total: 84` beside a populated `results` array reads as
"84 matches," and every visible row is a node that should have no vector.
Verbose logs show the vector search runs, then its candidates are absent:

```
level=info msg=vector_search.exec kw_count=1 fetch_limit=15 project=repro
level=info msg=vector_search.done candidates=15
{"total":84,"results":[ ... 84 nodes, alphabetical ... ]}
```

## Finding 4 — `.cbmignore` is not re-evaluated on re-index

Separate bug, found while building this repro.

Adding a pattern to `.cbmignore` and re-running `index_repository` against an
**existing** project leaves the newly-ignored files in the graph:

```bash
echo 'README.md' > .cbmignore
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'README%'
# -> total: 12   (README nodes still indexed)

codebase-memory-mcp cli delete_project --project repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'README%'
# -> total: 0    (correct)
```

`delete_project` first is currently required for ignore-rule changes to apply.

## Control — the index is sound

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

BM25 is exactly right, and `name_pattern` is unaffected. The defect is confined
to `semantic_query`.

## Stability, honestly

- **Deterministic for a built index.** Same query, 3 consecutive runs → identical
  scores. Re-indexing unchanged content → identical scores.
- **Not stable across rebuilds.** Scores and ordering shifted when the corpus
  changed and again when only the `--name` changed (the project name prefixes
  every `qualified_name`). One early build did rank the telemetry query
  correctly; later builds of equivalent content did not, and I could not isolate
  which variable is responsible. Reported as an observation, not a diagnosis.
- Findings 1–4 held under every configuration tried.

## Not reproduced here

On a larger private graph (~44k nodes) the same path returned rows whose `name`
did not match their own `qualified_name` / `file_path` — e.g. `name: "$defs"`
carrying `qualified_name: ...ValidationChangeType.removed`. That does **not**
occur in this repro, where every `name` matches. Recorded in case it shares a
root cause; it needs its own reproduction.

## Environment

- `codebase-memory-mcp` 0.9.0
- macOS 15 (Darwin 25.5.0), arm64
- Index mode: `full`
