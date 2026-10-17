#!/bin/bash
set -u
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=C.UTF-8
export JAVA_HOME=/opt/java/current
export PATH="$JAVA_HOME/bin:$PATH"
JAVA_BIN="$JAVA_HOME/bin/java"
[ -x "$JAVA_BIN" ] || JAVA_BIN=$(command -v java)
WAR=/opt/jenkins/jenkins.war
if [ ! -f "$WAR" ] || [ ! -s "$WAR" ]; then
  echo "[jenkins] missing war $WAR"
  exit 1
fi
MAJ=$("$JAVA_BIN" -version 2>&1 | head -1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
if [ -n "$MAJ" ] && [ "$MAJ" -lt 21 ]; then
  echo "[jenkins] Java $MAJ < 21, refuse. Run: update java"
  exit 1
fi
# 中文目录名：file.encoding + sun.jnu.encoding 必须 UTF-8
OPTS="${JAVA_OPTS:--Duser.home=/var/jenkins_local -Djava.io.tmpdir=/var/jenkins_local/tmp}"
case " $OPTS " in
  *"file.encoding"*) ;;
  *) OPTS="$OPTS -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8" ;;
esac
echo "[jenkins] LANG=$LANG file.encoding flags in: $OPTS" 
exec "$JAVA_BIN" $OPTS \
  -jar "$WAR" \
  --httpPort="${JENKINS_HTTP_PORT:-8080}" \
  --httpListenAddress="${JENKINS_LISTEN:-127.0.0.1}" \
  --webroot=/var/jenkins_local/war
