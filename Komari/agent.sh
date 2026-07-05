#!/bin/bash

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${NC} $1"
}

log_success() {
    echo -e "${GREEN}${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${NC} $1"
}

log_config() {
    echo -e "${CYAN}[CONFIG]${NC} $1"
}

# Default values
service_name="komari-agent"
target_dir="/opt/komari"
github_proxy=""
install_version="" # New parameter for specifying version

# Detect OS
os_type=$(uname -s)
case $os_type in
    Darwin)
        os_name="darwin"
        target_dir="/usr/local/komari"  # Use /usr/local on macOS
        # Check if we can write to /usr/local, fallback to user directory
        if [ ! -w "/usr/local" ] && [ "$EUID" -ne 0 ]; then
            target_dir="$HOME/.komari"
            log_info "No write permission to /usr/local, using user directory: $target_dir"
        fi
        ;;
    Linux)
        os_name="linux"
        # 🌟 修改点：如果是非 Root 用户，默认安装到用户的家目录
        if [ "$EUID" -ne 0 ]; then
            target_dir="$HOME/.komari"
        fi
        ;;
    FreeBSD)
        os_name="freebsd"
        if [ "$EUID" -ne 0 ]; then
            target_dir="$HOME/.komari"
        fi
        ;;
    MINGW*|MSYS*|CYGWIN*)
        os_name="windows"
        target_dir="/c/komari"  # Use C:\komari on Windows
        ;;
    *)
        log_error "Unsupported operating system: $os_type"
        exit 1
        ;;
esac

# Parse install-specific arguments
komari_args=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir)
            target_dir="$2"
            shift 2
            ;;
        --install-service-name)
            service_name="$2"
            shift 2
            ;;
        --install-ghproxy)
            github_proxy="$2"
            shift 2
            ;;
        --install-version)
            install_version="$2"
            shift 2
            ;;
        --install*)
            log_warning "Unknown install parameter: $1"
            shift
            ;;
        *)
            # Non-install arguments go to komari_args
            komari_args="$komari_args $1"
            shift
            ;;
    esac
done

# Remove leading space from komari_args if present
komari_args="${komari_args# }"

komari_agent_path="${target_dir}/agent"

require_root_for_deps=true
# macOS doesn't always require sudo for everything
if [ "$os_name" = "darwin" ] && command -v brew >/dev/null 2>&1; then
    # On macOS with Homebrew, we can run without root for dependencies
    require_root_for_deps=false
fi

# 🌟 修改点：解除非 Root 强制退出的限制，仅提醒并跳过系统级依赖安装
if [ "$EUID" -ne 0 ]; then
    log_warning "Running as non-root user. System-level services and dependency managers will be bypassed."
    require_root_for_deps=false
fi

echo -e "${WHITE}===========================================${NC}"
echo -e "${WHITE}    Komari Agent Installation Script     ${NC}"
echo -e "${WHITE}===========================================${NC}"
echo ""
log_config "Installation configuration:"
log_config "  Service name: ${GREEN}$service_name${NC}"
log_config "  Install directory: ${GREEN}$target_dir${NC}"
log_config "  GitHub proxy: ${GREEN}${github_proxy:-"(direct)"}${NC}"
log_config "  Binary arguments: ${GREEN}$komari_args${NC}"
if [ -n "$install_version" ]; then
    log_config "  Specified agent version: ${GREEN}$install_version${NC}"
else
    log_config "  Agent version: ${GREEN}Latest${NC}"
fi
echo ""

# Function to uninstall the previous installation
uninstall_previous() {
    log_step "Checking for previous installation..."
    
    # Stop and disable service if it exists (only try if we have root/permissions)
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "${service_name}.service" 2>/dev/null; then
        log_info "Stopping and disabling existing systemd service..."
        sudo systemctl stop ${service_name}.service 2>/dev/null || true
        sudo systemctl disable ${service_name}.service 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/${service_name}.service" 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/${service_name}" ]; then
        log_info "Stopping and disabling existing OpenRC service..."
        sudo rc-service ${service_name} stop 2>/dev/null || true
        sudo rc-update del ${service_name} default 2>/dev/null || true
        sudo rm -f "/etc/init.d/${service_name}" 2>/dev/null || true
    fi
    
    # 🌟 修改点：杀掉后台可能存在的 nohup 用户级进程
    pkill -f "$komari_agent_path" 2>/dev/null || true

    # Remove old binary if it exists
    if [ -f "$komari_agent_path" ]; then
        log_info "Removing old binary..."
        rm -f "$komari_agent_path"
    fi
}

