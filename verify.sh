#!/usr/bin/env bash
# Asserts the behaviours described in README.md. Uses the JSON argument form
# throughout, because the --semantic-query flag does not parse its array (Bug A).
# Orderings and categories are asserted; exact decimals are not.
#
#   ./verify.sh                    assert the bugs are present (stock build)
#   EXPECT_FIXED=1 ./verify.sh      assert the OOV fallback is fixed (patched build)
#   CBM=/path/to/codebase-memory-mcp ./verify.sh
#
# Uses a throwaway CBM_CACHE_DIR, so your real indexes are untouched.

set -uo pipefail

CBM="${CBM:-codebase-memory-mcp}"
REPO="$(cd "$(dirname "$0")" && pwd)"
CACHE="$(mktemp -d)"
export CBM_CACHE_DIR="$CACHE"
trap 'rm -rf "$CACHE"' EXIT

command -v "$CBM" >/dev/null || { echo "not found: $CBM"; exit 127; }
command -v python3 >/dev/null || { echo "python3 required"; exit 127; }

EXPECT_FIXED="${EXPECT_FIXED:-0}"
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  SKIP  %s\n' "$1"; }

# JSON form: sem '<project>' '"a","b"'
N="$REPO/_normalize.py"
# `format:json` is ignored by v0.9.0 (already JSON) and honoured by newer builds.
sem() { "$CBM" cli search_graph "{\"project\":\"$1\",\"semantic_query\":[$2],\"limit\":${3:-5},\"format\":\"json\"}" 2>/dev/null; }
q()   { "$CBM" cli search_graph "$@" 2>/dev/null; }
qj()  { "$CBM" cli search_graph "{\"project\":\"$1\",\"name_pattern\":\".*\",\"file_pattern\":\"$2\",\"limit\":1,\"format\":\"json\"}" 2>/dev/null; }
idx() { "$CBM" cli index_repository --repo-path "$REPO" --name "$1" --mode full >/dev/null 2>&1; }
top() { python3 "$N" semantic | cut -f1,2; }

echo "codebase-memory-mcp: $("$CBM" --version 2>/dev/null | head -1)"
echo "repo: $REPO"
echo

idx repro

# --- Guard -------------------------------------------------------------------
echo "Guard — harness excluded from the corpus"
a=$(qj repro 'README%' | python3 "$N" total)
b=$(qj repro 'verify%' | python3 "$N" total)
[ "${a:-1}" = "0" ] && [ "${b:-1}" = "0" ] \
  && ok "README.md and verify.sh are not indexed" \
  || bad "harness leaked into corpus (README=$a verify=$b)"

# --- Bug A: CLI flag does not parse the array --------------------------------
echo "Bug A — --semantic-query flag does not parse its array"
flag=$("$CBM" cli search_graph --project repro --semantic-query '["battery"]' --limit 3 --format json 2>/dev/null | python3 "$N" semantic | head -1 | cut -f1)
json=$(sem repro '"battery"' 3 | top | head -1 | cut -f1)
[ -n "$json" ] && [ "$flag" != "$json" ] \
  && ok "flag form -> '$flag'; JSON form -> '$json' (differ, so the flag is not parsed)" \
  || bad "expected the two argument forms to disagree (flag='$flag' json='$json')"

# --- Bug B: correct parsing works; one OOV keyword collapses the query -------
echo "Bug B — correctly parsed in-vocabulary query is accurate"
pr=$(sem repro '"discount","tariff","currency"' 4 | top | grep -c 'pricing.py')
[ "${pr:-0}" -ge 3 ] \
  && ok "['discount','tariff','currency'] -> $pr/4 src/pricing.py symbols" \
  || bad "expected mostly pricing.py, got $pr/4"

# 'thermostat' is absent from this fixture's identifiers on every release tested
# (v0.9.0 and current main), so it reliably exercises the fallback. It IS in the
# nomic vocabulary, and it is semantically a telemetry word.
echo "Bug B — out-of-vocabulary keyword ('thermostat')"
oov=$(sem repro '"thermostat"' 3 | top | head -1 | cut -f2)
if [ "$EXPECT_FIXED" = "1" ]; then
  [ "$oov" = "src/telemetry.py" ] \
    && ok "resolves to $oov (nomic fallback active)" \
    || bad "expected src/telemetry.py, got '$oov' — fix not active"
else
  [ -n "$oov" ] && [ "$oov" != "src/telemetry.py" ] \
    && ok "degrades to '$oov' instead of telemetry (hash fallback)" \
    || bad "expected a non-telemetry answer, got '$oov' — already fixed?"
