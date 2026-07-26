# `semantic_query`: out-of-vocabulary keywords silently become random hash vectors

Reproduction and source-level root cause for
[DeusData/codebase-memory-mcp#915](https://github.com/DeusData/codebase-memory-mcp/issues/915),
on **v0.9.0**. Line references are against the `v0.9.0` tag.

Synthetic throwaway code: a parcel delivery service with three deliberately
unrelated domains — pricing, telemetry, routing — so every query has one
obviously correct answer. 84 indexed nodes.

`.cbmignore` excludes `README.md` and `verify.sh`; both name the query terms and
would otherwise contaminate the corpus under test.

Verified identical on **macOS 15 arm64** and **Linux 7.0 x86_64**, both v0.9.0,
from clean clones with a virgin `CBM_CACHE_DIR`. `./verify.sh` returns 0 on both.

---

## Root cause: index-time and query-time vectors come from different spaces

**Index time** — `cbm_sem_random_index()` (`src/semantic/semantic.c:437`) looks
each token up in the vendored 31 MB `nomic-embed-code` table
(`vendored/nomic/code_vectors.bin`) and only falls back to sparse random
indexing on a miss. Node vectors therefore carry real pretrained semantics.

**Query time** — `vs_build_keyword_vectors()` (`src/store/store.c:6245`) does
*not* call that function. It tries `vs_load_enriched_vector()`
(`src/store/store.c:6176`), which reads only the per-project `token_vectors`
table:

```c
const char *tv_sql = "SELECT vector, idf FROM token_vectors"
                     " WHERE project = ?1 AND token = ?2 LIMIT 1";
```

and on a miss falls through to `vs_fill_sparse_random()`
(`src/store/store.c:6202`):

```c
static void vs_fill_sparse_random(const char *token, float *out) {
    uint64_t seed = XXH3_64bits(token, strlen(token));
    ...
}
```

**`vs_fill_sparse_random` never consults the nomic table.** So any keyword
outside the project's harvested vocabulary is turned into a content-free hash
and compared against node vectors that were built from pretrained embeddings.
The result is not a weak match — it is noise, returned silently, with no error
and no signal to the caller.

`token_vectors` is populated only from the indexed corpus
(`phase3c_export_token_vectors`, `src/pipeline/pass_semantic_edges.c:1101`). In
this 84-node repo it holds 108 tokens, all harvested from identifiers.

### Three consequences

**a) Multi-word keywords always miss.** The lookup is on the whole string, and
the table holds single tokens, so a phrase can never match:

```bash
codebase-memory-mcp cli search_graph --project repro --semantic-query '["discount tariff currency"]' --limit 4
#   0.093  print   <python-builtins>
#   0.079  pop     <python-builtins>     <- pure hash noise
codebase-memory-mcp cli search_graph --project repro --semantic-query '["discount","tariff","currency"]' --limit 4
#   0.039  haversine_distance_km  src/routing.py
#   0.009  summarize_sensor_alarms src/telemetry.py   <- real code
```

The docs do say keywords, e.g. `["send","pubsub","publish"]`. But a phrase is
accepted and silently answered with noise rather than rejected.

**b) Ordinary English words miss too, if absent from the identifiers.**
`temperature` is not in this project's vocabulary — the field is
`cabin_temperature_c`, tokenized differently — so it degrades to a hash vector:

```bash
codebase-memory-mcp cli search_graph --project repro --semantic-query '["temperature"]' --limit 3
#  -0.00297  tyre_pressure_low
#  -0.01184  split_into_legs
#  -0.01191  refrigeration_breached     <- the actual temperature function, ranked 3rd, negative
```

`battery` *is* in the vocabulary, yet still ranks `shortest_route` above
`battery_is_critical`. So vocabulary presence is necessary, not sufficient.

**c) Negative cosines are returned as top hits.** `vs_min_cosine_score()`
(`src/store/store.c:6267`) takes the minimum across keywords with no floor:

```c
if (cos_k < min_score) { min_score = cos_k; }
```

Nothing rejects a negative result. Taking the *min* also systematically
penalises specialists: `battery_is_critical` is rank 3 on `battery` (+0.033) but
rank 10 on `temperature` (-0.024), so its min sinks it below a generalist that
is mediocre on all three.

---

## Finding 2 — the semantic corpus is 39% language builtins

`cbm_store_vector_search` restricts candidates (`src/store/store.c:6345`):

```sql
AND n.label IN ('Function','Method','Class')
```

In this repo that is **18 rows total**, of which **7 are Python builtins**:

| source | vectors |
| --- | --- |
| `<python-builtins>` (`len` `print` `upper` `lower` `append` `pop` `get`) | **7** |
| `src/telemetry.py` | 4 |
| `src/pricing.py` | 4 |
| `src/routing.py` | 3 |