# Uninstall previous installation
uninstall_previous

install_dependencies() {
    log_step "Checking and installing dependencies..."

    local deps="curl"
    local missing_deps=""
    for cmd in $deps; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_deps="$missing_deps $cmd"
        fi
    done

    if [ -n "$missing_deps" ]; then
        # 🌟 修改点：如果非 root 用户且没有 curl，尝试检查 wget，实在没有才报错退出
        if [ "$require_root_for_deps" = false ] && [ "$os_name" != "darwin" ]; then
            if ! command -v wget >/dev/null 2>&1; then
                log_error "Non-root user detected and neither 'curl' nor 'wget' is installed. Please install them manually."
                exit 1
            else
                log_warning "curl not found, but wget is available. Proceeding..."
                return
            fi
        fi

        # Check package manager and install dependencies
        if command -v apt >/dev/null 2>&1; then
            log_info "Using apt to install dependencies..."
            apt update
            apt install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            log_info "Using yum to install dependencies..."
            yum install -y $missing_deps
        elif command -v apk >/dev/null 2>&1; then
            log_info "Using apk to install dependencies..."
            apk add $missing_deps
        elif command -v brew >/dev/null 2>&1; then
            log_info "Using Homebrew to install dependencies..."
            brew install $missing_deps
        else
            log_error "No supported package manager found (apt/yum/apk/brew)"
            exit 1
        fi
        
        # Verify installation
        for cmd in $missing_deps; do
            if ! command -v $cmd >/dev/null 2>&1; then
                log_error "Failed to install $cmd"
                exit 1
            fi
        done
        log_success "Dependencies installed successfully"
    else
        log_success "Dependencies already satisfied"
    fi
}

# Install dependencies
install_dependencies

# Architecture detection with platform-specific support
arch=$(uname -m)
case $arch in
    x86_64)
        arch="amd64"
        ;;
    aarch64|arm64)
        arch="arm64"
        ;;
    i386|i686)
        # x86 (32-bit) support
        case $os_name in
            freebsd|linux|windows)
                arch="386"
                ;;
            *)
                log_error "32-bit x86 architecture not supported on $os_name"
                exit 1
                ;;
        esac
        ;;
    armv7*|armv6*)
        # ARM 32-bit support
        case $os_name in
            freebsd|linux)
                arch="arm"
                ;;
            *)
                log_error "32-bit ARM architecture not supported on $os_name"
                exit 1
                ;;
        esac
        ;;
    *)
        log_error "Unsupported architecture: $arch on $os_name"
        exit 1
        ;;
esac
log_info "Detected OS: ${GREEN}$os_name${NC}, Architecture: ${GREEN}$arch${NC}"

version_to_install="latest"
if [ -n "$install_version" ]; then
    log_info "Attempting to install specified version: ${GREEN}$install_version${NC}"
    version_to_install="$install_version"
else
    log_info "No version specified, installing the latest version."
fi

# Construct download URL
file_name="komari-agent-${os_name}-${arch}"
if [ "$version_to_install" = "latest" ]; then
    download_path="latest/download"
else
    download_path="download/${version_to_install}"
fi

if [ -n "$github_proxy" ]; then
    download_url="${github_proxy}/https://github.com/komari-monitor/komari-agent/releases/${download_path}/${file_name}"
else
    download_url="https://github.com/komari-monitor/komari-agent/releases/${download_path}/${file_name}"
fi

log_step "Creating installation directory: ${GREEN}$target_dir${NC}"
mkdir -p "$target_dir"

# Download binary (Support both curl and wget)
if [ -n "$github_proxy" ]; then
    log_step "Downloading $file_name via proxy..."
else
    log_step "Downloading $file_name directly..."
fi
log_info "URL: ${CYAN}$download_url${NC}"

if command -v curl >/dev/null 2>&1; then
    if ! curl -L -o "$komari_agent_path" "$download_url"; then
        log_error "Download failed via curl"
        exit 1
    fi