fi

echo "Bug B — 'thermostat' is absent from token_vectors"
if command -v sqlite3 >/dev/null && [ -f "$CACHE/repro.db" ]; then
  n=$(sqlite3 "$CACHE/repro.db" "SELECT count(*) FROM token_vectors WHERE token='thermostat';")
  [ "${n:-1}" = "0" ] \
    && ok "not in token_vectors -> the fallback path is what is being measured" \
    || bad "unexpectedly present ($n rows); pick another out-of-vocabulary word"
else
  skip "sqlite3 unavailable"
fi

echo "Bug E — 'limit' changes the winner, not just the row count"
t1=$(sem repro '"battery","thermostat","sensor"' 1 | top | head -1 | cut -f1)
t3=$(sem repro '"battery","thermostat","sensor"' 3 | top | head -1 | cut -f1)
if [ "$EXPECT_FIXED" = "1" ]; then
  [ -n "$t1" ] && [ "$t1" = "$t3" ] \
    && ok "stable across limits ('$t1') once keywords resolve" \
    || bad "top-1 still varies with limit ('$t1' vs '$t3')"
else
  [ -n "$t1" ] && [ "$t1" != "$t3" ] \
    && ok "top-1 is '$t1' at limit=1 but '$t3' at limit=3" \
    || bad "expected the top result to change with limit (got '$t1' vs '$t3')"
fi

# --- Bug C: project name changes scores --------------------------------------
echo "Bug C — scores depend on the project name"
idx othername
sc() { sem "$1" '"battery"' 1 | python3 "$N" semantic | head -1 | cut -f3; }
s1=$(sc repro); s2=$(sc othername)
[ -n "$s1" ] && [ "$s1" != "$s2" ] \
  && ok "rank-1 score differs by project name: $s1 vs $s2" \
  || bad "scores identical ($s1 vs $s2)"

# --- Bug D: .cbmignore additive-only -----------------------------------------
echo "Bug D — re-index applies inclusions but not exclusions"
before=$(qj repro 'docs/decisions%' | python3 "$N" total)
cp "$REPO/.cbmignore" "$CACHE/cbmignore.bak"
printf 'README.md\nverify.sh\ndocs/decisions.md\n' > "$REPO/.cbmignore"
idx repro
during=$(qj repro 'docs/decisions%' | python3 "$N" total)
"$CBM" cli delete_project --project repro >/dev/null 2>&1
idx repro
after=$(qj repro 'docs/decisions%' | python3 "$N" total)
cp "$CACHE/cbmignore.bak" "$REPO/.cbmignore"
[ "${before:-0}" -gt 0 ] && [ "$during" = "$before" ] && [ "$after" = "0" ] \
  && ok "re-index kept $during nodes; delete_project+index dropped to 0" \
  || bad "expected $before -> $before -> 0, got $before -> $during -> $after"

"$CBM" cli delete_project --project repro >/dev/null 2>&1; idx repro

# --- Observation: results ignores semantic_query ------------------------------
echo "Observation — 'results' identical across unrelated queries"
h() { sem repro "$1" 5 | python3 "$N" results | shasum -a 1 | cut -d" " -f1; }
h1=$(h '"discount","tariff"'); h2=$(h '"battery","sensor"')
[ -n "$h1" ] && [ "$h1" = "$h2" ] \
  && ok "identical rows for unrelated queries (sha1 ${h1:0:12})" \
  || bad "rows differed ($h1 vs $h2)"

# --- Retraction check: builtins do NOT dominate correct queries ---------------
echo "Retraction — builtins do not dominate a correctly parsed query"
bi=$(sem repro '"discount","tariff","currency"' 5 | top | grep -c 'builtins')
[ "${bi:-0}" -eq 0 ] \
  && ok "no <python-builtins> in the top 5 (earlier claim retracted)" \
  || bad "unexpected builtins in a correctly parsed query ($bi)"

# --- Control -----------------------------------------------------------------
echo "Control — BM25 is correct"
ctl=$("$CBM" cli search_graph '{"project":"repro","query":"discount tariff currency","limit":5,"format":"json"}' 2>/dev/null \
  | python3 "$N" results | awk 'BEGIN{n=0;ok=1} {n++; if ($0 !~ /pricing/) ok=0} END{print (n>0 && ok) ? "OK" : "BAD"}')
[ "$ctl" = "OK" ] && ok "returns only src/pricing.py symbols" || bad "BM25 also wrong"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
