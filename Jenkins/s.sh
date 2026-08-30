#!/bin/bash

set -u

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8

export PM2_HOME="${PM2_HOME:-/var/jenkins_local/.pm2}"
export JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_local}"
export JAVA_HOME="${JAVA_HOME:-/opt/java/current}"
export PATH="/app/bin:$JAVA_HOME/bin:/opt/tunnel:/usr/local/bin:$PATH"
export JAVA_OPTS="${JAVA_OPTS:--Duser.home=/var/jenkins_local -Djava.io.tmpdir=/var/jenkins_local/tmp -Djenkins.install.runSetupWizard=false -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8}"

export JENKINS_HTTP_PORT="${PANEL_PORT:-7860}"
export JENKINS_LISTEN="0.0.0.0"

mkdir -p /app/bin /var/jenkins_local/tmp /tmp /opt/jenkins /opt/java /opt/tunnel /data/tmp "$PM2_HOME"
chmod 777 /var/jenkins_local/tmp /tmp 2>/dev/null || true
cd /app

ensure_java21() {
  if [ -x /opt/java/current/bin/java ]; then
    MAJ=$(/opt/java/current/bin/java -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
    if [ -n "$MAJ" ] && [ "$MAJ" -ge 21 ]; then
      echo "[startup] Java ok: $(/opt/java/current/bin/java -version 2>&1 | head -1)"
      return 0
    fi
  fi
  echo "[startup] Installing Temurin JDK 21..."
  STAGING=/opt/java/staging
  rm -rf "$STAGING"; mkdir -p "$STAGING" /opt/java
  curl -fL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" -o /tmp/jdk21.tar.gz || return 1
  tar -xzf /tmp/jdk21.tar.gz -C "$STAGING"
  INNER=$(find "$STAGING" -maxdepth 1 -type d -name 'jdk-*' | head -1)
  DEST="/opt/java/$(basename "$INNER")"
  rm -rf "$DEST"; mv "$INNER" "$DEST"
  ln -sfn "$DEST" /opt/java/current
  VER=$("$DEST/bin/java" -version 2>&1 | head -1)
  echo "$VER" > /opt/java/version
  rm -rf "$STAGING" /tmp/jdk21.tar.gz
  echo "[startup] Java installed: $VER"
}

ensure_jenkins_war() {
  if [ -f /opt/jenkins/jenkins.war ] && [ -s /opt/jenkins/jenkins.war ]; then
    echo "[startup] Jenkins war ok: $(cat /opt/jenkins/version 2>/dev/null || echo unknown)"
    return 0
  fi
  echo "[startup] Downloading Jenkins LTS war..."
  mkdir -p /opt/jenkins
  LATEST=$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt 2>/dev/null | tr -d '\r' | head -1 || echo "latest")
  curl -fL "https://get.jenkins.io/war-stable/${LATEST}/jenkins.war" -o /tmp/jenkins.war.new || return 1
  mv /tmp/jenkins.war.new /opt/jenkins/jenkins.war
  echo "$LATEST" > /opt/jenkins/version
  echo "[startup] Jenkins war: $LATEST"
}

ensure_cloudflared() {
  if [ -x /opt/tunnel/cloudflared ]; then
    echo "[startup] cloudflared ok"
    return 0
  fi
  echo "[startup] Downloading cloudflared..."
  mkdir -p /opt/tunnel
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o /tmp/cloudflared.new || return 1
  chmod +x /tmp/cloudflared.new
  mv /tmp/cloudflared.new /opt/tunnel/cloudflared
}

ensure_java21 || echo "[startup] WARN java21 install failed"
ensure_jenkins_war || echo "[startup] WARN jenkins download failed"
ensure_cloudflared || echo "[startup] WARN tunnel download failed"



