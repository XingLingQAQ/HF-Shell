#!/bin/bash
# Gitea Space entrypoint.
#
# Replaces the original flow where the Space image downloaded Gitea/startup.sh
# from GitHub at boot and that script then re-fetched the Gitea binary, the
# gitea-pages release, cloudflared and an npm tree. All of those are baked into
# this image, so the boot path is now: prepare the work dir on the bucket mount,
# start PM2, serve the control panel on :7860, and let PM2 supervise Gitea on
# :3000, pages on :8000, Renovate and the tunnel.
set -u
umask 000

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8
export NODE_ENV=production

export GITEA_WORK_DIR="${GITEA_WORK_DIR:-/data/gitea}"
export GITEA_CUSTOM="${GITEA_CUSTOM:-$GITEA_WORK_DIR/custom}"
export PANEL_PORT="${PANEL_PORT:-7860}"
export GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
export GITEA_HTTP_ADDR="${GITEA_HTTP_ADDR:-127.0.0.1}"
export PM2_HOME="${PM2_HOME:-/app/.pm2}"
export PATH="/app/node_modules/.bin:/opt/gitea:/opt/gitea-pages:/opt/renovate/node_modules/.bin:/opt/tunnel:/usr/local/bin:$PATH"

echo "[Info] Gitea $(cat /opt/gitea/version 2>/dev/null || echo '?')  pages $(cat /opt/gitea-pages/version 2>/dev/null || echo '?')  cloudflared $(cat /opt/tunnel/version 2>/dev/null || echo '?')"

mkdir -p "$GITEA_WORK_DIR" "$GITEA_CUSTOM/conf" /data/renovate /app /tmp "$PM2_HOME" 2>/dev/null || true
chmod -R 777 /app /tmp 2>/dev/null || true

# ---------------- 1. First-boot restore from the sibling backup ---------------
# Gitea's work dir normally lives directly on the bucket, so this only fires when
# the live tree is empty (a fresh bucket, or a botched boot) while the backup
# still holds a copy. Children are copied one at a time because the bucket mount
# throttles under burst I/O.
if [ -d /data/gitea_backup ] && [ -n "$(ls -A /data/gitea_backup 2>/dev/null)" ]; then
  if [ -z "$(ls -A "$GITEA_WORK_DIR" 2>/dev/null)" ]; then
    echo "[Sync] /data/gitea empty, restoring from /data/gitea_backup ..."
    for item in /data/gitea_backup/*; do
      [ ! -e "$item" ] && continue
      echo "[Sync] Restoring: $(basename "$item")"
      cp -a "$item" "$GITEA_WORK_DIR/" || true
      sleep 0.2
    done
    cp -a /data/gitea_backup/.[!.]* "$GITEA_WORK_DIR/" 2>/dev/null || true
    echo "[Sync] Restore complete."
  else
    echo "[Sync] /data/gitea present, skipping restore."
  fi
else
  echo "[Sync] No backup found."
fi

# Gitea refuses to run as root, and it writes as the `git` account, so the tree
# on the mount has to belong to that account.
if id git >/dev/null 2>&1; then
  chown -R git:git "$GITEA_WORK_DIR" /opt/gitea /opt/gitea-pages 2>/dev/null || true
  chmod 755 /opt/gitea/gitea /opt/gitea-pages/gitea-pages 2>/dev/null || true
else
  echo "[WARN] no 'git' account; Gitea will be forced to run as root"
fi

# ---------------- 2. app.ini: make sure the package registry stays on --------
CONF="$GITEA_CUSTOM/conf/app.ini"
if [ -f "$CONF" ]; then
  if grep -q '^\[packages\]' "$CONF" 2>/dev/null; then
    if grep -A5 '^\[packages\]' "$CONF" | grep -q '^ENABLED'; then
      sed -i '/^\[packages\]/,/^\[/{s/^ENABLED *=.*/ENABLED = true/}' "$CONF" 2>/dev/null || true
    else
      sed -i '/^\[packages\]/a ENABLED = true' "$CONF" 2>/dev/null || true
    fi
  else
    printf '\n[packages]\nENABLED = true\n' >> "$CONF"
  fi
  # Only rewritten when the Space actually sets the variable; the stored config
  # already carries the value this deployment has been running with.
  if [ -n "${GITEA_ROOT_URL:-}" ]; then
    if grep -q '^ROOT_URL' "$CONF"; then
      sed -i "s|^ROOT_URL.*|ROOT_URL = ${GITEA_ROOT_URL}|" "$CONF" || true
    else
      sed -i "/^\[server\]/a ROOT_URL = ${GITEA_ROOT_URL}" "$CONF" 2>/dev/null || true
    fi
    echo "[Info] ROOT_URL -> ${GITEA_ROOT_URL}"
  fi
  sed -i 's/^RUN_USER *=.*/RUN_USER = git/' "$CONF" 2>/dev/null || true
  chown git:git "$CONF" 2>/dev/null || true
