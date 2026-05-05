#!/bin/bash
# =========================================================
# GoLang 环境与自编译生态模块 (Caddy & DERPer)
# =========================================================

# ----------------- Go 环境部署 -----------------
install_go() {
    info "正在安装/修复 Go 运行时环境..."
    local domain="go.dev"
    [[ "$IS_CN_REGION" == "true" ]] && domain="golang.google.cn"
    
    # 动态抓取最新版本号
    local latest_ver=$(curl -s --connect-timeout 5 "https://${domain}/VERSION?m=text" | head -n 1)
    latest_ver=${latest_ver:-go1.22.1}
    
    info "正在拉取 $latest_ver 官方二进制包..."
    local tmp_go="/tmp/go.tar.gz"
    if ! curl -# -L --connect-timeout 5 -o "$tmp_go" "https://${domain}/dl/${latest_ver}.linux-amd64.tar.gz"; then
        err "下载失败，请检查网络。"
        return 1
    fi
    
    # 彻底清理并安装
    rm -rf /usr/local/go && tar -C /usr/local -xzf "$tmp_go"
    export PATH=$PATH:/usr/local/go/bin
    
    # 国内环境注入 GOPROXY 代理，确保后续编译不卡死 (七牛云代理)
    if [[ "$IS_CN_REGION" == "true" ]]; then
        export GOPROXY=https://goproxy.cn,direct
        update_fish_env "GOPROXY" "https://goproxy.cn,direct"
    fi
    
    # 同步至 Fish 环境
    update_fish_path "/usr/local/go/bin"
    update_fish_path "\$HOME/go/bin"
    
    info "✅ Go 语言环境就绪。"
}

uninstall_go() {
    rm -rf /usr/local/go "$HOME/go" /tmp/go.tar.gz
    
    # 清理 Fish 环境
    remove_fish_path "/usr/local/go/bin"
    remove_fish_path "\$HOME/go/bin"
    remove_fish_env "GOPROXY"
    
    info "✅ Go 已从系统移除。"
}

# ----------------- 自定义 Caddy (带 layer4/naive 插件) -----------------
install_caddy() {
    info "开始自编译构建 Caddy (集成 layer4/naiveproxy/cloudflare 插件)..."
    
    # 环境预检
    [[ ! $(command -v go) ]] && install_go
    [[ "$IS_CN_REGION" == "true" ]] && export GOPROXY=https://goproxy.cn,direct
    
    # 部署 xcaddy 编译工具
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    export PATH=$PATH:~/go/bin
    
    # 开启编译沙盒
    local build_dir="/tmp/caddy_build_$$"
    mkdir -p "$build_dir" && cd "$build_dir"
    
    info "正在执行 xcaddy 多插件并行编译 (此步消耗 CPU/内存较大，请耐心等待)..."
    xcaddy build \
        --with github.com/mholt/caddy-l4 \
        --with github.com/caddy-dns/cloudflare \
        --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive || return 1
        
    # 规范化部署
    systemctl stop caddy >/dev/null 2>&1
    mv ./caddy /usr/bin/caddy && chmod +x /usr/bin/caddy
    # 黑科技：利用 Linux Capabilities 允许 Caddy 绑定 80/443 而无需 root 权限运行
    setcap cap_net_bind_service=+ep /usr/bin/caddy
    
    # 初始化标准运行用户与目录
    if [[ ! -d "/etc/caddy" ]]; then
        create_system_user "caddy"
        # 补齐 caddy 组 (部分系统 useradd 不会自动创建同名组)
        groupadd --system caddy 2>/dev/null || true
        usermod -aG caddy caddy
        
        mkdir -p /etc/caddy /etc/ssl/caddy /usr/share/caddy
        chown -R caddy:root /etc/caddy /etc/ssl/caddy
        echo "<h1>Caddy Standard Landing Page</h1>" > /usr/share/caddy/index.html
        echo ":80 { root * /usr/share/caddy; file_server }" > /etc/caddy/Caddyfile
    fi

    # 部署官方推荐的 Systemd 单元
    deploy_systemd_service "caddy" << EOF
[Unit]
Description=Caddy Web Server
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# --- Security Sandboxing ---
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# 允许 Caddy 写入其证书存储目录
ReadWritePaths=/var/lib/caddy /etc/ssl/caddy
# ---------------------------

[Install]
WantedBy=multi-user.target
EOF
    
    # 防火墙自动化下发 (nftables)
    add_fw_rule "80,443" "tcp/udp" "Caddy_Web"
    
    info "✅ Caddy (插件版) 部署成功！"
    cd /tmp && rm -rf "$build_dir"
}

