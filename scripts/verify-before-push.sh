#!/bin/bash
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

python3 scripts/harness/verify.py --repo "$REPO_ROOT" --mode push "$@"