else
  echo "[Info] no app.ini yet; Gitea will create one in $GITEA_CUSTOM/conf"
fi

# ---------------- 3. Renovate config ----------------------------------------
# Written only when missing or still carrying our marker, so a hand-edited
# config on the bucket survives a restart.
write_renovate_config() {
  mkdir -p /data/renovate
  local ep="${RENOVATE_ENDPOINT:-}"
  if [ -z "$ep" ]; then
    ep="${GITEA_ROOT_URL:-http://127.0.0.1:${GITEA_HTTP_PORT}}"
    ep="${ep%/}/api/v1/"
  fi
  if [ -f /data/renovate/config.js ] && ! grep -q 'NEXUS_MANAGED' /data/renovate/config.js 2>/dev/null; then
    echo "[Info] keeping existing /data/renovate/config.js"
    return 0
  fi
  cat > /data/renovate/config.js << EOFCFG
// NEXUS_MANAGED
module.exports = {
  platform: 'gitea',
  endpoint: '${ep}',
  token: process.env.RENOVATE_TOKEN,
  gitAuthor: process.env.RENOVATE_GIT_AUTHOR || 'Renovate Bot <renovate@localhost>',
  username: process.env.RENOVATE_USERNAME || 'renovate-bot',
  autodiscover: true,
  persistRepoData: true,
  baseDir: '/data/renovate/cache',
  binarySource: 'global',
  onboardingConfig: { extends: ['config:recommended'] },
};
EOFCFG
  echo "[Info] wrote /data/renovate/config.js endpoint=$ep"
}

# ---------------- 4. Background incremental backup ---------------------------
# The bucket mount throttles under burst I/O and the live work dir already sits
# on it, so this runs infrequently: an early snapshot, then daily.
(
  sleep 1800
  while true; do
    if [ -n "$(ls -A "$GITEA_WORK_DIR" 2>/dev/null)" ]; then
      echo "[Sync] Incremental backup -> /data/gitea_backup"
      mkdir -p /data/gitea_backup
      rsync -a --delete \
        --exclude 'indexers/' --exclude 'tmp/' --exclude 'log/' \
        "$GITEA_WORK_DIR"/ /data/gitea_backup/ >/dev/null 2>&1 || true
    fi
    sleep 86400
  done
) &

# ---------------- 5. Self-issued service tokens ------------------------------
# The Space secrets for pages and Renovate are write-only on the Hub, so a Space
# that is recreated (or whose secrets were never re-entered) silently loses those
# two processes: the wrapper skips anything whose token is empty. Gitea can mint
# its own tokens through the admin CLI, so when a token is missing, generate one
# and remember it on the bucket -- the next start then already has it, and the
# value survives recreating the Space.
#
# Runs before PM2 so the PM2 blocks below see the variables and start both
# processes on the very first boot.
TOKEN_STORE=/data/service-tokens.env
[ -f "$TOKEN_STORE" ] && . "$TOKEN_STORE"

# The DB sits on the bucket and belongs to the `git` account, so every CLI call
# has to run as that account. Fall back to running directly when runuser is
# unavailable (the image always has it, but a missing user must not abort boot).
as_git() {
  if id git >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
    runuser -u git -- env HOME=/home/git USER=git "$@"
  else
    env HOME=/home/git USER=git "$@"
  fi
}

issue_token() {
  # $1 = token name in Gitea, $2 = scopes, $3 = username.
  # Prints the token on success and returns 0, prints nothing on failure.
  local base="$1" scopes="$2" user="$3" out name
  # Gitea is not up yet at this point, so the CLI talks to the database directly.
  # Names must be unique per user: the bucket already carries a `renovate-bot`
  # token from the previous deployment and the CLI rejects a repeat name, so
  # every issued token gets a fresh suffix.
  name="${base}-$(date +%Y%m%d%H%M%S)"
  out="$(as_git /opt/gitea/gitea admin user generate-access-token \
           --config "$CONF" --work-path "$GITEA_WORK_DIR" \
           --custom-path "$GITEA_CUSTOM" \
           --username "$user" --token-name "$name" --scopes "$scopes" --raw 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | tr -d '\r' | tail -1)"
  # A real token is one unbroken run of hex/base64 characters.
  case "$out" in ""|*" "*|*error*|*Error*) return 1 ;; esac
  [ "${#out}" -ge 20 ] || return 1
  printf '%s' "$out"
  return 0
}

