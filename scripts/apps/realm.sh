#!/bin/bash
# =========================================================
# Realm 转发服务器自动化部署与管理
# =========================================================

# ----------------- 核心安装逻辑 -----------------
install_realm() {
    info "正在准备部署 Realm 转发服务器..."

    # 1. 环境检查与架构检测
    local arch
    case "$(uname -m)" in
        x86_64) arch="x86_64-unknown-linux-gnu" ;;
        aarch64) arch="aarch64-unknown-linux-gnu" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac

    # 2. 获取最新版本
    info "正在获取 Realm 最新版本信息..."
    local latest_version
    latest_version=$(curl -sL https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$latest_version" ]]; then
        latest_version="v2.7.0" # 兜底稳定版
        warn "获取最新版本失败，将尝试安装兜底版本: $latest_version"
    fi

    # 3. 下载与安装
    local download_url="https://github.com/zhboner/realm/releases/download/${latest_version}/realm-${arch}.tar.gz"
    local tmp_file="/tmp/realm.tar.gz"
    local install_dir="/opt/realm"
    
    download_with_fallback "$tmp_file" "$download_url" || return 1
    
    mkdir -p "$install_dir"
    tar -xzf "$tmp_file" -C "$install_dir" || { err "解压 Realm 失败。"; return 1; }
    chmod +x "${install_dir}/realm"
    rm -f "$tmp_file"

    # 4. 创建运行用户与配置目录
    create_system_user "realm"
    
    mkdir -p /etc/realm
    if [[ ! -f /etc/realm/config.toml ]]; then
        cat > /etc/realm/config.toml << EOF
# Realm 配置文件 (TOML)
# 详情参考: https://github.com/zhboner/realm

[[endpoints]]
listen = "0.0.0.0:10000"
remote = "1.1.1.1:443"
EOF
        chown -R realm:realm /etc/realm
    fi

    # 5. 配置 Systemd 服务
    deploy_systemd_service "realm" << EOF
[Unit]
Description=Realm Relay Service
After=network.target

[Service]
Type=simple
User=realm
Group=realm
WorkingDirectory=/etc/realm
ExecStart=/opt/realm/realm -c /etc/realm/config.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# --- Security Sandboxing ---
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# ---------------------------

[Install]
WantedBy=multi-user.target
EOF

    if systemctl is-active --quiet realm; then
        info "✅ Realm 已成功安装并启动。"
        info "配置文件路径: /etc/realm/config.toml"
        info "您可以通过编辑该文件并运行 'systemctl restart realm' 来管理转发规则。"
    else
        warn "Realm 已安装，但当前未启动，请检查配置文件是否正确。"
    fi
}

# ----------------- 深度卸载逻辑 -----------------
uninstall_realm() {
    info "准备深度清理 Realm 及其残留..."

    systemctl stop realm >/dev/null 2>&1
    systemctl disable realm >/dev/null 2>&1
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload

    rm -rf /opt/realm
    rm -rf /etc/realm
    
    if id -u realm >/dev/null 2>&1; then
        userdel realm
    fi

    info "✅ Realm 已彻底从系统中移除。"
}