uninstall_caddy() {
    info "正在卸载 Caddy 及其所有配置..."
    systemctl stop caddy >/dev/null 2>&1
    systemctl disable caddy >/dev/null 2>&1
    rm -f /etc/systemd/system/caddy.service /usr/bin/caddy
    rm -rf /etc/caddy /usr/share/caddy /etc/ssl/caddy
    
    [[ -f "/etc/nftables/debopti.d/Caddy_Web.nft" ]] && rm -f "/etc/nftables/debopti.d/Caddy_Web.nft" && nft -f /etc/nftables.conf
    id -u caddy >/dev/null 2>&1 && userdel caddy
    info "✅ Caddy 已移除。"
}

# ----------------- Tailscale DERPer (隐身防拨测补丁) -----------------
install_derper() {
    info "开始自编译构建 Tailscale DERPer (注入隐身防拨测补丁)..."
    
    # 环境预检
    [[ ! $(command -v go) ]] && install_go
    [[ "$IS_CN_REGION" == "true" ]] && export GOPROXY=https://goproxy.cn,direct
    
    local ts_ver="v1.94.2" # 锁定版本以确保补丁 sed 偏移量正确
    local build_dir="/tmp/derper_build_$$"
    mkdir -p "$build_dir"
    
    # 拉取源码
    git_clone_with_fallback "$build_dir/tailscale" "https://github.com/tailscale/tailscale.git" -b "$ts_ver" --depth 1 || return 1
    cd "$build_dir/tailscale/cmd/derper" || return 1
    
    info "正在注入源码级隐身补丁 (掐断 GFW/网络扫描器的主动探测)..."
    
    # 补丁 1: 注入底层连接掐断函数
    sed -i '/func main()/i func closeConn(w http.ResponseWriter) { if hj, ok := w.(http.Hijacker); ok { if conn, _, err := hj.Hijack(); err == nil { conn.Close() } } }' derper.go
    # 补丁 2: 严格校验 /generate_204 路由，仅放行 Go 官方心跳客户端
    sed -i 's/mux.HandleFunc("\/generate_204", derphttp.ServeNoContent)/mux.HandleFunc("\/generate_204", func(w http.ResponseWriter, r *http.Request) { if r.UserAgent() == "Go-http-client\/1.1" { derphttp.ServeNoContent(w, r); return }; closeConn(w) })/g' derper.go
    # 补丁 3: 掐断根路径 / 的文本回显
    sed -i 's/fmt.Fprintf(w, "DERP\\n")/closeConn(w)/g' derper.go
    
    info "执行编译构建..."
    go build -v -o /usr/bin/derper || return 1
    
    # 生成自签证书与服务单元
    local cert_dir="/opt/derper/certs"
    mkdir -p "$cert_dir"
    local ip=$(curl -s4 --connect-timeout 3 ifconfig.me || echo "127.0.0.1")
    openssl req -x509 -newkey ed25519 -days 3650 -nodes -keyout "${cert_dir}/${ip}.key" -out "${cert_dir}/${ip}.crt" -subj "/CN=${ip}" >/dev/null 2>&1
    
    # 初始化标准运行用户
    create_system_user "derper"
    chown -R derper:derper /opt/derper

    deploy_systemd_service "derper" << EOF
[Unit]
Description=Tailscale DERP Relay Server (Stealth)
After=network.target

[Service]
Type=simple
User=derper
Group=derper
ExecStart=/usr/bin/derper -a :34781 -hostname ${ip} -certmode manual -certdir ${cert_dir} -stun -http-port -1 -verify-clients=false
Restart=on-failure
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
    
    # 防火墙自动化 (nftables)
    add_fw_rule "34781" "tcp" "DERP_Relay"
    add_fw_rule "3478" "udp" "DERP_STUN"
    
    info "✅ DERPer 隐身版部署完成！端口: TCP 34781 | UDP 3478"
    cd /tmp && rm -rf "$build_dir"
}

uninstall_derper() {
    info "正在卸载 DERPer..."
    systemctl stop derper >/dev/null 2>&1
    systemctl disable derper >/dev/null 2>&1
    rm -f /etc/systemd/system/derper.service /usr/bin/derper
    rm -rf /opt/derper
    id -u derper >/dev/null 2>&1 && userdel derper
    
    [[ -f "/etc/nftables/debopti.d/DERP_Relay.nft" ]] && rm -f "/etc/nftables/debopti.d/DERP_Relay.nft"
    [[ -f "/etc/nftables/debopti.d/DERP_STUN.nft" ]] && rm -f "/etc/nftables/debopti.d/DERP_STUN.nft"
    nft -f /etc/nftables.conf
    
    info "✅ DERPer 已移除。"
}
