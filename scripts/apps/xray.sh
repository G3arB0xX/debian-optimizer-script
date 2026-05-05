#!/bin/bash
# =========================================================
# Xray Core 自动化部署与规则管理
# =========================================================

# ----------------- 核心安装逻辑 -----------------
install_xray() {
    info "正在从 XTLS 官方源部署/更新 Xray Core..."
    
    # 获取官方安装脚本，利用 fallback 机制保障国内成功率
    download_with_fallback "/tmp/xray-install.sh" "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh" || return 1
    
    # 执行官方安装命令
    bash /tmp/xray-install.sh install || { err "Xray 核心安装失败。"; return 1; }
    
    # 部署第三方增强版路由规则 (GeoData)
    setup_xray_geodata || true

    # --- 安全沙箱加固 (Systemd Override) ---
    inject_service_override "xray" << EOF
[Service]
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# 限制 Capabilities，即便以 root 运行也只能执行必要操作
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF
    
    if systemctl is-active --quiet xray; then
        info "✅ Xray Core 已成功安装并运行。"
    else
        warn "Xray 已安装，但当前未启动 (可能是缺失配置文件)。"
    fi
}

# ----------------- 深度卸载逻辑 -----------------
uninstall_xray() {
    info "准备深度清理 Xray Core 及其生态残留..."
    
    # 优先调用官方卸载逻辑
    if [[ ! -f "/tmp/xray-install.sh" ]]; then
        download_with_fallback "/tmp/xray-install.sh" "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh" || return 1
    fi
    bash /tmp/xray-install.sh remove >/dev/null 2>&1
    
    # 停止服务并清理 Systemd 单元
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    rm -rf /etc/systemd/system/xray*
    systemctl daemon-reload
    
    # 清理第三方规则与定时任务
    cleanup_xray_geodata
    
    # 暴力扫荡所有可能残留的二进制与配置目录，确保环境原子化还原
    rm -rf /usr/bin/xray /usr/local/bin/xray /usr/local/etc/xray /etc/xray /opt/xray /etc/systemd/system/xray.service.d
    
    info "✅ Xray 已彻底从系统中移除。"
}

# ----------------- 第三方规则 (Loyalsoldier) 部署 -----------------
setup_xray_geodata() {
    info "部署 Loyalsoldier 高级路由规则 (geosite.dat)..."
    local asset_dir="/usr/local/share/xray"
    mkdir -p "$asset_dir"
    
    local repo_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    
    # 使用高可用下载
    if download_with_fallback "$asset_dir/ls-geosite.dat.new" "$repo_url"; then
        local filesize=$(stat -c%s "$asset_dir/ls-geosite.dat.new" 2>/dev/null || echo 0)
        # 防御性检查：确保文件不是镜像站返回的 404 HTML
        if [[ $filesize -gt 102400 ]]; then
            mv -f "$asset_dir/ls-geosite.dat.new" "$asset_dir/ls-geosite.dat"
            info "✅ 路由规则已就绪。"
        else
            rm -f "$asset_dir/ls-geosite.dat.new"
            warn "规则文件校验失败 (体积异常)，跳过更新。"
            return 1
        fi
    fi

    # 配置自动更新 Cron 任务
    local cron_script="/usr/local/bin/xray-rule-update.sh"
    cat > "$cron_script" << 'EOF'
#!/bin/bash
# Xray 规则自动更新脚本
ASSET_DIR="/usr/local/share/xray"
TARGET_FILE="${ASSET_DIR}/ls-geosite.dat"
TMP_FILE="${TARGET_FILE}.new"
URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
# 国内加速逻辑
DOWNLOAD_URL="$URL"
curl -sSL -m 5 https://api.ip.sb/geoip 2>/dev/null | grep -i -q "China" && DOWNLOAD_URL="https://ghfast.top/${URL}"

if curl -fsSL -m 60 -o "$TMP_FILE" "$DOWNLOAD_URL" && [[ -s "$TMP_FILE" ]]; then
    mv -f "$TMP_FILE" "$TARGET_FILE"
    systemctl restart xray >/dev/null 2>&1
else
    rm -f "$TMP_FILE"
fi
EOF
    chmod +x "$cron_script"
    
    # 写入每周一凌晨 3:30 自动执行更新
    if ! crontab -l 2>/dev/null | grep -q "$cron_script"; then
        (crontab -l 2>/dev/null; echo "30 3 * * 1 $cron_script >/dev/null 2>&1") | crontab - || true
    fi
}

# ----------------- 规则清理 -----------------
cleanup_xray_geodata() {
    info "清理路由规则及相关定时任务..."
    local cron_script="/usr/local/bin/xray-rule-update.sh"
    rm -rf /usr/local/share/xray
    rm -f "$cron_script"
    # 移除 crontab 条目
    if crontab -l 2>/dev/null | grep -q "$cron_script"; then
        (crontab -l 2>/dev/null; grep -v "$cron_script") | crontab - || true
    fi
}
