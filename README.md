# Minimal reproduction — `semantic_query` returns builtins instead of project code

Context for [DeusData/codebase-memory-mcp#915](https://github.com/DeusData/codebase-memory-mcp/issues/915),
on **v0.9.0** (the issue was filed against v0.8.1).

Synthetic throwaway code: a parcel delivery service with three deliberately
unrelated domains — pricing, telemetry, routing — so every query below has one
obviously correct answer. **84 indexed nodes**; none of this needs a large graph.

Three file kinds on purpose: Python (gets vectors), plus JSON Schema and
Markdown (produce `Variable` / `Section` nodes that appear to get none).
`.cbmignore` excludes `README.md` and `verify.sh`: both mention the query terms,
and both would otherwise contaminate the corpus under test. Adding `verify.sh`
to the corpus moves every score — see Finding 3.

### Verification performed

| | |
| --- | --- |
| Clean `git clone` into unrelated directories | identical |
| Virgin `CBM_CACHE_DIR` | identical |
| **macOS 15 / arm64** vs **Linux 7.0 / x86_64**, both v0.9.0 | **identical to 8 decimals** |

Nothing here depends on prior local state, on the checkout path, or on the
platform. `verify.sh` returned 6/6 on both machines with the same `results`
hash.

### What is being claimed

The **claims are the orderings** — builtins ranking above project code, negative
similarities appearing at all, rank changing with the project name. Exact scores
are quoted because they proved stable across both platforms tested, so a
mismatch is informative. But if your digits differ and `<python-builtins>` still
outranks `src/pricing.py`, that is still the bug.

Two scope limits worth knowing before you spend time:

- **Finding 1 may be Python-specific.** `<python-builtins>` nodes come from the
  Python resolver. A TypeScript or Go corpus may show no builtin pollution.
- **This install ships no embedding model** — no ONNX, tokenizer, or vocab
  assets anywhere under the install or cache directories. Together with the
  project-name sensitivity in Finding 3, that suggests vectors derived from
  identifier text per project rather than a pretrained code embedding. If
  `semantic_query` is intended to be lexical rather than neural, then Findings
  1–3 are a documentation and expectations problem rather than a ranking bug,
  and a maintainer ruling on that would settle it quickly.

## Reproduce

```bash
git clone https://github.com/Icosa2050/cbm-semantic-query-repro
cd cbm-semantic-query-repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full
codebase-memory-mcp cli search_graph --project repro --semantic-query '["discount tariff currency"]' --limit 5
```

## Finding 1 — language builtins outrank all project code

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

## Finding 2 — negative cosine similarities returned as top hits

`["battery temperature sensor"]`:

| symbol | file | score |
| --- | --- | --- |
| `invoice_total` | `src/pricing.py` | **-0.008916** |
| `print` | `<python-builtins>` | **-0.011670** |
| `append` | `<python-builtins>` | **-0.011673** |

`--help` describes a per-keyword min-cosine gate, which should not surface
negative similarities at all. The observed range across all queries is roughly
-0.015 … 0.229 — low for exact-topic matches, suggesting a normalization problem
independent of Finding 1.

## Finding 3 — scores depend on the project name

Same clone, same commit, byte-identical source; only `--name` differs:

```bash
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro     --mode full
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name othername --mode full
codebase-memory-mcp cli search_graph --project repro     --semantic-query '["battery temperature sensor"]' --limit 4
codebase-memory-mcp cli search_graph --project othername --semantic-query '["battery temperature sensor"]' --limit 4
```

| rank | `--name repro` | `--name othername` |
| --- | --- | --- |
| 1 | `invoice_total` -0.00891594 | `split_into_legs` -0.00888523 |
| 2 | `print` -0.01167019 | `print` -0.01166980 |
| 3 | `append` -0.01167298 | `append` -0.01167576 |
| 4 | `pop` -0.01464620 | `invoice_total` -0.01185947 |

`invoice_total` moves from rank 1 to rank 4 and its score changes by ~33%. The
project name prefixes every `qualified_name`, so this is consistent with vectors
derived from identifier text rather than a pretrained code embedding — but that
is a hypothesis, not a diagnosis. The reproducible fact is that **an arbitrary
project label changes semantic similarity between code symbols.**

## Finding 4 — re-index applies `.cbmignore` inclusions but not exclusions

Separate bug, found while building this repro. Replayable from a clean clone.
Note the ignore file must keep `README.md` and `verify.sh` listed, or you are
changing two variables at once.

```bash
# docs/decisions.md starts indexed
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'docs/decisions%'
# -> total: 6

printf 'README.md\nverify.sh\ndocs/decisions.md\n' > .cbmignore
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full   # -> nodes: 84 (unchanged)
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'docs/decisions%'
# -> total: 6    (still indexed; the new ignore rule had no effect)

codebase-memory-mcp cli delete_project --project repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full   # -> nodes: 78
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'docs/decisions%'
# -> total: 0    (correct)
```

The update is **additive-only**. Dropping a name from `.cbmignore` so a file
becomes newly *eligible* is picked up by a plain re-index; adding a name so a
file becomes newly *ignored* is not. Removing `verify.sh` from the ignore list
and re-indexing takes the graph 84 -> 101 (its 17 nodes are added immediately),
while `docs/decisions.md` stays indexed in the same run.

`delete_project` first is currently required for any exclusion to take effect.

## Finding 5 — `results` ignores `semantic_query`

This is what #915 reports. It may be intended.

With `semantic_query` as the only argument, `results` is byte-for-byte identical
for every query, alphabetical by `name`, `total` equal to the full node count.
Verified by hashing the rows from three unrelated queries — all three hash the
same:

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

## Determinism

- **Stable for a given index.** Same query, 3 consecutive runs → identical
  scores. Re-indexing unchanged content → identical scores.
- **Path-independent.** A clean clone into an unrelated directory reproduces
  every score above to the digit.
- **Not stable across index identity.** See Finding 3.
- One early build did rank `["battery temperature sensor"]` correctly
  (`refrigeration_breached` 0.068, `battery_is_critical` 0.065). Later builds of
  equivalent content did not, and I could not isolate the variable. Recorded as
  an unexplained observation.

## Not reproduced here

On a larger private graph (~44k nodes) the same path returned rows whose `name`
did not match their own `qualified_name` / `file_path` — e.g. `name: "$defs"`
carrying `qualified_name: ...ValidationChangeType.removed`. That does **not**
occur in this repro, where every `name` matches. Recorded in case it shares a
root cause; it needs its own reproduction.

## Environment

- `codebase-memory-mcp` 0.9.0
- Verified on macOS 15 (Darwin 25.5.0) arm64 **and** Linux 7.0.0 x86_64 — identical results
- Index mode: `full`

## One-command check

```bash
./verify.sh                              # codebase-memory-mcp from PATH
CBM=/path/to/codebase-memory-mcp ./verify.sh
```

Asserts the orderings above, not the decimals, and runs against a throwaway
`CBM_CACHE_DIR` so your own indexes are untouched. Exit code 0 means every
finding reproduced on your machine.
