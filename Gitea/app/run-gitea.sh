#!/bin/bash
# Gitea server, supervised by PM2.
#
# Gitea refuses to run as root, so once the `git` account exists we drop to it
# via runuser/su. GITEA_I_AM_BEING_UNSAFE_RUNNING_AS_ROOT is only a last-resort
# escape hatch for images where the account could not be created.
set -u

export GITEA_WORK_DIR="${GITEA_WORK_DIR:-/data/gitea}"
export GITEA_CUSTOM="${GITEA_CUSTOM:-/data/gitea/custom}"
export USER=git
export HOME=/home/git
export USERNAME=git

cd "$GITEA_WORK_DIR" || exit 1

CONF="$GITEA_WORK_DIR/custom/conf/app.ini"

if [ "$(id -u)" = "0" ] && id git >/dev/null 2>&1; then
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u git -- env \
      HOME=/home/git USER=git USERNAME=git \
      GITEA_WORK_DIR="$GITEA_WORK_DIR" GITEA_CUSTOM="$GITEA_CUSTOM" \
      /opt/gitea/gitea web \
        --config "$CONF" \
        --work-path "$GITEA_WORK_DIR" \
        --custom-path "$GITEA_CUSTOM"
  else
    exec su -s /bin/bash git -c "export HOME=/home/git USER=git GITEA_WORK_DIR='$GITEA_WORK_DIR' GITEA_CUSTOM='$GITEA_CUSTOM'; cd '$GITEA_WORK_DIR' && exec /opt/gitea/gitea web --config '$CONF' --work-path '$GITEA_WORK_DIR' --custom-path '$GITEA_CUSTOM'"
  fi
fi

echo "[gitea] WARNING: no usable 'git' account, running as root anyway" >&2
export GITEA_I_AM_BEING_UNSAFE_RUNNING_AS_ROOT=true
exec /opt/gitea/gitea web \
  --config "$CONF" \
  --work-path "$GITEA_WORK_DIR" \
  --custom-path "$GITEA_CUSTOM"
