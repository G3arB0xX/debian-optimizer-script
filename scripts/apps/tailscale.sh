#!/bin/bash
# =========================================================
# Tailscale 官方组网组件管理
# =========================================================

install_tailscale() {
    local is_update="false"
    if command -v tailscale >/dev/null 2>&1; then
        is_update="true"
        info "正在拉取 Tailscale 最新版本进行更新..."
    else
        info "开始全新部署 Tailscale 官方节点..."
    fi
    
    # 获取官方安装脚本
    curl -fsSL --connect-timeout 10 https://tailscale.com/install.sh -o /tmp/tailscale-install.sh || {
        err "获取官方脚本失败，请检查服务器是否能直连 tailscale.com"
        return 1
    }
    
    # 执行安装，静默处理正常输出，保留错误日志
    sh /tmp/tailscale-install.sh >/dev/null 2>&1 || {
        err "Tailscale 部署失败，可能是 APT 源拉取超时。"
        return 1
    }
    
    # --- 安全沙箱加固 (Systemd Override) ---
    inject_service_override "tailscaled" << EOF
[Service]
ProtectSystem=full
# Tailscale 需要在 /root/.config 或其他地方保存状态，暂不开启 ProtectHome
PrivateTmp=true
NoNewPrivileges=true
# Tailscale 需要极高的权限来管理网络
EOF
    
    # 自动在防火墙放行 P2P 打洞所需的 UDP 端口 (默认 41641)
    add_fw_rule "41641" "udp" "Tailscale_P2P"
    
    if [[ "$is_update" == "false" ]]; then
        info "✅ Tailscale 部署成功！"
        echo -e "\n${YELLOW}重要提示：${NC}"
        echo -e "当前节点尚未绑定，请在终端执行: ${GREEN}tailscale up${NC} 获取登录链接。"
    else
        info "✅ Tailscale 已更新至最新版本。"
    fi
}

uninstall_tailscale() {
    info "正在卸载 Tailscale..."
    # 强制清理包管理器记录
    apt-get purge -yq tailscale >/dev/null 2>&1
    
    info "清理持久化数据与状态残留..."
    rm -rf /var/lib/tailscale /etc/tailscale /usr/bin/tailscale /usr/sbin/tailscaled /opt/tailscale
    
    # 清理防火墙规则
    [[ -f "/etc/nftables/debopti.d/Tailscale_P2P.nft" ]] && rm -f "/etc/nftables/debopti.d/Tailscale_P2P.nft" && nft -f /etc/nftables.conf

    info "✅ Tailscale 已彻底移除。"
}
