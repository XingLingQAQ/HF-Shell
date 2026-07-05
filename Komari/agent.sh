#!/bin/bash

# ==========================================
# Komari Agent 免 Root + Docker 自适应启动脚本 (传参版)
# ==========================================

# 1. 动态参数解析器
SERVER_URL=""
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--endpoint)
      SERVER_URL="$2"
      shift 2
      ;;
    -a|--auto-discovery)
      TOKEN="$2"
      shift 2
      ;;
    *)
      echo "❌ 未知参数: $1"
      echo "用法: bash install_komari_user.sh -e <服务器地址> --auto-discovery <Token>"
      exit 1
      ;;
  esac
done

# 校验必要参数
if [ -z "$SERVER_URL" ] || [ -z "$TOKEN" ]; then
  echo "❌ 错误: 缺少必要配置参数！"
  echo "👉 示例: bash install_komari_user.sh -e https://servers.xingling.one --auto-discovery your_token_here"
  exit 1
fi

echo ">>> 开始部署 Komari Agent (免 Root 自适应版)..."
echo ">>> 目标面板: $SERVER_URL"
echo ">>> 注册密钥: ${TOKEN:0:5}******"

# 2. 定义普通用户的安装目录
WORKDIR="$HOME/.komari"
AGENT_BIN="$WORKDIR/komari-agent"

# 3. 创建专属隐藏工作目录
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

# 4. 自动检测系统 CPU 架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  DL_ARCH="amd64" ;;
    aarch64) DL_ARCH="arm64" ;;
    armv7l)  DL_ARCH="arm" ;;
    i386)    DL_ARCH="386" ;;
    *)       echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

echo ">>> 检测到系统架构: $DL_ARCH"

# 5. 下载二进制程序
DOWNLOAD_URL="https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-$DL_ARCH"
echo ">>> 正在下载二进制程序..."

if command -v curl >/dev/null 2>&1; then
    curl -sL "$DOWNLOAD_URL" -o "$AGENT_BIN"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$AGENT_BIN" "$DOWNLOAD_URL"
else
    echo "❌ 错误: 系统中未找到 curl 或 wget，无法下载！"
    exit 1
fi

chmod +x "$AGENT_BIN"

# 6. 清理正在运行的旧进程
echo ">>> 正在清理历史进程..."
pkill -f "komari-agent.*$SERVER_URL" || true
sleep 1

# 7. 定义核心守护进程启动命令 (参数已自动固化)
START_CMD="nohup $AGENT_BIN -e $SERVER_URL --auto-discovery $TOKEN > $WORKDIR/komari-agent.log 2>&1 &"

# ==========================================
# 🌟 8. 核心黑科技：Docker 启动脚本自动嗅探与注入
# ==========================================
INJECTED=false

# 判断是否为 Docker 容器环境
if [ -f /.dockerenv ] || grep -q 'docker' /proc/1/cgroup 2>/dev/null; then
    echo ">>> 🐳 检测到 Docker 容器环境，开始寻找启动入口脚本..."
    
    # 常见的 Docker 启动脚本白名单
    for SCRIPT_PATH in "/startup.sh" "/wrapper.sh" "/entrypoint.sh" "/docker-entrypoint.sh" "/app/start.sh"; do
        if [ -f "$SCRIPT_PATH" ]; then
            echo ">>> 🔍 找到潜在的启动脚本: $SCRIPT_PATH"
            
            # 检查是否已经注入过，防止重复添加
            if grep -q "komari-agent" "$SCRIPT_PATH"; then
                echo ">>> ⚡ 脚本中已存在 Komari Agent 启动项，跳过注入。"
                INJECTED=true
                break
            fi
            
            # 手术级安全注入：如果有 exec 阻塞指令，必须插在它前面；没有则追加到末尾
            if grep -q "^exec " "$SCRIPT_PATH"; then
                awk -v cmd="# Start Komari Agent (Auto Injected)\n$START_CMD" '/^exec /{print cmd}1' "$SCRIPT_PATH" > /tmp/injector.tmp 2>/dev/null
                if [ -s /tmp/injector.tmp ]; then
                    cat /tmp/injector.tmp > "$SCRIPT_PATH" 2>/dev/null
                    rm -f /tmp/injector.tmp
                fi
            else
                echo -e "\n# Start Komari Agent (Auto Injected)\n$START_CMD" >> "$SCRIPT_PATH" 2>/dev/null
            fi
            
            # 验证写入是否成功（应对只读挂载的特殊情况）
            if grep -q "komari-agent" "$SCRIPT_PATH"; then
                echo "✅ 已成功将自启命令固化到: $SCRIPT_PATH"
                INJECTED=true
                break
            else
                echo "⚠️ 注入失败 (文件可能为只读或权限不足)，继续寻找下一个脚本..."
            fi
        fi
    done
fi

# ==========================================
# 9. 备用回退机制：传统 Linux 环境使用 Crontab
# ==========================================
if [ "$INJECTED" = false ]; then
    echo ">>> 🔄 未命中 Docker 启动脚本，回退至 Crontab 自启模式..."
    if command -v crontab >/dev/null 2>&1; then
        CRON_CMD="@reboot $START_CMD"
        (crontab -l 2>/dev/null | grep -v "komari-agent"; echo "$CRON_CMD") | crontab -
        echo "✅ Crontab 自启配置完成！"
    else
        echo "❌ 警告: 系统中未找到 crontab，进程如被杀死需手动拉起！"
    fi
fi

# 10. 立刻拉起当前环境的探针
echo ">>> 🚀 正在后台拉起 Komari Agent..."
eval "$START_CMD"

echo "=========================================="
echo "🎉 Komari Agent 部署与保活配置全成功！"
echo "👉 查看实时日志: tail -f $WORKDIR/komari-agent.log"
echo "=========================================="