cat << 'EOF' > /app/bin/update-jenkins
#!/bin/bash
set -e
echo "=== 检查 更新 ==="
LATEST=$(curl -fsSL https://updates.jenkins.io/stable/latestCore.txt | tr -d '\r' | head -1)
LOCAL=$(cat /opt/jenkins/version 2>/dev/null || echo none)
echo "本地版本: $LOCAL | 最新版本: $LATEST"
if [ "$LATEST" == "$LOCAL" ]; then echo "已是最新版本，无需更新。"; exit 0; fi
echo "下载中..."
curl -fL "https://get.jenkins.io/war-stable/$LATEST/jenkins.war" -o /tmp/jenkins.war.new
SIZE=$(wc -c < /tmp/jenkins.war.new | tr -d ' ')
if [ "${SIZE:-0}" -lt 1000000 ]; then echo "下载失败，文件过小"; exit 1; fi
mv /tmp/jenkins.war.new /opt/jenkins/jenkins.war
echo "$LATEST" > /opt/jenkins/version
pm2 restart jenkins --update-env || true
echo "✅ J已更新并重启。"
EOF

cat << 'EOF' > /app/bin/update-java
#!/bin/bash
set -e
echo "=== 检查 Java 21 (Temurin) 更新 ==="
# 简化逻辑，直接覆盖下载最新 GA 稳定版
STAGING=/opt/java/staging
rm -rf "$STAGING"; mkdir -p "$STAGING"
echo "下载中..."
curl -fL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk" -o /tmp/jdk21.tar.gz
SIZE=$(wc -c < /tmp/jdk21.tar.gz | tr -d ' ')
if [ "${SIZE:-0}" -lt 50000000 ]; then echo "下载失败，文件过小"; exit 1; fi
tar -xzf /tmp/jdk21.tar.gz -C "$STAGING"
INNER=$(find "$STAGING" -maxdepth 1 -type d -name "jdk-*" | head -1)
DEST="/opt/java/$(basename "$INNER")"
rm -rf "$DEST"; mv "$INNER" "$DEST"
ln -sfn "$DEST" /opt/java/current
rm -rf "$STAGING" /tmp/jdk21.tar.gz
VER=$(/opt/java/current/bin/java -version 2>&1 | head -1)
echo "$VER" > /opt/java/version
echo "✅ Java 已更新为: $VER"
pm2 restart jenkins --update-env || true
EOF

cat << 'EOF' > /app/bin/update-sys
#!/bin/bash
set -e

API_URL=$(echo "aHR0cHM6Ly9hcGkuZ2l0aHViLmNvbS9yZXBvcy9jbG91ZGZsYXJlL2Nsb3VkZmxhcmVkL3JlbGVhc2VzL2xhdGVzdA==" | base64 -d)
DL_URL=$(echo "aHR0cHM6Ly9naXRodWIuY29tL2Nsb3VkZmxhcmUvY2xvdWRmbGFyZWQvcmVsZWFzZXMvbGF0ZXN0L2Rvd25sb2FkL2Nsb3VkZmxhcmVkLWxpbnV4LWFtZDY0" | base64 -d)

BIN_DIR="/opt/sys_core"
BIN_NAME="sys-daemon"
PM2_NAME="sys-daemon" # PM2 中显示的进程名

echo "=== 检查核心网络组件更新 ==="
LATEST=$(curl -s "$API_URL" | grep '"tag_name":' | head -1 | cut -d'"' -f4)
LOCAL=$(cat $BIN_DIR/version 2>/dev/null || echo none)

echo "本地版本: $LOCAL | 最新版本: $LATEST"
if [ "$LATEST" == "$LOCAL" ]; then 
    echo "已是最新版本。"
    exit 0
fi

echo "下载中..."
mkdir -p "$BIN_DIR"
curl -fsSL "$DL_URL" -o /tmp/core_update.tmp
chmod +x /tmp/core_update.tmp

mv /tmp/core_update.tmp "$BIN_DIR/$BIN_NAME"
echo "$LATEST" > "$BIN_DIR/version"

if pm2 describe $PM2_NAME >/dev/null 2>&1; then 
    pm2 restart $PM2_NAME --update-env
fi
echo "✅ 核心组件已更新并重启。"
EOF
chmod +x /app/bin/update-sys
chmod +x /app/bin/update-jenkins /app/bin/update-java /app/bin/update-tunnel

# ---------- 编写 J启动脚本 (替代原本 Base64) ----------
cat << 'EOF' > /opt/jenkins/run-jenkins.sh
#!/bin/bash
set -u
export LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8
export JAVA_HOME=/opt/java/current
export PATH="$JAVA_HOME/bin:$PATH"
JAVA_BIN="$JAVA_HOME/bin/java"

if [ ! -x "$JAVA_BIN" ]; then JAVA_BIN=$(command -v java); fi
if [ ! -s /opt/jenkins/jenkins.war ]; then echo "Missing war"; exit 1; fi

OPTS="${JAVA_OPTS:-}"
case " $OPTS " in
  *"file.encoding"*) ;;
  *) OPTS="$OPTS -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8" ;;
esac

echo "[jenkins] Starting on ${JENKINS_LISTEN:-0.0.0.0}:${JENKINS_HTTP_PORT:-7860}"
exec "$JAVA_BIN" $OPTS \
  -jar /opt/jenkins/jenkins.war \
  --httpPort="${JENKINS_HTTP_PORT:-7860}" \
  --httpListenAddress="${JENKINS_LISTEN:-0.0.0.0}" \
  --webroot=/var/jenkins_local/war
EOF
chmod +x /opt/jenkins/run-jenkins.sh

# ---------- PM2 初始化与进程拉起 ----------
if [ ! -d /app/node_modules/pm2 ]; then
  echo "[Info] Installing PM2 locally..."
  npm install --prefix /app pm2 --omit=dev >/dev/null 2>&1
fi
export PATH="/app/node_modules/.bin:$PATH"

echo "[Info] Starting services via PM2..."
pm2 delete all 2>/dev/null || true

if [ -x /opt/java/current/bin/java ] && [ -f /opt/jenkins/jenkins.war ]; then
  pm2 start /opt/jenkins/run-jenkins.sh \
    --name jenkins \
    --interpreter bash \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/jenkins.log \
    --time
else
  echo "[WARN] Jenkins requirements missing."
fi

CF_TOKEN_VAL="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TOKEN:-}}"
if [ -n "$CF_TOKEN_VAL" ] && [ -x /opt/tunnel/cloudflared ]; then
  pm2 start /opt/tunnel/cloudflared \
    --name tunnel \
    --max-restarts 100 \
    --restart-delay 5000 \
    --log /tmp/tunnel.log \
    --time \
    -- tunnel --no-autoupdate run --token "$CF_TOKEN_VAL"
fi

pm2 save 2>/dev/null || true

echo "[Info] Startup complete. Jenkins is mapped to internal port 7860."
echo "[Info] To update components manually, use console commands: update-jenkins, update-java, update-tunnel"

exec pm2 logs
