#!/usr/bin/env bash
# Builds a fresh test database, then runs every tests/test_*.sql file inside its
# own transaction that is ROLLED BACK afterwards, so tests are fully isolated.
# Usage: tests/run_tests.sh            (connection via standard PG* env vars)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${TEST_DB:-stagedb_test}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

"$ROOT/scripts/reset_db.sh" "$DB" >/dev/null || exit 1
"${PSQL[@]}" -f "$ROOT/tests/fixtures.sql" -f "$ROOT/tests/_helpers.sql" >/dev/null || exit 1

total=0; failed=0
for f in "$ROOT"/tests/test_*.sql; do
    name="$(basename "$f" .sql)"
    out="$( { echo 'BEGIN;'; cat "$f"; echo 'ROLLBACK;'; } | "${PSQL[@]}" 2>&1 )"
    status=$?
    passes=$(grep -c 'PASS:' <<<"$out")
    total=$((total + passes))
    if [[ $status -ne 0 ]]; then
        failed=$((failed + 1))
        printf '\033[31m✗ %-32s\033[0m %3d passed, then failed:\n' "$name" "$passes"
        grep -E 'ERROR|FAIL' <<<"$out" | sed 's/^/      /'
    else
        printf '\033[32m✓ %-32s\033[0m %3d assertions\n' "$name" "$passes"
    fi
    [[ -n "${VERBOSE:-}" ]] && grep 'PASS:' <<<"$out" | sed 's/.*PASS: /      · /'
done

echo "-------------------------------------------------"
if [[ $failed -eq 0 ]]; then
    echo "All test files passed ($total assertions)."
else
    echo "$failed test file(s) failed ($total assertions passed before failure)."
    exit 1
fi
