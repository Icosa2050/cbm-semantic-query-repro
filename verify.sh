#!/usr/bin/env bash
# Asserts the behaviours described in README.md. Uses the JSON argument form
# throughout, because the --semantic-query flag does not parse its array (Bug A).
# Orderings and categories are asserted; exact decimals are not.
#
#   ./verify.sh
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

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  SKIP  %s\n' "$1"; }

# JSON form: sem '<project>' '"a","b"'
sem() { "$CBM" cli search_graph "{\"project\":\"$1\",\"semantic_query\":[$2],\"limit\":${3:-5}}" 2>/dev/null | grep -v '^level='; }
q()   { "$CBM" cli search_graph "$@" 2>/dev/null | grep -v '^level='; }
idx() { "$CBM" cli index_repository --repo-path "$REPO" --name "$1" --mode full >/dev/null 2>&1; }
top() { python3 -c 'import sys,json
r=json.load(sys.stdin).get("semantic_results",[])
print("\n".join(x["name"]+"\t"+x["file_path"] for x in r))'; }

echo "codebase-memory-mcp: $("$CBM" --version 2>/dev/null | head -1)"
echo "repo: $REPO"
echo

idx repro

# --- Guard -------------------------------------------------------------------
echo "Guard — harness excluded from the corpus"
a=$(q --project repro --name-pattern '.*' --file-pattern 'README%' | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
b=$(q --project repro --name-pattern '.*' --file-pattern 'verify%' | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
[ "${a:-1}" = "0" ] && [ "${b:-1}" = "0" ] \
  && ok "README.md and verify.sh are not indexed" \
  || bad "harness leaked into corpus (README=$a verify=$b)"

# --- Bug A: CLI flag does not parse the array --------------------------------
echo "Bug A — --semantic-query flag does not parse its array"
flag=$(q --project repro --semantic-query '["battery"]' --limit 3 | top | head -1 | cut -f1)
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

echo "Bug B — one out-of-vocabulary keyword collapses the query"
# limit>=3: see Bug E, the candidate pool is limit*5 and changes the winner.
good=$(sem repro '"battery"' 3 | top | head -1 | cut -f2)
poisoned=$(sem repro '"battery","temperature","sensor"' 3 | top | head -1 | cut -f2)
[ "$good" = "src/telemetry.py" ] && [ "$poisoned" != "src/telemetry.py" ] \
  && ok "['battery'] -> $good; adding out-of-vocab 'temperature' -> $poisoned" \
  || bad "expected telemetry then a non-telemetry answer (got '$good' then '$poisoned')"

echo "Bug E — 'limit' changes the winner, not just the row count"
t1=$(sem repro '"battery","temperature","sensor"' 1 | top | head -1 | cut -f1)
t3=$(sem repro '"battery","temperature","sensor"' 3 | top | head -1 | cut -f1)
[ -n "$t1" ] && [ "$t1" != "$t3" ] \
  && ok "top-1 is '$t1' at limit=1 but '$t3' at limit=3" \
  || bad "expected the top result to change with limit (got '$t1' vs '$t3')"

echo "Bug B — 'temperature' is absent from token_vectors but present in nomic"
if command -v sqlite3 >/dev/null && [ -f "$CACHE/repro.db" ]; then
  n=$(sqlite3 "$CACHE/repro.db" "SELECT count(*) FROM token_vectors WHERE token='temperature';")
  [ "${n:-1}" = "0" ] \
    && ok "'temperature' not in token_vectors -> takes the hash fallback" \
    || bad "'temperature' unexpectedly present ($n rows)"
else
  skip "sqlite3 unavailable"
fi

# --- Bug C: project name changes scores --------------------------------------
echo "Bug C — scores depend on the project name"
idx othername
sc() { sem "$1" '"battery"' 1 | python3 -c 'import sys,json
r=json.load(sys.stdin).get("semantic_results",[])
print("%.8f" % r[0]["score"] if r else "")'; }
s1=$(sc repro); s2=$(sc othername)
[ -n "$s1" ] && [ "$s1" != "$s2" ] \
  && ok "rank-1 score differs by project name: $s1 vs $s2" \
  || bad "scores identical ($s1 vs $s2)"

# --- Bug D: .cbmignore additive-only -----------------------------------------
echo "Bug D — re-index applies inclusions but not exclusions"
before=$(q --project repro --name-pattern '.*' --file-pattern 'docs/decisions%' | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
cp "$REPO/.cbmignore" "$CACHE/cbmignore.bak"
printf 'README.md\nverify.sh\ndocs/decisions.md\n' > "$REPO/.cbmignore"
idx repro
during=$(q --project repro --name-pattern '.*' --file-pattern 'docs/decisions%' | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
"$CBM" cli delete_project --project repro >/dev/null 2>&1
idx repro
after=$(q --project repro --name-pattern '.*' --file-pattern 'docs/decisions%' | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
cp "$CACHE/cbmignore.bak" "$REPO/.cbmignore"
[ "${before:-0}" -gt 0 ] && [ "$during" = "$before" ] && [ "$after" = "0" ] \
  && ok "re-index kept $during nodes; delete_project+index dropped to 0" \
  || bad "expected $before -> $before -> 0, got $before -> $during -> $after"

"$CBM" cli delete_project --project repro >/dev/null 2>&1; idx repro

# --- Observation: results ignores semantic_query ------------------------------
echo "Observation — 'results' identical across unrelated queries"
h() { sem repro "$1" 5 | python3 -c 'import sys,json,hashlib; print(hashlib.sha1(str([r["qualified_name"] for r in json.load(sys.stdin)["results"]]).encode()).hexdigest())'; }
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
ctl=$(q --project repro --query "discount tariff currency" --limit 5 \
  | python3 -c 'import sys,json; r=json.load(sys.stdin)["results"]; print("OK" if r and all("pricing" in x["file_path"] for x in r) else "BAD")')
[ "$ctl" = "OK" ] && ok "returns only src/pricing.py symbols" || bad "BM25 also wrong"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
