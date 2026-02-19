#!/usr/bin/env bash
set -euo pipefail

N_HOST="${1:-norns-shield.local}"
N_USER="${N_USER:-we}"
APP_NAME="notetalk"
APP_DIR="/home/${N_USER}/dust/code/${APP_NAME}"

echo "[1/2] Deploy ${APP_NAME} -> ${N_USER}@${N_HOST}:${APP_DIR}"
rsync -avz \
  --exclude '.git' \
  --exclude '.cursor' \
  --exclude 'node_modules' \
  "./" "${N_USER}@${N_HOST}:${APP_DIR}/"

echo "[2/2] Try auto-load on Norns"
LOAD_CMD="norns.script.load('code/${APP_NAME}/${APP_NAME}.lua')"
AUTO_LOADED=0

# Preferred: run from local machine against Norns host.
if command -v maiden-remote-repl >/dev/null 2>&1; then
  maiden-remote-repl --host "${N_HOST}" send "${LOAD_CMD}" && AUTO_LOADED=1 || true
elif command -v maiden >/dev/null 2>&1; then
  printf '%s\n' "${LOAD_CMD}" | maiden repl --host "${N_HOST}" && AUTO_LOADED=1 || true
fi

# Fallback: if maiden exists on Norns, try there.
if [[ "${AUTO_LOADED}" -eq 0 ]]; then
  if ssh "${N_USER}@${N_HOST}" "command -v maiden >/dev/null 2>&1"; then
    ssh "${N_USER}@${N_HOST}" "echo \"${LOAD_CMD}\" | maiden repl" && AUTO_LOADED=1 || true
  fi
fi

if [[ "${AUTO_LOADED}" -eq 1 ]]; then
  echo "Done: ${APP_NAME} deployed and load command sent."
else
  echo "Done: ${APP_NAME} deployed."
  echo "Auto-load skipped (no CLI REPL tool found)."
  echo "Run from Norns UI: SELECT SCRIPT -> ${APP_NAME} -> RUN"
fi