Interpreter stubs are 39% of the entire vector space and compete directly with
project code. Combined with a hash-vector query they win outright.

```bash
sqlite3 "$CBM_CACHE_DIR/repro.db" \
  "SELECT n.file_path, count(*) FROM node_vectors v
     JOIN nodes n ON n.id=v.node_id GROUP BY 1 ORDER BY 2 DESC;"
```

---

## Finding 3 — scores depend on the project name

The project name is tokenised into the vocabulary along with everything else —
`repro` is present as a token in `token_vectors` — so it shifts IDF for the
whole corpus. Same clone, same commit, byte-identical source, only `--name`
differs:

| rank | `--name repro` | `--name othername` |
| --- | --- | --- |
| 1 | `haversine_distance_km` 0.05703263 | `haversine_distance_km` 0.05976143 |
| 2 | `compute_parcel_price` 0.03571049 | `compute_parcel_price` 0.04475240 |

```bash
sqlite3 "$CBM_CACHE_DIR/repro.db" "SELECT token FROM token_vectors WHERE token='repro';"
# repro
```

IDF is computed over the same 18 documents (stored ×1000: `2197` = ln(18/2),
`2890` = ln(18/1), `1504` = ln(18/4)), so a corpus this small is highly
sensitive to any token added — including the project label.

---

## Finding 4 — re-index applies `.cbmignore` inclusions but not exclusions

Unrelated to `semantic_query`; found while building this repro. Keep `README.md`
and `verify.sh` listed or you change two variables at once.

```bash
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'docs/decisions%'
# -> total: 6

printf 'README.md\nverify.sh\ndocs/decisions.md\n' > .cbmignore
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full   # -> nodes: 84 (unchanged)
codebase-memory-mcp cli search_graph --project repro --name-pattern '.*' --file-pattern 'docs/decisions%'
# -> total: 6    (still indexed; the new rule had no effect)

codebase-memory-mcp cli delete_project --project repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full   # -> nodes: 78
# -> total: 0
```

The update is additive-only: removing `verify.sh` from the ignore list and
re-indexing takes the graph 84 -> 101 immediately, while a newly *added*
exclusion is ignored in the same run. `delete_project` is currently required
for any exclusion to take effect.

---

## Finding 5 — `results` ignores `semantic_query` (probably by design)

This is what #915 reports. With `semantic_query` as the only argument, `results`
is byte-identical for every query, alphabetical by `name`, `total` equal to the
full node count — verified by hashing rows from unrelated queries.

```json
{ "total": 84,
  "results": [
    { "name": "\"Deferred Until\" Conditions", "label": "Section",  "file_path": "docs/decisions.md" },
    { "name": "$defs", "label": "Variable", "file_path": "schemas/parcel.schema.json" },
    { "name": "$id",   "label": "Variable", "file_path": "schemas/parcel.schema.json" }
  ] }
```

**#915's proposed fix does not apply here.** The vector path already uses an
inner join (`src/store/store.c:6341`):

```sql
FROM node_vectors v INNER JOIN nodes n ON n.id = v.node_id
```

Semantic output goes to `semantic_results`; `results` is the structural-filter
field, and with no `query`/`name_pattern`/`label` supplied there is nothing to
filter it by. That is defensible, but `total: 84` beside a populated `results`
array reads as "84 matches", which is what led to the `LEFT JOIN` diagnosis.

---

## Control — the index is sound

```bash
codebase-memory-mcp cli search_graph --project repro --query "discount tariff currency" --limit 5
# total: 3 -> compute_bulk_discount, apply_currency_surcharge, Tariff   (all src/pricing.py)
```

BM25 and `name_pattern` are exactly right. The defect is confined to
`semantic_query`.

---

## Suggested fixes

1. Have `vs_fill_sparse_random` fall back to the pretrained nomic table, as
   `cbm_sem_random_index` already does — or share one code path. This is the
   root cause; the rest are amplifiers.
2. Tokenise multi-word keywords instead of looking them up verbatim, or reject
   them with an explicit error.
3. Exclude `<python-builtins>` and equivalent stub nodes from `node_vectors`.
4. Add a score floor in `vs_min_cosine_score`, and reconsider min-across-keywords,
   which penalises specialists.
5. Exclude the project name from the tokenised corpus.
6. Signal out-of-vocabulary keywords in the response rather than returning noise.

## One-command check

```bash
./verify.sh
CBM=/path/to/codebase-memory-mcp ./verify.sh
```

Asserts the behaviours above, not exact decimals, against a throwaway
`CBM_CACHE_DIR`. Exit 0 means everything reproduced.

## Environment

- `codebase-memory-mcp` 0.9.0, index mode `full`
- Verified on macOS 15 (Darwin 25.5.0) arm64 **and** Linux 7.0.0 x86_64
