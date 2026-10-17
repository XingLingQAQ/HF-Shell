#!/bin/bash
# Renovate dependency-update loop, supervised by PM2.
#
# Renovate is a one-shot batch tool, so it is wrapped in a sleep loop to give it
# the "runs forever" shape PM2 expects. The Gitea endpoint and token come from
# the config file the wrapper writes.
set -u

export RENOVATE_CONFIG_FILE="${RENOVATE_CONFIG_FILE:-/data/renovate/config.js}"
export RENOVATE_TOKEN="${RENOVATE_TOKEN:?RENOVATE_TOKEN is required}"
export GITHUB_COM_TOKEN="${GITHUB_COM_TOKEN:-}"
export PATH="/opt/renovate/node_modules/.bin:$PATH"

INTERVAL="${RENOVATE_INTERVAL:-3600}"

# Gitea must be answering before the first scan can log in.
for _ in $(seq 1 90); do
  curl -fsS -o /dev/null -m 2 http://127.0.0.1:3000/ 2>/dev/null && break
  sleep 2
done

while true; do
  echo "[renovate] run $(date -Is 2>/dev/null || date)"
  /opt/renovate/node_modules/.bin/renovate || echo "[renovate] exit $?"
  echo "[renovate] sleep ${INTERVAL}s"
  sleep "$INTERVAL"
done
