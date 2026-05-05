#!/bin/bash
# =========================================================
# WARP & Usque 代理生态组件 (高性能优化版)
# =========================================================

# ----------------- Cloudflare WARP CLI -----------------
install_warp() {
    local is_update="false"
    [[ $(command -v warp-cli) ]] && is_update="true"

    info "正在配置 Cloudflare 官方 APT 通道..."
    # 补齐 LSB 依赖以便精准获取 Debian 代号 (如 bullseye/bookworm)
    safe_apt_install lsb-release gnupg || return 1
    
    # 导入 GPG 密钥
    curl -fsSL --connect-timeout 5 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg || return 1
    
    # 动态写入软件源
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
    
    info "拉取最新 WARP 客户端并执行部署..."
    apt-get update -yq >/dev/null 2>&1
    safe_apt_install cloudflare-warp || return 1
    
    # 激活并等待守护进程初始化
    systemctl enable --now warp-svc >/dev/null 2>&1
    local retry=0
    while ! warp-cli --accept-tos status >/dev/null 2>&1; do
        sleep 1
        ((retry++))
        [[ $retry -ge 10 ]] && { err "WARP 守护进程超时未响应。"; return 1; }
    done

    if [[ "$is_update" == "false" ]]; then
        info "正在执行设备注册与协议栈优化..."
        warp-cli --accept-tos registration new >/dev/null 2>&1 || { err "注册失败 (国内机器可能需要开启代理后再试)"; return 1; }
        
        # 优化项 1: 强制使用 WireGuard 协议替代开销较大的 MASQUE (HTTP/3)
        warp-cli --accept-tos tunnel protocol set WireGuard >/dev/null 2>&1
        # 优化项 2: 禁用内置的遥测 DNS 日志以降低磁盘 I/O
        warp-cli --accept-tos dns families off >/dev/null 2>&1
        # 优化项 3: 设置为全局 Socks5 代理模式 (默认端口 40000)
        warp-cli --accept-tos mode proxy >/dev/null 2>&1
        warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
        warp-cli --accept-tos connect >/dev/null 2>&1
    fi

    # --- 系统级性能加固 (Systemd Override) ---
    inject_service_override "warp-svc" << EOF
[Service]
# 设置内存软上限，触发 GC 回收 (80M)
MemoryHigh=80M
# 设置内存硬上限，防止内存泄露撑爆 VPS (120M)
MemoryMax=120M
# 屏蔽高频调试日志，仅保留 Error 级输出以保护磁盘寿命
LogLevelMax=error

# --- Security Sandboxing ---
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# WARP 守护进程通常需要 root 权限和较多能力，这里暂不限制 CapabilityBoundingSet 以防断网
# ---------------------------
EOF
    
    info "✅ Cloudflare WARP 部署完成！"
    info "本地 Socks5 入口: 127.0.0.1:40000"
}

uninstall_warp() {
    info "正在卸载 Cloudflare WARP 及其配置..."
    warp-cli --accept-tos disconnect >/dev/null 2>&1
    warp-cli --accept-tos registration delete >/dev/null 2>&1
    apt-get purge -yq cloudflare-warp >/dev/null 2>&1
    
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -rf /etc/systemd/system/warp-svc.service.d /opt/cloudflare-warp
    
    info "✅ WARP 已彻底移除。"
}

# ----------------- Usque (MASQUE) -----------------
install_usque() {
    info "正在部署 Usque (MASQUE 协议) 高速客户端..."
    safe_apt_install jq unzip || return 1
    
    local arch=""
    [[ "$(uname -m)" == "x86_64" ]] && arch="amd64" || arch="arm64"
    
    # 获取最新发布版本
    local dl_url=$(curl -sSL --connect-timeout 10 "https://api.github.com/repos/Diniboy1123/usque/releases/latest" | jq -r ".assets[] | select(.name | contains(\"linux_${arch}.zip\")) | .browser_download_url" 2>/dev/null)
    
    [[ -z "$dl_url" || "$dl_url" == "null" ]] && { err "GitHub API 获取下载链接失败。"; return 1; }
    
    mkdir -p /opt/usque
    local tmp_zip="/tmp/usque.zip"
    download_with_fallback "$tmp_zip" "$dl_url" || return 1
    
    unzip -qo "$tmp_zip" -d /opt/usque/
    chmod +x /opt/usque/usque
    
    # 初始化标准运行用户
    create_system_user "usque"
    chown -R usque:usque /opt/usque

    # 部署 Systemd 服务
    deploy_systemd_service "usque" << EOF
[Unit]
Description=Usque MASQUE Socks5 Service
After=network.target

[Service]
Type=simple
User=usque
Group=usque
WorkingDirectory=/opt/usque
ExecStart=/opt/usque/usque socks -b 127.0.0.1 -p 40001
Restart=on-failure
RestartSec=5

# --- Security Sandboxing ---
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# ---------------------------

[Install]
WantedBy=multi-user.target
EOF
    
    info "✅ Usque 部署完成，代理端口: 40001"
}

uninstall_usque() {
    info "正在卸载 Usque..."
    systemctl stop usque >/dev/null 2>&1
    systemctl disable usque >/dev/null 2>&1
    rm -f /etc/systemd/system/usque.service
    rm -rf /opt/usque
    id -u usque >/dev/null 2>&1 && userdel usque
    info "✅ Usque 已移除。"
}

# ----------------- Xray-WireGuard 配置生成器 -----------------
generate_warp_xray() {
    info "正在生成基于 WireGuard 协议的 Xray WARP 出站配置..."
    # 依赖检查
    apt-get install -yq jq >/dev/null 2>&1
    
    local arch=""
    [[ "$(uname -m)" == "x86_64" ]] && arch="amd64" || arch="arm64"
    
    # 临时拉取 wgcf 工具进行注册
    local wgcf_bin="/tmp/wgcf"
    download_with_fallback "$wgcf_bin" "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${arch}" || return 1
    chmod +x "$wgcf_bin"
    
    local work_dir="/tmp/warp_gen_$$"
    mkdir -p "$work_dir" && cd "$work_dir"
    
    # 自动执行注册并提取核心数据 (私钥、IPv4、reserved 掩码)
    "$wgcf_bin" register --accept-tos >/dev/null 2>&1
    "$wgcf_bin" generate >/dev/null 2>&1
    
    local private_key=$(grep "private_key" wgcf-account.toml | awk -F"'" '{print $2}')
    local client_id=$(grep "device_id" wgcf-account.toml | awk -F"'" '{print $2}')
    local ipv4=$(grep "^Address" wgcf-profile.conf | grep -oE "172\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1)
    
    # 核心黑科技：计算 reserved 字段以通过 Cloudflare 针对非官方客户端的封锁
    local hex_id=$(echo -n "$client_id" | base64 -d | od -An -v -tx1 | tr -d ' \n')
    local r1=$((16#${hex_id:0:2}))
    local r2=$((16#${hex_id:2:2}))
    local r3=$((16#${hex_id:4:2}))
    
    echo -e "\n${GREEN}===== Xray Outbound JSON (WireGuard) =====${NC}"
    cat <<EOF
{
  "tag": "warp",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${private_key}",
    "address": ["${ipv4}/32"],
    "peers": [{
        "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "endpoint": "162.159.192.1:2408"
    }],
    "reserved": [${r1}, ${r2}, ${r3}]
  }
}
EOF
    echo -e "${GREEN}===========================================${NC}\n"
    cd /tmp && rm -rf "$work_dir" "$wgcf_bin"
}
