#!/usr/bin/env bash
# End-to-end local demo: anvil -> deploy -> worker + watcher in background
# -> buyer hires worker -> delivery verified -> payment released.
# Requires: forge/anvil on PATH, python venv with web3 (.venv).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
PY=".venv/bin/python -u"

echo "=== HSK Horizon A2A Settlement — local end-to-end demo ==="
anvil --port 8545 --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 2

forge build --silent
$PY demo/deploy.py

$PY agents/worker_agent.py &
WORKER_PID=$!
$PY agents/settlement_watcher.py &
WATCHER_PID=$!
sleep 2

$PY agents/buyer_agent.py

sleep 3
kill $WORKER_PID $WATCHER_PID 2>/dev/null || true
echo "=== demo complete — settlement audit log: demo/settlement_log.jsonl ==="
cat demo/settlement_log.jsonl
