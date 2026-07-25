# Minimal reproduction — `semantic_query` rankings are corpus-fitted, not semantic

Context for [DeusData/codebase-memory-mcp#915](https://github.com/DeusData/codebase-memory-mcp/issues/915),
on **v0.9.0** (the issue was filed against v0.8.1).

Synthetic throwaway code: a parcel delivery service with three deliberately
unrelated domains — pricing, telemetry, routing — so every query below has one
obviously correct answer. **93 nodes**; none of this needs a large graph.

Three file kinds on purpose: Python (gets vectors), plus JSON Schema and
Markdown (produce `Variable` / `Section` nodes that appear to get none).

## Reproduce

```bash
git clone https://github.com/<owner>/cbm-semantic-query-repro
cd cbm-semantic-query-repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full
codebase-memory-mcp cli search_graph --project repro --semantic-query '["waypoint graph shortest path"]' --limit 5
```

## Finding 1 — ranking inverts when one unrelated file is added

The headline. Ranking is **deterministic for a given index** but **unstable
across re-indexes of near-identical content**, and the shift is not a small
reordering — it inverts.

Indexing the three source files alone gives **84 nodes** and a correct answer
for the telemetry query:

| query | top 3 | verdict |
| --- | --- | --- |
| `["battery temperature sensor"]` | `refrigeration_breached` 0.068, `battery_is_critical` 0.065, `summarize_sensor_alarms` 0.062 | correct |

Adding this README — one Markdown file, no code — gives **93 nodes**, and the
same query collapses:

| query | top 3 | verdict |
| --- | --- | --- |
| `["battery temperature sensor"]` | `invoice_total` **-0.009**, `print` **-0.012**, `append` **-0.012** | wrong domain, all scores negative |
| `["waypoint graph shortest path"]` | `tyre_pressure_low` 0.229, `battery_is_critical` 0.220, `summarize_sensor_alarms` 0.217 | telemetry wins a routing query; `shortest_route` absent |

`src/routing.py` defines `shortest_route`, a Dijkstra implementation — the only
correct answer to that third query. It is not returned at any limit.

### It is not random seeding

- Same index, same query, 3 consecutive runs → byte-identical scores.
- Re-indexing **unchanged** content twice → byte-identical scores.
- Adding one Markdown file → completely different ordering and sign.

So the vectors appear to be **fitted to the corpus** (TF-IDF / hashing /
SVD-like) rather than produced by a pretrained embedding model. That single
hypothesis explains everything observed here:

- cosine scores confined to roughly -0.02 … 0.23, where exact-topic matches
  should be far higher;
- **negative** similarities surfacing as top-ranked results;
- corpus sensitivity — the space is refit when documents change;
- no vocabulary bridging (in a separate private test, a German query never
  reached the equivalent English identifiers).

## Finding 2 — language builtins are embedded and outrank project code

`["discount tariff currency"]` returns **no pricing code at all**, on both the
84-node and 93-node indexes:

| symbol | file | score (93-node) |
| --- | --- | --- |
| `print` | `<python-builtins>` | 0.093 |
| `pop` | `<python-builtins>` | 0.079 |
| `append` | `<python-builtins>` | 0.079 |
| `upper` | `<python-builtins>` | 0.071 |
| `lower` | `<python-builtins>` | 0.068 |

`src/pricing.py` defines `compute_bulk_discount`, `apply_currency_surcharge`,
`invoice_total` and a `Tariff` dataclass. None appear.

Interpreter builtins are generic high-frequency tokens, so under a corpus-fitted
scheme they would naturally accumulate undifferentiated weight — consistent with
Finding 1.

**Expected:** stub/builtin nodes excluded from semantic ranking.

## Finding 3 — `results` ignores `semantic_query` entirely

Possibly working as intended; recorded because it is what #915 reports.

With `semantic_query` as the only argument, `results` is byte-for-byte identical
for every query, alphabetical by `name`, `total` equal to the full node count:

```json
{
  "total": 93,
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
`semantic_results`, and with no `query` / `name_pattern` / `label` supplied there
is nothing to filter `results` by — so this may be by design, and #915's
`LEFT JOIN node_vectors` diagnosis may be aimed at the wrong field.

It still misleads: `total: 93` beside a populated `results` array reads as
"93 matches," and every visible row is a node that should have no vector.
Verbose logs show the vector search runs and its candidates are then absent:

```
level=info msg=vector_search.exec kw_count=1 fetch_limit=15 project=repro
level=info msg=vector_search.done candidates=15
{"total":93,"results":[ ... 93 nodes, alphabetical ... ]}
```

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

## Reproducing the 84-node baseline

`git rm README.md` (or index a checkout of the first commit) and re-index. The
telemetry query becomes correct again. That transition is Finding 1.

## Not reproduced here

On a larger private graph (~44k nodes) the same path returned rows whose `name`
did not match their own `qualified_name` / `file_path` — e.g. `name: "$defs"`
carrying `qualified_name: ...ValidationChangeType.removed`. That does **not**
occur in this 93-node repro, where every `name` matches. Recorded in case it
shares a root cause; it needs its own reproduction.

## Environment

- `codebase-memory-mcp` 0.9.0
- macOS 15 (Darwin 25.5.0), arm64
- Index mode: `full`
