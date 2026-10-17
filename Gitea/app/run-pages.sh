#!/bin/bash
# deadnews/gitea-pages static site server, supervised by PM2.
#
# Needs a Gitea access token with repository-contents read; without it there is
# nothing to authenticate with, so the wrapper never starts this process.
set -u

export GITEA_PAGES_SERVER="${GITEA_PAGES_SERVER:-http://127.0.0.1:3000}"
export GITEA_PAGES_TOKEN="${GITEA_PAGES_TOKEN:?GITEA_PAGES_TOKEN is required}"
export GITEA_PAGES_BRANCH="${GITEA_PAGES_BRANCH:-gh-pages}"
export GITEA_PAGES_ADDR="${GITEA_PAGES_ADDR:-127.0.0.1:8000}"

# Gitea must be answering before pages can resolve anything through its API.
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null -m 2 "$GITEA_PAGES_SERVER/" 2>/dev/null && break
  sleep 2
done

exec /opt/gitea-pages/gitea-pages
