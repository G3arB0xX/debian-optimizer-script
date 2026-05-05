#!/bin/bash
# =========================================================
# Easytier 虚拟组网组件管理
# =========================================================

install_easytier() {
    info "正在安装/更新 Easytier 跨平台组网引擎..."
    
    # 依赖检查
    if ! command -v unzip >/dev/null 2>&1; then
        info "补齐解压工具 (unzip)..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq unzip >/dev/null 2>&1
    fi

    # 获取官方安装脚本
    download_with_fallback "/tmp/easytier-install.sh" "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh" || return 1
    
    # 网络加速适配
    local proxy_args="--no-gh-proxy"
    [[ "$IS_CN_REGION" == "true" ]] && proxy_args="--gh-proxy https://ghfast.top/"
    
    # 智能判定：已安装则 update，未安装则 install
    if [[ -d "/opt/easytier" ]] || command -v easytier-core >/dev/null 2>&1; then
        info "检测到旧版本，执行平滑更新..."
        bash /tmp/easytier-install.sh update $proxy_args || return 1
    else
        info "执行全新安装部署..."
        bash /tmp/easytier-install.sh install $proxy_args || return 1
    fi
    
    # --- 安全沙箱加固 (Systemd Override) ---
    inject_service_override "easytier@" << EOF
[Service]
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# Easytier 需要网卡管理能力
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF
    
    # 防火墙 P2P 端口自动放行 (nftables)
    # 默认使用 11010 - 11015 范围以支持多实例并发打洞
    add_fw_rule "11010-11015" "tcp/udp" "Easytier_P2P"
    
    info "✅ Easytier 操作完成。"
    info "主配置文件路径: /opt/easytier/config/default.conf"
}

uninstall_easytier() {
    info "准备彻底卸载 Easytier..."
    
    if [[ ! -f "/tmp/easytier-install.sh" ]]; then
        download_with_fallback "/tmp/easytier-install.sh" "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh" || return 1
    fi
    # 调用官方卸载逻辑
    bash /tmp/easytier-install.sh uninstall >/dev/null 2>&1

    info "执行深度清理 (残留配置与 Systemd 单元)..."
    systemctl stop easytier >/dev/null 2>&1
    systemctl disable easytier >/dev/null 2>&1
    rm -rf /etc/systemd/system/easytier*
    rm -rf /etc/systemd/system/easytier@.service.d
    systemctl daemon-reload
    
    # 彻底抹除二进制与安装目录
    rm -rf /usr/bin/easytier-core /usr/local/bin/easytier-core /opt/easytier /opt/easytier-core
    
    # 清理防火墙规则
    [[ -f "/etc/nftables/debopti.d/Easytier_P2P.nft" ]] && rm -f "/etc/nftables/debopti.d/Easytier_P2P.nft" && nft -f /etc/nftables.conf

    info "✅ Easytier 已从系统完全移除。"
}
