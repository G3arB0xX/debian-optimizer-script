#!/bin/bash
# =========================================================
# 系统级底层调优模块 (内核、协议栈与系统限制)
# =========================================================

# ----------------- 基础环境优化 -----------------
setup_base() {
    info "正在优化 APT 镜像源与系统基础组件..."
    
    # 自动备份官方源
    [[ ! -f /etc/apt/sources.list.bak ]] && cp /etc/apt/sources.list /etc/apt/sources.list.bak
    
    export DEBIAN_FRONTEND=noninteractive

    # 破除“鸡生蛋”死锁：预装 CA 证书以支持后续的 HTTPS 请求
    if ! dpkg -s ca-certificates >/dev/null 2>&1; then
        info "预装 CA 证书以兼容 HTTPS 源..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq ca-certificates >/dev/null 2>&1
    fi

    # 国内环境自适应切换到 TUNA 镜像站，提升包管理器拉取速度
    if [[ "$IS_CN_REGION" == "true" ]]; then
        if grep -qE "deb\.debian\.org|security\.debian\.org" /etc/apt/sources.list; then
            info "切换 APT 源为清华大学 TUNA 镜像站..."
            sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
            sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
        fi
    fi

    # 强制升级源协议到更安全的 HTTPS
    sed -i 's|http://|https://|g' /etc/apt/sources.list

    info "同步包缓存并补齐基础系统工具..."
    apt-get update -yq || warn "APT 缓存刷新异常，请检查网络。"
    # 补齐运维常用工具，确保脚本后续逻辑不因缺少二进制而中断
    apt-get install -yq curl wget gnupg lsb-release procps unzip tar openssl git logrotate
    apt-get upgrade -yq && apt-get autoremove -yq
}

# ----------------- 内核自适应更换 -----------------
setup_kernel() {
    info "检查系统内核架构..."
    local current_kernel=$(uname -r)
    
    # Cloud 内核针对 KVM/Xen 环境去除了物理驱动，启动更快，内存占用更低
    if echo "$current_kernel" | grep -q "cloud"; then
        info "当前已是 Cloud 专用内核，无需更换。"
    else
        echo -e "${YELLOW}检测到当前为物理机内核，建议更换为 Cloud 内核以降低内存开销。${NC}"
        read -p "是否更换为 Cloud 内核并自动清理旧内核？[y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            apt-get install -yq linux-image-cloud-amd64 linux-headers-cloud-amd64 || die "内核下载失败！"
            update-grub
            # 自动清理除了当前和 Cloud 以外的所有冗余内核，释放 /boot 空间
            local old_kernels=$(dpkg -l | grep linux-image | awk '{print $2}' | grep -v "cloud" | grep -v "$current_kernel" || true)
            [[ -n "$old_kernels" ]] && apt-get purge -yq $old_kernels
            info "✅ 内核更换成功，重启后生效。"
        fi
    fi
}

# ----------------- TCP 协议栈调优 (BBR) -----------------
setup_sysctl() {
    info "下发建站级 Sysctl 协议栈优化参数..."
    local conf_file="/etc/sysctl.d/99-debopti-optimize.conf"
    
    cat > "$conf_file" << 'EOF'
# 解除文件句柄限制 (系统级)
fs.file-max = 1048576

# 核心：开启 BBR 拥塞控制算法 (极大提升高延迟下的传输速度)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 连接回收与复用优化 (针对反代场景)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 50000

# 缓冲区扩容：提升单线程吞吐能力
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 加强防 SYN 洪水攻击能力
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# 开启 TCP Fast Open 减少握手往返
net.ipv4.tcp_fastopen = 3
EOF
    sysctl --system > /dev/null 2>&1
    info "✅ TCP 协议栈优化已激活。"
}

# ----------------- 系统资源限制优化 -----------------
setup_limits() {
    info "解除系统用户级最大文件句柄限制 (nofile)..."
    local limits_conf="/etc/security/limits.d/99-debopti-nofile.conf"
    
    cat > "$limits_conf" << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    # 同时同步 Systemd 的全局限制，确保通过 systemctl 启动的服务也受惠
    set_conf_value "/etc/systemd/system.conf" "DefaultLimitNOFILE" "1048576"
    set_conf_value "/etc/systemd/user.conf" "DefaultLimitNOFILE" "1048576"
    info "✅ 文件句柄限制已解除 (需重新登录生效)。"
}

# ----------------- 内存与虚拟内存管理 -----------------
setup_memory() {
    info "正在配置内存优化策略 (ZRAM & Swap)..."
    local mem_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
    
    # ZRAM：使用 CPU 计算换取内存空间，适合小内存 VPS (推荐)
    read -p "是否启用 ZRAM 内存压缩？(建议 2G 以下内存开启) [y/N]: " zram_choice
    if [[ "$zram_choice" =~ ^[Yy]$ ]]; then
        apt-get install -yq zram-tools > /dev/null
        # 配置 50% 内存作为 ZRAM，使用高性能 zstd 算法
        cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
        systemctl restart zramswap
        info "✅ ZRAM 已启动。"
    fi
    
    # 物理 Swap 文件兜底
    read -p "是否创建物理 Swap 交换文件？[y/N]: " swap_choice
    if [[ "$swap_choice" =~ ^[Yy]$ ]]; then
        if grep -q "/swapfile" /proc/swaps; then
            info "Swap 文件已存在，跳过。"
        else
            local swap_size=$(( mem_mb * 2 ))
            info "正在创建 ${swap_size}MB Swap 文件..."
            fallocate -l ${swap_size}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${swap_size} status=progress
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            if swapon /swapfile 2>/dev/null; then
                [[ ! $(grep "/swapfile" /etc/fstab) ]] && echo "/swapfile none swap sw 0 0" >> /etc/fstab
                info "✅ Swap 挂载成功。"
            else
                warn "环境不支持挂载 Swap (常见于部分 LXC 容器)，已清理。"
                rm -f /swapfile
            fi
        fi
    fi
}

