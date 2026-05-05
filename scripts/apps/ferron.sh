#!/bin/bash
# =========================================================
# Ferron 高性能 Web 服务器自动化部署 (官方源标准版)
# =========================================================

# ----------------- 核心安装逻辑 -----------------
install_ferron() {
    info "正在通过 Ferron 官方标准仓库部署 Web 服务器..."

    # 1. 补齐仓库管理依赖
    safe_apt_install curl gnupg2 ca-certificates lsb-release debian-archive-keyring || return 1

    # 2. 注入官方签名密钥 (采用现代 keyring 隔离模式)
    info "正在添加 Ferron 官方 PGP 签名密钥..."
    local keyring="/usr/share/keyrings/ferron-keyring.gpg"
    curl -fsSL https://deb.ferron.sh/signing.pgp | gpg --dearmor -o "$keyring" --yes || {
        err "获取签名密钥失败，请检查网络连接。"
        return 1
    }

    # 3. 配置 APT 软件源
    info "正在配置官方 APT 软件源..."
    local codename
    codename=$(lsb_release -cs)
    echo "deb [signed-by=$keyring] https://deb.ferron.sh $codename main" | tee /etc/apt/sources.list.d/ferron.list >/dev/null

    # 4. 执行安装
    info "同步包缓存并安装 Ferron..."
    apt-get update -yq >/dev/null 2>&1
    safe_apt_install ferron || {
        err "Ferron 软件包安装失败。可能是不支持当前系统发行版 ($codename)。"
        return 1
    }

    # 5. 基础环境初始化
    if [[ ! -d "/var/www/ferron" ]]; then
        mkdir -p /var/www/ferron
        echo "<h1>Ferron is installed successfully!</h1>" > /var/www/ferron/index.html
        chown -R ferron:ferron /var/www/ferron
    fi

    # --- 安全沙箱加固 (Systemd Override) ---
    inject_service_override "ferron" << EOF
[Service]
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
EOF

    if systemctl is-active --quiet ferron; then
        info "✅ Ferron 已通过官方仓库成功安装并运行。"
        info "管理指令: systemctl [start|stop|restart|reload] ferron"
        info "主配置文件: /etc/ferron.kdl (V2 版本采用 KDL 语法)"
        info "Web 根目录: /var/www/ferron"
        info "访问测试: http://$(curl -s4 ifconfig.me || echo 'localhost')"
    else
        warn "Ferron 已安装，但服务未正常启动，请检查 /etc/ferron.kdl 配置。"
    fi
}

# ----------------- 深度卸载逻辑 -----------------
uninstall_ferron() {
    info "正在执行 Ferron 深度清理程序..."

    # 1. 停止并移除服务
    systemctl stop ferron >/dev/null 2>&1
    systemctl disable ferron >/dev/null 2>&1

    # 2. 卸载软件包并清理残留配置
    apt-get purge -yq ferron >/dev/null 2>&1
    apt-get autoremove -yq >/dev/null 2>&1

    # 3. 清理仓库配置
    rm -f /etc/apt/sources.list.d/ferron.list
    rm -f /usr/share/keyrings/ferron-keyring.gpg
    apt-get update -yq >/dev/null 2>&1

    # 4. 暴力清理目录残留
    rm -rf /etc/ferron.kdl /var/log/ferron /var/www/ferron /etc/systemd/system/ferron.service.d
    
    info "✅ Ferron 官方组件及仓库配置已彻底移除。"
}
