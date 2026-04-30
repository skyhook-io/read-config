#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_FILE="${REPO_ROOT}/action.yml"

if [[ ! -f "${ACTION_FILE}" ]]; then
  echo "FAIL: action.yml not found at repository root (${ACTION_FILE})"
  exit 1
fi

echo "Checking basic action metadata in ${ACTION_FILE}..."

grep -q "^name:" "${ACTION_FILE}" || { echo "FAIL: missing top-level 'name' field"; exit 1; }
grep -q "^description:" "${ACTION_FILE}" || { echo "FAIL: missing top-level 'description' field"; exit 1; }
grep -q "^runs:" "${ACTION_FILE}" || { echo "FAIL: missing top-level 'runs' section"; exit 1; }
grep -q "using: 'composite'" "${ACTION_FILE}" || { echo "FAIL: expected runs.using to be 'composite'"; exit 1; }

echo "PASS: action.yml metadata looks valid for GitHub Marketplace."

