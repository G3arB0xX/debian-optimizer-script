#!/bin/bash
# =========================================================
# 安全加固模块 (基于 nftables 目录级管理)
# =========================================================

# ----------------- SSH 安全审计 -----------------
# ----------------- SSH 安全审计与深度加固 -----------------
# 按照 VIBE 指令，实现：非 root 用户创建、Key 登录强制化、高位端口随机化
check_ssh_security() {
    info "正在执行系统级 SSH 零信任安全加固..."

    # 1. 检测/创建非 root 用户
    local target_user
    target_user=$(detect_or_create_user)

    # 2. 配置 SSH 密钥登录
    setup_user_ssh_key "$target_user"

    # 3. 随机高位端口与防火墙规则
    local old_port
    old_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | head -n 1 || echo 22)
    local new_port=$((RANDOM % 25535 + 40000))
    
    # 记录原始配置用于回退
    local socket_override="/etc/systemd/system/ssh.socket.d/override.conf"
    local has_socket=false
    if systemctl is-active --quiet ssh.socket; then
        has_socket=true
    fi

    apply_ssh_port "$new_port" "$has_socket"
    add_fw_rule "$new_port" "tcp" "SSH_Hardened_Port"

    # 4. 验证连通性
    echo -e "\n${YELLOW}⚠️  关键步骤：请勿关闭当前终端！${NC}"
    echo -e "SSH 已切换至端口: ${GREEN}$new_port${NC}"
    echo -e "请在您的本地机器开启一个【新窗口】，尝试使用以下命令登录："
    echo -e "${CYAN}ssh -p $new_port $target_user@$(curl -s4 ifconfig.me || echo "您的服务器IP")${NC}\n"

    local confirmed=false
    read -p "您是否已成功通过新端口登录？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        confirmed=true
    else
        warn "验证未通过，正在回滚配置..."
        rollback_ssh_changes "$old_port" "$has_socket" "$new_port"
        return 1
    fi

    # 5. 终极加固：禁止 Root、禁止密码、锁定 Root
    if [[ "$confirmed" == "true" ]]; then
        lockdown_ssh_system
        info "✅ SSH 安全加固任务圆满完成。"
    fi
}

detect_or_create_user() {
    # 查找 UID >= 1000 的普通用户 (排除 nobody)
    local users=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd)
    
    if [[ -n "$users" ]]; then
        info "检测到现有普通用户: $(echo $users | tr '\n' ' ')"
        local selected_user=$(echo $users | awk '{print $1}')
        read -p "是否使用现有用户 '$selected_user' 进行加固？(y/n): " use_existing
        if [[ "$use_existing" == "y" || "$use_existing" == "Y" ]]; then
            echo "$selected_user"
            return
        fi
    fi

    # 创建新用户
    local username
    while true; do
        read -p "请输入要创建的新用户名: " username
        if [[ "$username" =~ ^[a-z][-a-z0-9]*$ ]]; then
            if id "$username" &>/dev/null; then
                err "用户已存在，请换一个名字。"
            else
                break
            fi
        else
            err "用户名格式不合法 (仅支持小写字母和数字，以字母开头)。"
        fi
    done

    # 交互式设置密码
    info "请为用户 $username 设置密码 (输入时不可见):"
    useradd -m -s /bin/bash "$username"
    passwd "$username"

    # 赋予 sudo 权限
    if grep -q "^sudo:" /etc/group; then
        usermod -aG sudo "$username"
    elif grep -q "^wheel:" /etc/group; then
        usermod -aG wheel "$username"
    fi
    
    info "用户 $username 创建成功并已加入 sudo 组。"
    echo "$username"
}

setup_user_ssh_key() {
    local user=$1
    local user_home=$(eval echo ~$user)
    local ssh_dir="$user_home/.ssh"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    echo -e "\n${YELLOW}配置 SSH 密钥登录 (Ed25519)${NC}"
    echo "请在您的本地电脑运行: ${CYAN}ssh-keygen -t ed25519${NC}"
    echo "然后将生成的公钥 (.pub 文件内容) 粘贴到下方："
    
    local pub_key=""
    while [[ -z "$pub_key" ]]; do
        read -p "粘贴公钥: " pub_key
        if [[ ! "$pub_key" =~ ssh-ed25519 ]]; then
            warn "检测到非 Ed25519 格式密钥，为了安全建议使用 ed25519。请确认或重新粘贴。"
        fi
    done

    echo "$pub_key" > "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    chown -R "$user:$user" "$ssh_dir"
    info "密钥已成功注入 $user 账户。"
}

apply_ssh_port() {
    local port=$1
    local has_socket=$2

    if [[ "$has_socket" == "true" ]]; then
        info "检测到系统使用 ssh.socket，正在应用 Systemd Override..."
        mkdir -p /etc/systemd/system/ssh.socket.d/
        cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=$port
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket
    else
        info "修改 /etc/ssh/sshd_config 端口..."
        sed -i "s/^#\?Port [0-9]*/Port $port/" /etc/ssh/sshd_config
        systemctl restart ssh
    fi
}