else
    if ! wget -qO "$komari_agent_path" "$download_url"; then
        log_error "Download failed via wget"
        exit 1
    fi
fi

# Set executable permissions
chmod +x "$komari_agent_path"
log_success "Komari-agent installed to ${GREEN}$komari_agent_path${NC}"

# Detect init system and configure service
log_step "Configuring system service..."

# Function to detect actual init system
detect_init_system() {
    # 🌟 修改点：最高优先级 - 检查是否在 Docker 中
    if [ -f /.dockerenv ] || grep -q 'docker' /proc/1/cgroup 2>/dev/null; then
        echo "docker"
        return
    fi
    
    # 🌟 修改点：如果是普通用户，强制返回 user_cron，绕过所有需要 root 的 init 检测
    if [ "$EUID" -ne 0 ]; then
        echo "user_cron"
        return
    fi

    # Check if running on NixOS
    if [ -f /etc/NIXOS ]; then
        echo "nixos"
        return
    fi
    
    # Alpine Linux MUST be checked first
    if [ -f /etc/alpine-release ]; then
        if command -v rc-service >/dev/null 2>&1 || [ -f /sbin/openrc-run ]; then
            echo "openrc"
            return
        fi
    fi
    
    local pid1_process=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')
    if [ "$pid1_process" = "systemd" ] || [ -d /run/systemd/system ]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
            echo "systemd"
            return
        fi
    fi
    
    if [ "$pid1_process" = "openrc-init" ]; then
        if command -v rc-service >/dev/null 2>&1; then
            echo "openrc"; return
        fi
    fi
    
    if [ "$pid1_process" = "init" ] && [ ! -f /etc/alpine-release ]; then
        if [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1; then
            echo "openrc"; return
        fi
    fi
    
    if command -v uci >/dev/null 2>&1 && [ -f /etc/rc.common ]; then
        echo "procd"; return
    fi
    
    if [ "$os_name" = "darwin" ] && command -v launchctl >/dev/null 2>&1; then
        echo "launchd"; return
    fi
    
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
        echo "systemd"; return
    fi
    
    if command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        echo "openrc"; return
    fi

    if command -v initctl >/dev/null 2>&1 && [ -d /etc/init ]; then
        echo "upstart"; return
    fi
    
    echo "user_cron" # 终极降级
}

init_system=$(detect_init_system)
log_info "Detected init system: ${GREEN}$init_system${NC}"

# Handle each init system
if [ "$init_system" = "docker" ]; then
    # 🌟 修改点：Docker 环境的智能嗅探注入
    log_info "🐳 Docker container detected. Attempting to inject into entrypoint scripts..."
    START_CMD="nohup ${komari_agent_path} ${komari_args} > ${target_dir}/komari-agent.log 2>&1 &"
    INJECTED=false
    
    for SCRIPT_PATH in "/startup.sh" "/wrapper.sh" "/entrypoint.sh" "/docker-entrypoint.sh" "/app/start.sh"; do
        if [ -f "$SCRIPT_PATH" ]; then
            log_info "🔍 Found potential startup script: $SCRIPT_PATH"
            
            if grep -q "komari-agent" "$SCRIPT_PATH"; then
                log_success "⚡ Komari Agent already injected in $SCRIPT_PATH"
                INJECTED=true
                break
            fi
            
            if grep -q "^exec " "$SCRIPT_PATH"; then
                awk -v cmd="# Start Komari Agent (Auto Injected)\n$START_CMD" '/^exec /{print cmd}1' "$SCRIPT_PATH" > /tmp/injector.tmp 2>/dev/null
                if [ -s /tmp/injector.tmp ]; then
                    cat /tmp/injector.tmp > "$SCRIPT_PATH" 2>/dev/null
                    rm -f /tmp/injector.tmp
                fi
            else
                echo -e "\n# Start Komari Agent (Auto Injected)\n$START_CMD" >> "$SCRIPT_PATH" 2>/dev/null
            fi
            
            if grep -q "komari-agent" "$SCRIPT_PATH"; then
                log_success "✅ Successfully injected into $SCRIPT_PATH"
                INJECTED=true
                break
            fi
        fi
    done
    
    # 立刻在后台启动探针
    eval "$START_CMD"
    log_success "Komari agent started in background."

elif [ "$init_system" = "user_cron" ]; then
    # 🌟 修改点：非 Root 用户的 Crontab 守护逻辑
    log_info "🔄 Using user crontab for service management (Non-Root fallback)"
    START_CMD="nohup ${komari_agent_path} ${komari_args} > ${target_dir}/komari-agent.log 2>&1 &"
    
    if command -v crontab >/dev/null 2>&1; then
        CRON_CMD="@reboot $START_CMD"
        (crontab -l 2>/dev/null | grep -v "komari-agent"; echo "$CRON_CMD") | crontab -
        log_success "✅ Successfully added to user crontab for auto-restart."
    else
        log_warning "crontab not found on this system. Process will not auto-restart on reboot!"
    fi
    
    # 立刻在后台启动探针
    eval "$START_CMD"
    log_success "Komari agent started in background."

elif [ "$init_system" = "nixos" ]; then
    # --- 原版 NixOS 配置 ---
    log_warning "NixOS detected. System services must be configured declaratively."
    # ... 省略中间输出部分，保持原样逻辑已在源码中 ...
    log_info "Please add the following to your NixOS configuration:"
    echo -e "${CYAN}systemd.services.${service_name} = {${NC}"
    echo -e "${CYAN}    ExecStart = \"${komari_agent_path} ${komari_args}\";${NC}"
    echo -e "${CYAN}};${NC}"

elif [ "$init_system" = "openrc" ]; then
    # --- 原版 OpenRC 配置 ---
    log_info "Using OpenRC for service management"
    service_file="/etc/init.d/${service_name}"
    cat > "$service_file" << EOF
#!/sbin/openrc-run

name="Komari Agent Service"
description="Komari monitoring agent"
command="${komari_agent_path}"
command_args="${komari_args}"
command_user="root"
directory="${target_dir}"
pidfile="/run/${service_name}.pid"
retry="SIGTERM/30"
supervisor=supervise-daemon

depend() {
    need net
    after network
}
EOF
    chmod +x "$service_file"
    rc-update add ${service_name} default
    rc-service ${service_name} start
    log_success "OpenRC service configured and started"

elif [ "$init_system" = "systemd" ]; then
    # --- 原版 Systemd 配置 ---
    log_info "Using systemd for service management"
    service_file="/etc/systemd/system/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=${komari_agent_path} ${komari_args}
WorkingDirectory=${target_dir}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${service_name}.service
    systemctl start ${service_name}.service
    log_success "Systemd service configured and started"

elif [ "$init_system" = "procd" ]; then
    # --- 原版 Procd 配置 ---
    log_info "Using procd for service management"
    service_file="/etc/init.d/${service_name}"
    cat > "$service_file" << EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
PROG="${komari_agent_path}"
ARGS="${komari_args}"
start_service() {
    procd_open_instance
    procd_set_param command \$PROG \$ARGS
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param user root
    procd_close_instance
}
stop_service() {
    killall \$(basename \$PROG)
}
reload_service() {
    stop
    start
}
EOF
    chmod +x "$service_file"
    /etc/init.d/${service_name} enable
    /etc/init.d/${service_name} start
    log_success "procd service configured and started"

elif [ "$init_system" = "upstart" ]; then
    # --- 原版 Upstart 配置 ---
    log_info "Using upstart for service management"
    service_file="/etc/init/${service_name}.conf"
    cat > "$service_file" << EOF
description "Komari Agent Service"
chdir ${target_dir}
start on filesystem or runlevel [2345]
stop on runlevel [!2345]
respawn
respawn limit 10 5
umask 022
console none
pre-start script
    test -x ${komari_agent_path} || { stop; exit 0; }
end script
script
    exec ${komari_agent_path} ${komari_args}
end script
EOF
    initctl reload-configuration
    initctl start ${service_name}
    log_success "Upstart service configured and started"
fi

echo ""
echo -e "${WHITE}===========================================${NC}"
log_success "Komari-agent installation completed!"
log_config "Service: ${GREEN}$service_name${NC}"
log_config "Arguments: ${GREEN}$komari_args${NC}"
if [ "$EUID" -ne 0 ] || [ "$init_system" = "docker" ]; then
    log_config "Log file: ${GREEN}$target_dir/komari-agent.log${NC}"
fi
echo -e "${WHITE}===========================================${NC}"