# ----------------- 日志轮转与清理 -----------------
setup_logrotate() {
    info "配置 Logrotate 日志按天轮转，防止磁盘撑爆..."
    # 强制将每周轮换改为每日，保留 7 天副本并开启压缩
    set_conf_value "/etc/logrotate.conf" "daily" "" ""
    set_conf_value "/etc/logrotate.conf" "rotate" "7"
    set_conf_value "/etc/logrotate.conf" "compress" "" ""
    info "✅ 日志轮转配置更新。"
}

# ----------------- 内存极限瘦身 (Low Memory Optimization) -----------------
# 针对 1G 及以下内存 VPS 的深度优化，削减冗余进程与日志开销
setup_low_memory_optimization() {
    info "正在执行系统级极限瘦身优化 (针对低配 VPS)..."

    # 1. 削减 TTY 终端数量 (保留 2 个以防万一)
    info "削减冗余 TTY 终端进程..."
    if [[ -f /etc/systemd/logind.conf ]]; then
        set_conf_value "/etc/systemd/logind.conf" "NAutoVTs" "2"
        set_conf_value "/etc/systemd/logind.conf" "ReserveVT" "2"
        systemctl restart systemd-logind >/dev/null 2>&1 || true
    fi

    # 2. 移除重复的日志系统 (rsyslog)
    if dpkg -s rsyslog >/dev/null 2>&1; then
        info "检测到 rsyslog，正在卸载以释放内存 (改由 journald 接管)..."
        apt-get purge -yq rsyslog >/dev/null 2>&1
    fi

    # 3. 限制 Systemd Journal 日志的体量
    info "限制 Journald 日志内存与磁盘配额..."
    local journal_conf="/etc/systemd/journald.conf"
    if [[ -f "$journal_conf" ]]; then
        set_conf_value "$journal_conf" "SystemMaxUse" "200M"
        set_conf_value "$journal_conf" "RuntimeMaxUse" "10M"
        systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi

    # 4. 裁剪系统冗余服务 (可选)
    echo -e "${YELLOW}是否屏蔽系统冗余服务 (ModemManager, Avahi, Bluetooth 等)？[y/N]: ${NC}"
    read -p "" service_choice
    if [[ "$service_choice" =~ ^[Yy]$ ]]; then
        info "正在屏蔽冗余服务..."
        local services=("ModemManager" "avahi-daemon" "bluetooth" "cups" "pnmos")
        for svc in "${services[@]}"; do
            if systemctl list-unit-files | grep -q "^${svc}.service"; then
                systemctl stop "$svc" >/dev/null 2>&1 || true
                systemctl mask "$svc" >/dev/null 2>&1 || true
                info "已屏蔽服务: $svc"
            fi
        done
    fi

    info "✅ 极限瘦身优化已完成。"
}

# ----------------- 时区与时间同步 -----------------
setup_timezone() {
    info "校准系统时区与时间同步..."
    # 强制设置为 Asia/Shanghai，确保日志时间线一致
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
    # 部署更现代的 chrony 代替 ntp
    apt-get install -yq chrony > /dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 || true
    info "✅ 时区已设为 Asia/Shanghai。"
}

# ----------------- 综合优化入口 -----------------
run_base_optimization() {
    global_netcheck
    setup_base
    setup_kernel
    setup_sysctl
    setup_limits
    setup_security # 由 security.sh 提供
    setup_memory
    setup_low_memory_optimization
    setup_logrotate
    setup_timezone
    
    # 写入完成标记
    sed -i '/BASE_OPTIMIZED/d' "$INIT_FLAG" 2>/dev/null
    echo "BASE_OPTIMIZED=\"true\"" >> "$INIT_FLAG"
    info "🔥 基础系统级优化全部完成！"
}

# ----------------- 路由转发管理 -----------------
get_ip_forward_status() {
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
        echo -e "${GREEN}[已开启]${NC}"
    else
        echo -e "${YELLOW}[已关闭]${NC}"
    fi
}

toggle_ip_forwarding() {
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
        info "关闭系统 IP 转发功能..."
        rm -f /etc/sysctl.d/99-debopti-forwarding.conf
        sysctl -w net.ipv4.ip_forward=0 >/dev/null || true
        info "✅ 已切换为纯建站模式 (Forward Off)。"
    else
        info "开启系统 IP 转发功能..."
        cat > /etc/sysctl.d/99-debopti-forwarding.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
        sysctl --system > /dev/null 2>&1
        info "✅ 已切换为组网/代理模式 (Forward On)。"
    fi
    sleep 1
}
