#!/usr/bin/env bash
# Asserts the qualitative claims in README.md. Exact scores are platform- and
# version-dependent and are deliberately NOT asserted; the orderings are.
#
#   ./verify.sh            uses `codebase-memory-mcp` from PATH
#   CBM=/path/to/bin ./verify.sh
#
# Runs against a throwaway CBM_CACHE_DIR so your real index is untouched.

set -uo pipefail

CBM="${CBM:-codebase-memory-mcp}"
REPO="$(cd "$(dirname "$0")" && pwd)"
CACHE="$(mktemp -d)"
export CBM_CACHE_DIR="$CACHE"
trap 'rm -rf "$CACHE"' EXIT

command -v "$CBM" >/dev/null || { echo "not found: $CBM"; exit 127; }
command -v python3 >/dev/null || { echo "python3 required"; exit 127; }

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

q() { "$CBM" cli search_graph "$@" 2>/dev/null | grep -v '^level='; }
idx() { "$CBM" cli index_repository --repo-path "$REPO" --name "$1" --mode full >/dev/null 2>&1; }

echo "codebase-memory-mcp: $("$CBM" --version 2>/dev/null | head -1)"
echo "repo: $REPO"
echo

idx repro

# --- Finding 1: builtins outrank project code -------------------------------
echo "Finding 1 — builtins outrank project code"
out=$(q --project repro --semantic-query '["discount tariff currency"]' --limit 5)
verdict=$(printf '%s' "$out" | python3 -c '
import sys, json
r = json.load(sys.stdin).get("semantic_results", [])
builtins = [x for x in r if "builtins" in x["file_path"]]
pricing  = [x for x in r if "pricing" in x["file_path"]]
print("BUG" if builtins and not pricing else "OK")
print(", ".join(f'"'"'{x["name"]}({x["file_path"]})'"'"' for x in r[:3]))
')
[ "$(printf '%s' "$verdict" | head -1)" = "BUG" ] \
  && ok "no pricing code returned; builtins only" \
  || bad "expected builtins-only, got: $(printf '%s' "$verdict" | tail -1)"
printf '        top3: %s\n' "$(printf '%s' "$verdict" | tail -1)"

# --- Finding 2: negative similarities ---------------------------------------
echo "Finding 2 — negative cosine similarities returned"
neg=$(q --project repro --semantic-query '["battery temperature sensor"]' --limit 5 \
  | python3 -c 'import sys,json; print(sum(1 for x in json.load(sys.stdin).get("semantic_results",[]) if x["score"]<0))')
[ "${neg:-0}" -gt 0 ] && ok "$neg negative-score hits ranked" || bad "no negative scores seen"

# --- Finding 3: project name changes ranking --------------------------------
echo "Finding 3 — ranking depends on project name"
idx othername
a=$(q --project repro     --semantic-query '["battery temperature sensor"]' --limit 1 \
      | python3 -c 'import sys,json; r=json.load(sys.stdin).get("semantic_results",[]); print(r[0]["name"] if r else "")')
b=$(q --project othername --semantic-query '["battery temperature sensor"]' --limit 1 \
      | python3 -c 'import sys,json; r=json.load(sys.stdin).get("semantic_results",[]); print(r[0]["name"] if r else "")')
[ -n "$a" ] && [ "$a" != "$b" ] \
  && ok "rank-1 differs by project name: '$a' vs '$b'" \
  || bad "rank-1 identical ('$a'); not reproduced here"

# --- Finding 4: .cbmignore not re-evaluated on re-index ---------------------
echo "Finding 4 — .cbmignore ignored on re-index of existing project"
before=$(q --project repro --name-pattern '.*' --file-pattern 'docs/decisions%' \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
cp "$REPO/.cbmignore" "$CACHE/cbmignore.bak"
printf 'README.md\ndocs/decisions.md\n' > "$REPO/.cbmignore"
idx repro
during=$(q --project repro --name-pattern '.*' --file-pattern 'docs/decisions%' \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
"$CBM" cli delete_project --project repro >/dev/null 2>&1
idx repro
after=$(q --project repro --name-pattern '.*' --file-pattern 'docs/decisions%' \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["total"])')
cp "$CACHE/cbmignore.bak" "$REPO/.cbmignore"
[ "$before" -gt 0 ] && [ "$during" = "$before" ] && [ "$after" = "0" ] \
  && ok "re-index kept $during nodes; delete_project+index dropped to 0" \
  || bad "expected $before -> $before -> 0, got $before -> $during -> $after"

"$CBM" cli delete_project --project repro >/dev/null 2>&1; idx repro

# --- Finding 5: results ignores semantic_query -------------------------------
echo "Finding 5 — 'results' identical across unrelated queries"
h1=$(q --project repro --semantic-query '["discount tariff currency"]'   --limit 5 | python3 -c 'import sys,json,hashlib; print(hashlib.sha1(str([r["qualified_name"] for r in json.load(sys.stdin)["results"]]).encode()).hexdigest())')
h2=$(q --project repro --semantic-query '["battery temperature sensor"]' --limit 5 | python3 -c 'import sys,json,hashlib; print(hashlib.sha1(str([r["qualified_name"] for r in json.load(sys.stdin)["results"]]).encode()).hexdigest())')
[ -n "$h1" ] && [ "$h1" = "$h2" ] \
  && ok "identical rows for unrelated queries (sha1 ${h1:0:12})" \
  || bad "rows differed ($h1 vs $h2)"

# --- Control: BM25 is correct ------------------------------------------------
echo "Control — BM25 on the same phrase is correct"
ctl=$(q --project repro --query "discount tariff currency" --limit 5 \
  | python3 -c 'import sys,json; r=json.load(sys.stdin)["results"]; print("OK" if r and all("pricing" in x["file_path"] for x in r) else "BAD")')
[ "$ctl" = "OK" ] && ok "returns only src/pricing.py symbols" || bad "BM25 also wrong — index may be broken"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