rollback_ssh_changes() {
    local old_port=$1
    local has_socket=$2
    local new_port=$3

    info "执行配置回滚..."
    if [[ "$has_socket" == "true" ]]; then
        rm -f /etc/systemd/system/ssh.socket.d/override.conf
        systemctl daemon-reload
        systemctl restart ssh.socket
    else
        sed -i "s/^Port $new_port/Port $old_port/" /etc/ssh/sshd_config
        systemctl restart ssh
    fi

    # 清理防火墙规则
    rm -f "${NFT_CONF_DIR}/SSH_Hardened_Port.nft"
    nft -f /etc/nftables.conf 2>/dev/null || true
    
    warn "配置已回滚至端口 $old_port。请检查网络环境后重试。"
}

lockdown_ssh_system() {
    info "执行最终安全加固 (禁止密码/Root登录)..."

    # 修改 sshd_config
    local config="/etc/ssh/sshd_config"
    set_conf_value "$config" "PermitRootLogin" "no" " "
    set_conf_value "$config" "PasswordAuthentication" "no" " "
    set_conf_value "$config" "PubkeyAuthentication" "yes" " "
    
    # 针对 Debian 12 的额外加固：确保 ssh.service 也重启以应用配置
    systemctl restart ssh

    # 锁定 root 密码
    info "锁定 Root 账户密码..."
    passwd -l root
    
    # 持久化标记
    sed -i '/SSH_HARDENED/d' "$INIT_FLAG" 2>/dev/null
    echo "SSH_HARDENED=\"true\"" >> "$INIT_FLAG"
}

# ----------------- 现代防火墙接口 (nftables) -----------------
# 采用目录级管理，确保规则的原子化与可撤销性
NFT_CONF_DIR="/etc/nftables/debopti.d"

add_fw_rule() {
    local port=$1
    local proto=$2
    local comment=$3
    local rule_file="${NFT_CONF_DIR}/${comment// /_}.nft"

    info "下发 nftables 规则: $port/$proto ($comment)..."

    # 确保管理目录存在
    if [[ ! -d "$NFT_CONF_DIR" ]]; then
        setup_security
    fi

    # 构造原子规则文件
    # 使用 inet 族以同时支持 IPv4 和 IPv6
    cat > "$rule_file" << EOF
table inet filter {
    chain input {
        ${proto//\// } dport { ${port//:/ - } } accept comment "$comment"
    }
}
EOF
    # 语法释义：
    # ${proto//\// }：将 tcp/udp 转换为 tcp udp，适配 nft 语法
    # ${port//:/ - }：将 11010:11015 转换为 11010 - 11015，适配 nft 范围语法

    # 执行原子加载，防止语法错误导致防火墙整体崩溃
    if ! nft -f "$rule_file" 2>/dev/null; then
        warn "规则语法校验失败，尝试回退并应用..."
        rm -f "$rule_file"
        return 1
    fi
    
    # 确保主配置文件包含此目录
    if ! grep -q "include \"$NFT_CONF_DIR/\*.nft\"" /etc/nftables.conf; then
        echo "include \"$NFT_CONF_DIR/*.nft\"" >> /etc/nftables.conf
    fi
    info "✅ 规则已持久化。"
}

setup_security() {
    info "初始化系统级安全防御引擎 (nftables + Fail2ban)..."

    # 1. 彻底移除 UFW 以破除规则冲突死锁
    if command -v ufw >/dev/null 2>&1; then
        warn "清理旧版 UFW 引擎..."
        ufw disable >/dev/null 2>&1 || true
        apt-get purge -yq ufw >/dev/null 2>&1
    fi

    # 2. 安装并启用基础套件
    safe_apt_install nftables fail2ban || return 1

    # 3. 构建规范化 /etc/nftables.conf
    # 采用标准 hook 架构，优先处理 established 连接以最大化性能
    mkdir -p "$NFT_CONF_DIR"
    cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # 允许环回接口数据流
        iifname "lo" accept

        # 核心：允许已建立和关联的报文 (保证 TCP 握手响应)
        ct state established,related accept

        # 丢弃所有无效状态报文 (防范扫描与畸形包攻击)
        ct state invalid drop

        # 允许 ICMP/ICMPv6 (Ping) 并进行限速，防止 Ping 洪水攻击
        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate 5/second accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# 引入动态规则目录
include "$NFT_CONF_DIR/*.nft"
EOF

    # 4. 获取当前 SSH 端口并生成首条持久化规则
    local ssh_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | head -n 1 || true)
    ssh_port=${ssh_port:-22}
    add_fw_rule "$ssh_port" "tcp" "SSH_Listen_Port"

    # 5. 激活服务
    systemctl enable --now nftables
    nft -f /etc/nftables.conf || die "nftables 引擎启动异常，请检查系统日志。"

    # 6. 配置 Fail2ban 联动 nftables
    # 使用 nftables-multiport 动作直接在内核层阻断黑客 IP
    info "同步配置 Fail2ban 联动策略..."
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
findtime = 600
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban
    info "✅ 全局安全引擎已就绪。"
}