write_token_store() {
  # Subshell so the restrictive umask does not leak into the rest of the boot.
  (
    umask 077
    {
      echo "export GITEA_PAGES_TOKEN='${GITEA_PAGES_TOKEN:-}'"
      echo "export RENOVATE_TOKEN='${RENOVATE_TOKEN:-}'"
    } > "$TOKEN_STORE"
  )
  chown git:git "$TOKEN_STORE" 2>/dev/null || true
}

# The `git` account here is the Unix account Gitea runs as, not a Gitea user;
# tokens have to be attached to a row in the `user` table, so pick a real one.
# Pages only reads repository contents, Renovate writes issues and PRs, and the
# admin account exists in every deployment, so both default to it -- pages used
# to run without a token at all because the old secret was unrecoverable.
TOKEN_USER="${GITEA_TOKEN_USER:-xinglingqaq}"
# Renovate's own identity exists in the bucket DB and should keep authoring its
# commits, so prefer it there when the row is present.
if as_git /opt/gitea/gitea admin user list --config "$CONF" --work-path "$GITEA_WORK_DIR" \
     --custom-path "$GITEA_CUSTOM" 2>/dev/null | grep -qw 'renovate-bot'; then
  RENOVATE_USER=renovate-bot
else
  RENOVATE_USER="$TOKEN_USER"
fi

if [ -z "${GITEA_PAGES_TOKEN:-}" ] && [ -x /opt/gitea/gitea ] && [ -f "$CONF" ]; then
  if GITEA_PAGES_TOKEN="$(issue_token gitea-pages read:repository,read:user "$TOKEN_USER")"; then
    echo "[Info] issued GITEA_PAGES_TOKEN"
    write_token_store
  else
    GITEA_PAGES_TOKEN=""
    echo "[WARN] could not issue GITEA_PAGES_TOKEN"
  fi
fi

if [ -z "${RENOVATE_TOKEN:-}" ] && [ -x /opt/gitea/gitea ] && [ -f "$CONF" ]; then
  if RENOVATE_TOKEN="$(issue_token renovate-bot \
        "write:repository,write:issue,write:user,write:package" "$RENOVATE_USER")"; then
    echo "[Info] issued RENOVATE_TOKEN"
    write_token_store
  else
    RENOVATE_TOKEN=""
    echo "[WARN] could not issue RENOVATE_TOKEN"
  fi
fi

# ---------------- 6. PM2: Gitea + pages + Renovate + tunnel ------------------
PM2=/app/node_modules/.bin/pm2
echo "[Info] PM2 bring-up..."
"$PM2" delete all >/dev/null 2>&1 || true

if [ -x /opt/gitea/gitea ]; then
  "$PM2" start /app/run-gitea.sh \
    --name gitea \
    --interpreter bash \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/gitea.log \
    --time
else
  echo "[FATAL] Gitea binary missing at /opt/gitea/gitea"
fi

if [ -x /opt/gitea-pages/gitea-pages ]; then
  if [ -n "${GITEA_PAGES_TOKEN:-}" ]; then
    "$PM2" start /app/run-pages.sh \
      --name pages \
      --interpreter bash \
      --max-restarts 50 \
      --restart-delay 8000 \
      --log /tmp/pages.log \
      --time
  else
    echo "[Info] pages skipped (GITEA_PAGES_TOKEN not set)"
  fi
else
  echo "[WARN] gitea-pages binary missing"
fi

if [ -x /opt/renovate/node_modules/.bin/renovate ]; then
  if [ -n "${RENOVATE_TOKEN:-}" ]; then
    write_renovate_config
    "$PM2" start /app/run-renovate.sh \
      --name renovate \
      --interpreter bash \
      --max-restarts 30 \
      --restart-delay 15000 \
      --log /tmp/renovate.log \
      --time
  else
    echo "[Info] renovate skipped (RENOVATE_TOKEN not set)"
  fi
else
  echo "[WARN] renovate not installed"
fi

# Accept either secret name this deployment has used for the tunnel token.
CF_TOKEN_VAL="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TOKEN:-${SYS_AUTH_KEY:-}}}"
if [ -n "$CF_TOKEN_VAL" ] && [ -x /opt/tunnel/cloudflared ]; then
  "$PM2" start /opt/tunnel/cloudflared \
    --name tunnel \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/tunnel.log \
    --time \
    -- tunnel --no-autoupdate run --token "$CF_TOKEN_VAL"
else
  echo "[Info] Tunnel skipped (no token or cloudflared missing)."
fi

"$PM2" save >/dev/null 2>&1 || true
"$PM2" list || true

echo "[Info] Panel :${PANEL_PORT}  Gitea 127.0.0.1:${GITEA_HTTP_PORT}  pages :${GITEA_PAGES_PORT:-8000}"

# The panel is PID 1's foreground process; PM2 keeps the rest up.
exec node /app/bootstrapper.js
