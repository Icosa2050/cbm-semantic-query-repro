# `semantic_query`: out-of-vocabulary keywords fall back to a content-free hash

Reproduction, source-level cause, and a validated one-line fix for behaviour
discussed in [DeusData/codebase-memory-mcp#915](https://github.com/DeusData/codebase-memory-mcp/issues/915).
Tested on **v0.9.0**; line references are against the `v0.9.0` tag.

Synthetic throwaway code: a parcel delivery service with three deliberately
unrelated domains — pricing, telemetry, routing — so every query has one
obviously correct answer. 84 indexed nodes.

> **Use the JSON argument form.** `cli search_graph --semantic-query '["x"]'`
> does **not** parse the array (see Bug A); it passes the literal text `["x"]`
> as a single keyword. Every example here uses the JSON form.

---

## Bug A — the CLI `--semantic-query` flag never parses its array

```bash
codebase-memory-mcp cli search_graph --project repro --semantic-query '["temperature"]' --limit 3
#   keyword actually looked up: ["temperature"]      <- the literal string

codebase-memory-mcp cli search_graph '{"project":"repro","semantic_query":["temperature"],"limit":3}'
#   keyword actually looked up: temperature          <- correct
```

The flag form yields a keyword that can never be in any vocabulary, so it always
takes the Bug B fallback and returns noise. The JSON form and piped stdin both
parse correctly, as does the MCP tool. CLI-only, but silent.

## Bug B — query-time vectors never consult the pretrained table

At index time, `cbm_sem_random_index()` (`src/semantic/semantic.c:437`) looks a
token up in the vendored `nomic-embed-code` table (40,856 tokens) and only falls
back to sparse random indexing on a miss.

At query time, `vs_build_keyword_vectors()` (`src/store/store.c:6245`) does not
use that function. It tries `vs_load_enriched_vector()` (`src/store/store.c:6176`),
which reads only the per-project `token_vectors` table, then falls through to
`vs_fill_sparse_random()` (`src/store/store.c:6202`) — a plain XXH3 hash with no
nomic lookup.

`token_vectors` holds only tokens harvested from the indexed identifiers (108
here). `temperature` is absent — the field is `cabin_temperature_c` — even
though it *is* in the nomic vocabulary at index 35753. So it degrades to a hash.

**One out-of-vocabulary keyword collapses an entire query.** Because
`vs_min_cosine_score()` (`src/store/store.c:6267`) takes the minimum across
keywords, the hash keyword dominates:

| query | top 3 |
| --- | --- |
| `["battery"]` | `battery_is_critical` +0.946, `summarize_sensor_alarms` +0.934, `refrigeration_breached` +0.904 |
| `["battery","temperature","sensor"]` | `haversine_distance_km` **+0.069**, `compute_parcel_price` +0.051, `compute_bulk_discount` +0.045 |

Adding `temperature` drops the score by an order of magnitude and flips the
answer from telemetry to routing.

### Fix (validated)

```c
static void vs_fill_sparse_random(const char *token, float *out) {
    cbm_sem_vec_t sv;
    cbm_sem_random_index(token, &sv);   /* nomic first, sparse RI on miss */
    for (int d = 0; d < VS_VEC_DIM && d < CBM_SEM_DIM; d++) {
        out[d] = sv.v[d];
    }
}
```

plus `#include "semantic/semantic.h"`. `VS_VEC_DIM == CBM_SEM_DIM == 768`.

| query | stock | patched |
| --- | --- | --- |
| `["temperature"]` | `haversine_distance_km` +0.069 (routing) | `tyre_pressure_low` **+0.396**, `refrigeration_breached` +0.337, `summarize_sensor_alarms` +0.331 (telemetry) |
| `["battery","temperature","sensor"]` | `haversine_distance_km` +0.069 | `tyre_pressure_low` **+0.396**, `refrigeration_breached` +0.337 |
| `["battery"]` | `battery_is_critical` +0.946 | unchanged (no fallback taken) |

`make -f Makefile.cbm test`: **5934 passed, 1 skipped** — byte-identical to the
unpatched baseline on the same machine. The skip is a network-gated incremental
test, unrelated.

## Bug E — `limit` changes the winner, not just the row count

`fetch_limit = limit * 5` (`src/store/store.c:6357`) and the SQL pre-filter
orders by the **first keyword only**, then re-ranks by min across keywords. A
small pool therefore never sees the true best-by-min candidate:

| limit | top-1 for `["battery","temperature","sensor"]` |
| --- | --- |
| 1 | `summarize_sensor_alarms` +0.0267 |
| 2 | `compute_parcel_price` +0.0506 |
| 3+ | `haversine_distance_km` +0.0690 |

Asking for fewer results returns a different and lower-scored winner, so `limit`
is not a pure truncation.

## Bug C — scores depend on the project name

The project name is tokenised into the vocabulary like any other token, so it
shifts IDF corpus-wide. Same commit, byte-identical source, only `--name`
differs:

| project | rank 1 |
| --- | --- |
| `repro` | `battery_is_critical` 0.94567562 |
| `othername` | `battery_is_critical` 0.94138202 |

Small, but an arbitrary label should not move similarity between code symbols.

## Bug D — re-index applies `.cbmignore` inclusions but not exclusions

Unrelated to `semantic_query`. Keep `README.md` and `verify.sh` listed or you
change two variables at once.

```bash
printf 'README.md\nverify.sh\ndocs/decisions.md\n' > .cbmignore
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full  # nodes: 84, unchanged
# docs/decisions.md still indexed (6 nodes)
codebase-memory-mcp cli delete_project --project repro
codebase-memory-mcp cli index_repository --repo-path "$PWD" --name repro --mode full  # nodes: 78 -> 0
```

Additive-only: *removing* a name from `.cbmignore` is picked up immediately
(84 -> 101), *adding* one is not. `delete_project` is currently required.

## Observation — `results` ignores `semantic_query` (probably by design)

Three unrelated queries return byte-identical `results`, alphabetical by `name`,
`total` equal to the full node count. Per `cli search_graph --help`, semantic
output goes to `semantic_results` and `results` is the structural-filter field,
so with no `query`/`name_pattern`/`label` there is nothing to filter it by.

**#915's `LEFT JOIN node_vectors` diagnosis does not fit**: the vector path
already uses an inner join (`src/store/store.c:6341`). But `total: 84` beside a
populated `results` array reads as "84 matches", which is probably how that
reading arose.

## Retracted

An earlier version of this repo claimed language builtins outrank project code.
**That was wrong** — an artifact of Bug A. With correct parsing,
`["discount","tariff","currency"]` returns all four `src/pricing.py` functions
(+0.781, +0.778, +0.732, +0.705) and no builtins. Builtins *are* 7 of 18 rows in
`node_vectors`, but they do not distort correctly-parsed queries.

## Verify

```bash
./verify.sh
CBM=/path/to/codebase-memory-mcp ./verify.sh
```

Uses the JSON form throughout and a throwaway `CBM_CACHE_DIR`. Exit 0 means
everything reproduced.

## Environment

- `codebase-memory-mcp` 0.9.0, index mode `full`
- Verified on macOS 15 (Darwin 25.5.0) arm64 and Linux 7.0.0 x86_64
