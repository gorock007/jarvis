#!/usr/bin/env bash
# Offline only. Every CLI call uses the asserted fake in a throwaway repository.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-lessons-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
cp "$here/fake-claude" "$scratch/bin/claude"
chmod +x "$scratch/bin/claude"
export PATH="$scratch/bin:$PATH"
test "$(command -v claude)" = "$scratch/bin/claude"
export LESSONS_TEST_SCRATCH="$scratch"
"${LESSONS_TEST_PYTHON:-python3}" -I "$here/fixtures/test_core.py" "$here/../../plugins/jarvis/skills/setup/templates/handoffs/bin/jarvis-lessons.py"
