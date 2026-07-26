#!/usr/bin/env bash
# Asserts the behaviours described in README.md. Exact scores are not asserted;
# orderings and category membership are.
#
#   ./verify.sh                      codebase-memory-mcp from PATH
#   CBM=/path/to/bin ./verify.sh
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

q()   { "$CBM" cli search_graph "$@" 2>/dev/null | grep -v '^level='; }
idx() { "$CBM" cli index_repository --repo-path "$REPO" --name "$1" --mode full >/dev/null 2>&1; }
# names of semantic_results, one per line
names() { python3 -c 'import sys,json; [print(x["name"]+"\t"+x["file_path"]) for x in json.load(sys.stdin).get("semantic_results",[])]'; }

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
  || bad "harness leaked into corpus (README=$a verify=$b); results below unreliable"

# --- Root cause: OOV keyword -> hash vector ---------------------------------
echo "Root cause — multi-word keyword degrades to a hash vector"
phrase=$(q --project repro --semantic-query '["discount tariff currency"]' --limit 5 | names)
words=$(q  --project repro --semantic-query '["discount","tariff","currency"]' --limit 5 | names)
p_bi=$(printf '%s' "$phrase" | grep -c 'builtins')
p_pr=$(printf '%s' "$phrase" | grep -c 'src/')
w_pr=$(printf '%s' "$words"  | grep -c 'src/')
{ [ "$p_bi" -gt 0 ] && [ "$p_pr" -eq 0 ] && [ "$w_pr" -gt 0 ]; } \
  && ok "phrase -> ${p_bi} builtins / 0 project symbols; single words -> ${w_pr} project symbols" \
  || bad "expected phrase=builtins-only, words=project code (got phrase:${p_bi}b/${p_pr}p words:${w_pr}p)"

echo "Root cause — out-of-vocabulary word ranks negative"
neg=$(q --project repro --semantic-query '["temperature"]' --limit 3 \
  | python3 -c 'import sys,json; r=json.load(sys.stdin).get("semantic_results",[]); print(sum(1 for x in r if x["score"]<0))')
[ "${neg:-0}" -gt 0 ] \
  && ok "'temperature' (absent from token_vectors) yields $neg negative-score hits" \
  || bad "expected negative scores for an out-of-vocabulary keyword"

echo "Root cause — min-across-keywords penalises specialists"
r_bat=$(q --project repro --semantic-query '["battery"]' --limit 30 | names | grep -n 'battery_is_critical' | cut -d: -f1)
r_all=$(q --project repro --semantic-query '["battery","temperature","sensor"]' --limit 30 | names | grep -n 'battery_is_critical' | cut -d: -f1)
if [ -n "${r_bat:-}" ] && { [ -z "${r_all:-}" ] || [ "$r_all" -gt "$r_bat" ]; }; then
  ok "battery_is_critical: rank $r_bat on ['battery'] -> rank ${r_all:-absent} on the 3-keyword query"
else
  bad "expected the specialist to sink when keywords are combined (got $r_bat -> ${r_all:-absent})"
fi

# --- Builtins share of the semantic corpus ----------------------------------
echo "Finding 2 — builtins are a large share of node_vectors"
if command -v sqlite3 >/dev/null && [ -f "$CACHE/repro.db" ]; then
  tot=$(sqlite3 "$CACHE/repro.db" "SELECT count(*) FROM node_vectors;")
  bi=$(sqlite3 "$CACHE/repro.db" "SELECT count(*) FROM node_vectors v JOIN nodes n ON n.id=v.node_id WHERE n.file_path LIKE '%builtins%';")
  [ "${bi:-0}" -gt 0 ] && [ $((bi * 3)) -ge "${tot:-1}" ] \
    && ok "$bi of $tot vectors are language builtins" \
    || bad "expected builtins to be >=1/3 of node_vectors (got $bi/$tot)"
else
  skip "sqlite3 unavailable; cannot inspect node_vectors"
fi

# --- Finding 3: project name changes scores ---------------------------------
echo "Finding 3 — scores depend on the project name"
idx othername
topscore() { python3 -c 'import sys,json
r = json.load(sys.stdin).get("semantic_results", [])
print("%.8f" % r[0]["score"] if r else "")'; }
s1=$(q --project repro     --semantic-query '["battery","temperature","sensor"]' --limit 1 | topscore)
s2=$(q --project othername --semantic-query '["battery","temperature","sensor"]' --limit 1 | topscore)
[ -n "$s1" ] && [ "$s1" != "$s2" ] \
  && ok "rank-1 score differs by project name: $s1 vs $s2" \
  || bad "scores identical ($s1 vs $s2); not reproduced here"

# --- Finding 4: .cbmignore additive-only ------------------------------------
echo "Finding 4 — re-index applies inclusions but not exclusions"
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

# --- Finding 5: results ignores semantic_query -------------------------------
echo "Finding 5 — 'results' identical across unrelated queries"
h() { q --project repro --semantic-query "$1" --limit 5 | python3 -c 'import sys,json,hashlib; print(hashlib.sha1(str([r["qualified_name"] for r in json.load(sys.stdin)["results"]]).encode()).hexdigest())'; }
h1=$(h '["discount","tariff"]'); h2=$(h '["battery","sensor"]')
[ -n "$h1" ] && [ "$h1" = "$h2" ] \
  && ok "identical rows for unrelated queries (sha1 ${h1:0:12})" \
  || bad "rows differed ($h1 vs $h2)"

# --- Control -----------------------------------------------------------------
echo "Control — BM25 on the same phrase is correct"
ctl=$(q --project repro --query "discount tariff currency" --limit 5 \
  | python3 -c 'import sys,json; r=json.load(sys.stdin)["results"]; print("OK" if r and all("pricing" in x["file_path"] for x in r) else "BAD")')
[ "$ctl" = "OK" ] && ok "returns only src/pricing.py symbols" || bad "BM25 also wrong — index may be broken"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
