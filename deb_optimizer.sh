#!/bin/bash
set -euo pipefail
# =========================================================
# Debian 系统性能调优与服务自动化部署面板
# 适用系统: Debian 11 / Debian 12 (amd64)
# 特性: 幂等性设计、防重复执行、详尽系统级注释、可选组件自动构建
# =========================================================


# ----------------- 颜色与日志定义 -----------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()  { echo -e "${RED}[ERROR] $1${NC}"; }
die()  { echo -e "${RED}[FATAL] $1${NC}"; exit 1; } # 致命错误，退出脚本

# 暂停函数，等待用户按任意键继续
pause() {
    echo -e "\n${YELLOW}>>> 操作执行完毕。请阅读上方日志，按任意键返回菜单...${NC}"
    # -n 1: 接受1个字符即刻返回; -s: 静默不回显输入的字符; -r: 允许转义
    read -n 1 -s -r -p ""
}

# 用于记录脚本是否是第一次完整运行，实现基础优化防重复执行
INIT_FLAG="/etc/servopti.conf"
# 如果配置文件存在，则读取上一次保存的环境变量
if [[ -f "$INIT_FLAG" ]]; then
    source "$INIT_FLAG"
fi

# 防止首次运行时触发 set -u 的 unbound variable
IS_CN_REGION="${IS_CN_REGION:-}"
BASE_OPTIMIZED="${BASE_OPTIMIZED:-}"

# 全局注入 Go 环境变量，确保检测函数能找到 go 和 xcaddy
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

if [[ $EUID -ne 0 ]]; then
   die "此脚本必须以 root 权限运行，请使用 sudo -i 切换后重试。"
fi

# =========================================================
# 全局网络环境检测与自举
# =========================================================
global_netcheck() {
    # 幂等检测：如果已经从配置文件加载了地区，则直接跳过耗时的网络探测
    if [[ -n "{{$IS_CN_REGION:-}}" ]]; then
        return
    fi

    # 确保系统有 curl 命令用于网络请求
    if ! command -v curl >/dev/null 2>&1; then
        info "未检测到 curl，准备基础依赖..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq curl >/dev/null 2>&1
    fi

    if [[ -z "$IS_CN_REGION" ]]; then
        info "侦测全局网络归属地 (多节点容灾探测)..."
        IS_CN_REGION="false" # 默认设为海外
        
        # 定义通用的浏览器 User-Agent，绕过基础的反爬虫拦截
        UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

        # 探测节点 1: 国际节点 ipinfo.io，带上伪装 UA，返回国家简码，
        if [[ "$(curl -sL --connect-timeout 3 -A "$UA" https://ipinfo.io/country 2>/dev/null)" == *"CN"* ]]; then
            IS_CN_REGION="true"
        # 探测节点 2: 优先使用国内极速节点 cip.cc
        elif curl -sL --connect-timeout 3 -A "$UA" http://myip.ipip.net 2>/dev/null | grep -q "中国"; then
            IS_CN_REGION="true"
        # 探测节点 3: cip.cc 备用
        elif curl -sL --connect-timeout 3 -A "$UA" https://cip.cc 2>/dev/null | grep -q "中国"; then
            IS_CN_REGION="true"
        # 探测节点 4: ip.sb 兜底
        elif curl -sL --connect-timeout 3 -A "$UA" https://api.ip.sb/geoip 2>/dev/null | grep -i -q "China"; then
            IS_CN_REGION="true"
        fi

        if [[ "$IS_CN_REGION" == "true" ]]; then
            warn "检测到服务器位于中国大陆，将全局启用 APT 与 GitHub 镜像加速。"
        else
            info "服务器位于海外 (或探测超时)，将优先使用官方直连。"
        fi
    fi

    #持久化写入：将结果保存到文件，防重复并实现共享文件
    touch "$INIT_FLAG"
    sed -i '/IS_CN_REGION/d' "$INIT_FLAG" 2>/dev/null # 删掉旧记录防堆叠
    echo "IS_CN_REGION=\"$IS_CN_REGION\"" >> "$INIT_FLAG"
}

# =========================================================
# 高可用下载模块 (混合模式镜像池自动轮询 - 2026.3 优化版)
# =========================================================
download_with_fallback() {
    local target_file=$1
    local original_url=$2
    
    # 严格超时控制: 5秒握手失败或 120秒未下完直接打断
    local curl_opts="-fsSL --connect-timeout 5 --max-time 120"

    # 如果是国内机器且目标是 GitHub，启用混合镜像池自动轮询
    if [[ "$IS_CN_REGION" == "true" ]] && [[ "$original_url" =~ github\.com|githubusercontent\.com ]]; then
        info "检测到大陆网络环境，启动镜像节点轮询下载..."
        
        # 定义混合模式镜像池 (语法规则：模式|配置参数)
        # 优先级：CDN加速 (最快) > 高优全能代理站 > 教育网直连 > 备用代理 > 备用直连
        local mirrors=(
            "jsdelivr|"                                     # [特优] 专为 raw 文件解析至 jsdelivr CDN
            "prefix|https://ghp.ci"                         # [极稳] 当前开发者社区公认最稳的文件代理
            "prefix|https://ghfast.top"                     # [极速] 高速全能加速站
            "replace|github.com|hub.nuaa.cf"                # [高速] 南航教育网镜像 (Release/源码极速)
            "replace|raw.githubusercontent.com|raw.nuaa.cf" # [高速] 南航教育网 raw 节点
            "replace|github.com|kkgithub.com"               # [稳定] 老牌 GitHub 网页直连镜像
            "replace|raw.githubusercontent.com|raw.kkgithub.com"
            "prefix|https://ghproxy.net"                    # [备用] 原老牌 ghproxy 的稳定变体
            "replace|github.com|bgithub.xyz"                # [备用] 备用直连域名
            "prefix|https://moeyy.cn/gh-proxy"              # [备用] 个人高防优质节点
        )
        
        local success="false"
        for mirror_conf in "${mirrors[@]}"; do
            # 解析当前镜像站的运行模式
            local mode="${mirror_conf%%|*}"
            local rest="${mirror_conf#*|}"
            local download_url=""
            
            if [[ "$mode" == "jsdelivr" ]]; then
                # jsdelivr 模式：利用正则提取 raw 链接的 user, repo, branch, file 并重组
                # 仅对 raw.githubusercontent.com 生效
                if [[ "$original_url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$ ]]; then
                    local user="${BASH_REMATCH[1]}"
                    local repo="${BASH_REMATCH[2]}"
                    local branch="${BASH_REMATCH[3]}"
                    local file_path="${BASH_REMATCH[4]}"
                    # 组装全球顶级 CDN 链接 (注意：jsDelivr 有 50MB 大小限制，但对普通脚本完美)
                    download_url="https://cdn.jsdelivr.net/gh/${user}/${repo}@${branch}/${file_path}"
                else
                    # 如果不是 raw 文件 (比如 Release 安装包)，则跳过此模式
                    continue 
                fi

            elif [[ "$mode" == "prefix" ]]; then
                # 追加模式：直接拼接，代理站会自动处理
                download_url="${rest}/${original_url}"
                
            elif [[ "$mode" == "replace" ]]; then
                # 替换模式：提取目标与新域名
                local target_domain="${rest%%|*}"
                local replacement="${rest#*|}"
                
                # Bash 原生字符串替换：${字符串/查找/替换}
                download_url="${original_url/${target_domain}/${replacement}}"
                
                # 安全检查：如果 URL 没发生变化（说明该镜像不匹配当前域名类型），直接跳过
                if [[ "$download_url" == "$original_url" ]]; then
                    continue
                fi
            fi
            
            info "尝试连接镜像节点: $download_url"
            # 捕获 HTTP 状态码，防止代理站返回 502/404 但 curl 依然当做成功的情况
            if curl $curl_opts -o "$target_file" "$download_url" -w "%{http_code}" | grep -q "^20"; then
                success="true"
                info "下载成功: $target_file"
                break
            else
                warn "该节点响应超时、解析失败或触发限制，切换下一个节点..."
                rm -f "$target_file" # 清理可能残留的空文件或报错 HTML 页面
            fi
        done
        
        if [[ "$success" == "false" ]]; then
            err "所有国内备用镜像节点均已失效，下载彻底失败，请检查服务器网络。"
            return 1
        fi
        
    else
        # 海外机器或非 GitHub 链接的官方直连逻辑
        info "尝试优先官方直连下载: $original_url"
        if ! curl $curl_opts -o "$target_file" "$original_url"; then
            rm -f "$target_file"
            err "海外节点直连下载失败，请检查目标链接是否有效: $original_url"
            return 1
        fi
        info "下载成功: $target_file"
    fi
}

# =========================================================
# 高可用 Git Clone 模块 (镜像池轮询 + 防假死挂起 - 2026.3)
# =========================================================
git_clone_with_fallback() {
    local target_dir=$1
    local repo_url=$2
    shift 2
    local extra_args=("$@") # 接收额外参数，例如 -b v1.0 --depth 1

    # 防误删安全锁
    if [[ -z "$target_dir" || "$target_dir" == "/" || "$target_dir" == "/usr" || "$target_dir" == "/etc" ]]; then
        err "安全拦截：尝试操作受保护的系统目录 ($target_dir)！"
        return 1
    fi

    # 设置 Git 低速断开机制，防止镜像站半死不活导致 clone 永久挂起
    # 连续 10 秒传输速度低于 1000 bytes/s 则自动掐断
    export GIT_HTTP_LOW_SPEED_LIMIT=1000
    export GIT_HTTP_LOW_SPEED_TIME=10
    # 禁止 Git 弹窗询问密码（防止私有仓库或镜像站错误要求鉴权导致卡死）
    export GIT_TERMINAL_PROMPT=0

    if [[ "$IS_CN_REGION" == "true" ]] && [[ "$repo_url" =~ github\.com ]]; then
        info "检测到大陆网络环境，智能配置底层网络并启动 Git 镜像轮询..."
        
        # 强制降级到 HTTP/1.1 并放大缓冲区，彻底解决 HTTP/2 framing layer 断流问题
        git config --global http.version HTTP/1.1
        git config --global http.postBuffer 524288000

        # 定义 Git 专用镜像池
        # 优先级：Git专用缓存站 > 教育网 > 高优代理 > 老牌直连
        local mirrors=(
            "replace|github.com|gitclone.com/github.com"  # [特优] 专为 git clone 优化的缓存站
            "replace|github.com|hub.nuaa.cf"              # [极速] 南航教育网直连
            "prefix|https://ghfast.top"                   # [极速] 高速全能加速站
            "prefix|https://ghp.ci"                       # [极稳] 开发者公认高稳代理
            "replace|github.com|kkgithub.com"             # [稳定] 老牌 GitHub 镜像
            "replace|github.com|bgithub.xyz"              # [备用] 备用直连域名
        )

        local success="false"
        for mirror_conf in "${mirrors[@]}"; do
            local mode="${mirror_conf%%|*}"
            local rest="${mirror_conf#*|}"
            local clone_url=""

            if [[ "$mode" == "prefix" ]]; then
                clone_url="${rest}/${repo_url}"
            elif [[ "$mode" == "replace" ]]; then
                local target_domain="${rest%%|*}"
                local replacement="${rest#*|}"
                clone_url="${repo_url/${target_domain}/${replacement}}"
            fi

            info "尝试从镜像站拉取: $clone_url"
            
            # 清理可能残留的失败目录
            rm -rf "$target_dir"
            
            # 执行克隆命令
            if git clone "${extra_args[@]}" "$clone_url" "$target_dir"; then
                success="true"
                info "✅ 源码拉取成功！"
                
                # 恢复原仓库的 remote origin，确保后续 git pull 或更新正常对接官方
                info "修复远程源指向官方 GitHub..."
                git -C "$target_dir" remote set-url origin "$repo_url"
                break
            else
                warn "该镜像节点连接超时或拉取失败，尝试切换下一个节点..."
            fi
        done

        if [[ "$success" == "false" ]]; then
            err "❌ 所有可用 Git 镜像节点均已失效，拉取失败！请检查服务器网络或稍后重试。"
            return 1
        fi

    else
        # 海外机器直接官方拉取
        info "海外环境，使用官方直连拉取: $repo_url"
        rm -rf "$target_dir"
        if ! git clone "${extra_args[@]}" "$repo_url" "$target_dir"; then
            err "❌ 官方直连拉取失败，请检查仓库链接有效性。"
            return 1
        fi
        info "✅ 源码拉取成功！"
    fi
}

# =========================================================
# 核心功能模块 (带状态检测与系统级注释)
# =========================================================

check_ssh_security() {
    info "检查 SSH 安全配置..."
    # 动态获取 SSH 监听端口和密码登录状态 (追加 || true 防止在 WSL/容器 环境中因找不到 sshd 而触发 set -e 闪退)
    SSH_PORT=$(ss -tlpn 2>/dev/null | awk '/sshd/ {print $4}' | rev | cut -d: -f1 | rev | head -n1 || true)
    PASS_AUTH=$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2}' || true)
    
    # 如果抓不到端口（比如 WSL 或 sshd 未启动），赋予安全的默认值
    if [[ -z "$SSH_PORT" ]]; then 
        SSH_PORT=22
        info "未检测到运行中的 sshd 进程 ，可能是 WSL 或本地容器环境。"
    else
        info "当前识别到的 SSH 端口: $SSH_PORT"
    fi
    
    # 只有当明确检测到端口为 22 且 允许密码登录 时，才进行安全拦截
    # (在 WSL 中 PASS_AUTH 会是空值，因此可以直接安全跳过此拦截)
    if [[ "$SSH_PORT" == "22" && "$PASS_AUTH" == "yes" ]]; then
        echo -e "${RED}严重安全漏洞警告：服务器使用 22 端口且允许密码登录，优化脚本停止运行。${NC}"
        echo -e "请先配置密钥登录、修改 SSH 端口并关闭密码登录后重试。"
        return 1
    fi
}

setup_base() {
    info "检查并优化 APT 源与基础组件..."

    # 1. 安全备份 (防呆保护：只在没有备份时备份)
    if [[ ! -f /etc/apt/sources.list.bak ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi

    export DEBIAN_FRONTEND=noninteractive

    # 2. 预先安装证书 (破除“鸡生蛋”死锁)
    if ! dpkg -s ca-certificates >/dev/null 2>&1; then
        info "预装 CA 证书以支持 HTTPS 源..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq ca-certificates >/dev/null 2>&1
    fi

    # 3. 国内环境判断与精准镜像替换
    if [[ "$IS_CN_REGION" == "true" ]]; then
        # 只要源里有官方源，统统替换
        if grep -qE "deb\.debian\.org|security\.debian\.org" /etc/apt/sources.list; then
            info "检测到国内环境且正在使用官方源，切换至清华大学 TUNA 镜像源..."
            sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
            sed -i 's/security.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
        else
            info "国内环境：检测到已配置为第三方镜像源，跳过替换。"
        fi
    else
        info "海外环境：保留默认官方源。"
    fi

    # 4. 全局强制 HTTPS 升级
    if grep -q "http://" /etc/apt/sources.list; then
        info "将 APT 源强制升级为更安全的 HTTPS 协议..."
        sed -i 's|http://|https://|g' /etc/apt/sources.list
    fi

    # 5. 正式更新与安装基础组件
    info "更新包缓存并安装基础组件..."
    apt-get update -yq || warn "APT 更新出现异常，请检查网络或源配置。"
    apt-get install -yq curl wget gnupg lsb-release procps unzip tar openssl git logrotate
    apt-get upgrade -yq && apt-get autoremove -yq
}

setup_kernel() {
    info "检查系统内核..."
    CURRENT_KERNEL=$(uname -r)
    
    # Cloud 内核针对 KVM/Xen 等虚拟化环境精简了不必要的物理硬件驱动，体积更小，网络性能更好
    if echo "$CURRENT_KERNEL" | grep -q "cloud"; then
        info "当前内核 ($CURRENT_KERNEL) 已是 cloud 版本，跳过更换。"
    else
        echo -e "${YELLOW}检测到当前内核 ($CURRENT_KERNEL) 不是针对虚拟化环境优化的 cloud 版本。${NC}"
        read -p "是否更换为 cloud 内核？(降低资源占用但减少硬件兼容，需重启生效) [y/N 默认: N]: " choice
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            warn "准备安装 linux-image-cloud-amd64..."
            apt-get install -yq linux-image-cloud-amd64 linux-headers-cloud-amd64 || die "安装 cloud 内核失败"
            update-grub
            
            # 清理旧内核
            OLD_KERNELS=$(dpkg -l | grep linux-image | awk '{print $2}' | grep -v "cloud" | grep -v "$CURRENT_KERNEL" || true)
            if [[ -n "$OLD_KERNELS" ]]; then 
                apt-get purge -yq $OLD_KERNELS
            fi
            info "Cloud 内核安装与清理完成。"
        else
            info "已跳过更换 cloud 内核。"
        fi
    fi
}

setup_sysctl() {
    info "检查建站基础 Sysctl 网络调优..."
    if [[ -f "/etc/sysctl.d/99-custom-optimize.conf" ]]; then
        info "Sysctl 优化配置文件已存在，跳过覆盖以保护自定义设置。"
    else
        # 将带有详细注释的配置写入系统，方便日后维护
        cat > /etc/sysctl.d/99-custom-optimize.conf << 'EOF'
# ==========================================
# 纯建站网络底层与高并发优化配置 (自动生成)
# ==========================================

# 1. 核心并发限制
# 提升系统允许分配的最大文件句柄数，防止高并发下 "Too many open files" 错误
fs.file-max = 1048576

# 2. 拥塞控制与底端队列
# 启用公平队列 (fq) 配合 Google BBR 算法，大幅提升高延迟/轻微丢包环境下的吞吐量
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 3. TCP 连接特性优化
# 开启 TCP Fast Open (值为3表示客户端和服务端均开启)，减少握手延迟 (需应用层支持)
net.ipv4.tcp_fastopen = 3
# 关闭路由指标缓存，防止前一个较差的连接状态影响后续新连接
net.ipv4.tcp_no_metrics_save = 1
# 显式设置 ecn 与 F-RTO，防止过时的优化脚本破坏系统默认设置，仅供手动编辑脚本调试
#net.ipv4.tcp_ecn = 2
#net.ipv4.tcp_frto = 2
# 显式开启 MTU 探测和 TIME-WAIT 保护
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
# 开启选择性重传和窗口缩放，提升长距离网络传输速度（冗余项，系统默认开启）
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
# 开启接收缓冲区自动调节（冗余项，系统默认开启）
net.ipv4.tcp_moderate_rcvbuf = 1

# 4. TCP KeepAlive 存活检测优化
# 缩短探测时间，更早发现僵尸连接，释放服务器资源
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30

# 5. 核心内存与网络缓冲区扩容
# 将内核收发缓冲区的上限拉高至约 16MB，满足大文件或高带宽延迟乘积 (BDP) 场景
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 6. TIME_WAIT 状态回收与连接复用
# 允许将 TIME_WAIT socket 用于新的 TCP 连接 (做反代时极度重要)
net.ipv4.tcp_tw_reuse = 1
# 修改 FIN_WAIT_2 状态的超时时间（默认60s，改小加速回收）
net.ipv4.tcp_fin_timeout = 15
# 限制系统最多保持的 TIME_WAIT 数量
net.ipv4.tcp_max_tw_buckets = 50000

# 7. 队列长度与端口范围扩容
# 增加监听队列上限 (防 SYN 洪水攻击和高并发排队)
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768
# 扩大可用作发起请求的临时端口范围 (10000 - 65535)
net.ipv4.ip_local_port_range = 10000 65535
EOF
        sysctl --system > /dev/null 2>&1 || warn "部分 Sysctl 参数可能因系统环境（如 LXC/WSL/容器）受限未能生效，这不影响后续安装。"
        info "Sysctl 参数已执行。"
    fi
}

setup_limits() {
    info "检查系统最大文件句柄数限制..."
    if grep -q "1048576" /etc/security/limits.d/99-nofile.conf 2>/dev/null; then
        info "文件句柄限制已解除，跳过。"
    else
        # 写入 limits.conf 提升单个用户/进程可以打开的文件数
        cat > /etc/security/limits.d/99-nofile.conf << 'EOF'
# 解除系统与用户的软/硬文件句柄限制至 100万
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
        # 同时修改 systemd 的全局配置，确保用 systemctl 启动的服务也生效
        sed -i 's/#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/g' /etc/systemd/system.conf
        sed -i 's/#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/g' /etc/systemd/user.conf
        info "文件句柄限制解除完成。"
    fi
}

setup_security() {
    info "检查 Fail2ban 和 UFW 配置..."
    apt-get install -yq fail2ban ufw > /dev/null

    # 1. 抓取“当前正在维持会话”的真实连接端口 (旧端口)
    local CURRENT_SSH_PORT=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        CURRENT_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi
    
    # 2. 抓取“系统配置中实际要监听”的未来端口 (新端口)
    # 优先使用 sshd -T 直接解析配置文件，比用 ss 抓取网络状态更安全（即使服务没启动也能取到）
    local LISTEN_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | head -n 1 || true)
    
    # 终极兜底：如果配置文件极其畸形导致没取到，回退到默认 22
    LISTEN_PORT=${LISTEN_PORT:-22}
    
    if [[ -f "/etc/fail2ban/jail.local" ]] && grep -q "port = $LISTEN_PORT" /etc/fail2ban/jail.local; then
        info "Fail2ban 已经为当前 SSH 端口配置防护，跳过。"
    else
        cat > /etc/fail2ban/jail.local << EOF
# Fail2ban 自定义拦截规则
[sshd]
enabled = true
port = $LISTEN_PORT
filter = sshd
logpath = /var/log/auth.log
# 失败 3 次即触发封禁
maxretry = 3
# 封禁时间：86400秒 (1天)
bantime = 86400
# 统计周期：10分钟内
findtime = 600
EOF
        systemctl restart fail2ban
        systemctl enable fail2ban
    fi

    # 3. UFW 防火墙双保险放行逻辑
    info "配置 UFW 防火墙基础规则..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # 必须放行未来的监听端口
    info "放行 sshd 配置监听端口: $LISTEN_PORT"
    ufw allow "${LISTEN_PORT}/tcp" comment 'SSH Listen Port' >/dev/null 2>&1

    # 如果当前会话端口与监听端口不同，进行过渡期保护
    if [[ -n "$CURRENT_SSH_PORT" && "$CURRENT_SSH_PORT" != "$LISTEN_PORT" ]]; then
        warn "检测到当前会话端口 ($CURRENT_SSH_PORT) 与 sshd 配置端口 ($LISTEN_PORT) 不一致！"
        info "为防止防火墙启动瞬间截断当前会话，已临时双向放行。"
        ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'SSH Active Session (Legacy)' >/dev/null 2>&1
    fi
}

setup_memory() {
    info "检查内存优化与虚拟内存配置..."
    PHY_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    PHY_MEM_MB=$((PHY_MEM_KB / 1024))
    
    # ==========================================
    # 1. ZRAM 交互式配置
    # ==========================================
    read -p "是否需要配置 ZRAM 内存压缩？(用 CPU 算力换取更大可用内存) [y/N 默认N]: " zram_choice
    if [[ "$zram_choice" =~ ^[Yy]$ ]]; then
        if grep -q "PERCENT=50" /etc/default/zramswap 2>/dev/null; then
            info "ZRAM 已经配置，跳过。"
        else
            info "配置 ZRAM..."
            apt-get install -yq zram-tools > /dev/null
            cat > /etc/default/zramswap << EOF
# ZRAM 配置: 使用高压缩比的 zstd 算法，占用最多 50% 的物理内存
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
            systemctl restart zramswap
            info "ZRAM 配置已生效。"
        fi
    else
        info "已跳过 ZRAM 内存压缩配置。"
    fi
    
    # ==========================================
    # 2. Swap 文件交互式配置
    # ==========================================
    read -p "是否需要配置传统 Swap 交换文件？(作为物理内存耗尽时的补充) [y/N 默认N]: " swap_choice
    if [[ "$swap_choice" =~ ^[Yy]$ ]]; then
        SWAP_SIZE_MB=$((PHY_MEM_MB * 2))
        if grep -q "/swapfile" /proc/swaps; then
            info "Swap 内存已挂载，跳过创建。"
        elif [[ -f /swapfile ]]; then
            info "Swap 文件已存在但未挂载，尝试重新挂载..."
            swapon /swapfile 2>/dev/null || warn "当前环境不支持挂载 Swap (可能是容器/WSL)，已跳过。"
        else
            info "创建 Swap 文件 (${SWAP_SIZE_MB}MB)..."
            fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB} status=progress
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            # 严格捕获 swapon 的状态
            if swapon /swapfile 2>/dev/null; then
                if ! grep -q "/swapfile" /etc/fstab; then 
                    echo "/swapfile none swap sw 0 0" >> /etc/fstab
                fi
                info "Swap 文件创建并挂载成功。"
            else
                warn "当前环境不支持挂载 Swap (可能是 LXC/WSL 容器)，清理无效的 Swap 文件..."
                rm -f /swapfile
            fi
        fi
    else
        info "已跳过 Swap 交换文件配置。"
    fi
}

setup_logrotate() {
    info "检查 Logrotate 配置..."
    if grep -q "daily" /etc/logrotate.conf; then
        info "Logrotate 已经是按天轮换，跳过。"
    else
        # 将日志保留周期改为按天，保留7天并开启压缩，防止日志塞满硬盘
        sed -i 's/weekly/daily/g' /etc/logrotate.conf
        sed -i 's/rotate 4/rotate 7/g' /etc/logrotate.conf
        sed -i 's/#compress/compress/g' /etc/logrotate.conf
    fi
}

setup_timezone() {
    info "检查时区与时间同步服务..."
    # 拦截 timedatectl 报错，取不到则赋值 Unknown
    CURRENT_TZ=$(timedatectl 2>/dev/null | awk '/Time zone/ {print $3}' || echo "Unknown")
    
    if [[ "$CURRENT_TZ" == "Unknown" ]]; then
        warn "当前环境无完整的 systemd 时间总线 (常见于 WSL/容器)，跳过时区自动设置。"
    elif [[ "$CURRENT_TZ" == "Asia/Shanghai" ]]; then
        info "时区已是 Asia/Shanghai，跳过。"
    else
        # 追加容错
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
        apt-get install -yq chrony > /dev/null 2>&1 || true
        systemctl enable chrony >/dev/null 2>&1 || true
        systemctl restart chrony >/dev/null 2>&1 || true
        info "时区与时间同步配置已执行。"
    fi
}

run_base_optimization() {
    global_netcheck
    setup_base
    setup_kernel
    setup_sysctl
    setup_limits
    setup_security
    setup_memory
    setup_logrotate
    setup_timezone
    
    # 写入基础优化完成的标记
    sed -i '/BASE_OPTIMIZED/d' "$INIT_FLAG" 2>/dev/null
    echo "BASE_OPTIMIZED=\"true\"" >> "$INIT_FLAG"
    
    info "基础系统优化检查/配置完成 (默认纯建站模式，未开启 IP 转发)！"
}

# =========================================================
# IP 转发独立管理模块
# =========================================================

get_ip_forward_status() {
    local status=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [[ "$status" == "1" ]]; then echo -e "${GREEN}[已开启]${NC}"; else echo -e "${YELLOW}[已关闭]${NC}"; fi
}

toggle_ip_forwarding() {
    local status=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [[ "$status" == "1" ]]; then
        info "关闭 IP 转发 (切换为纯建站模式)..."
        rm -f /etc/sysctl.d/99-ip-forwarding.conf
        sysctl -w net.ipv4.ip_forward=0 >/dev/null || true
        sysctl -w net.ipv4.conf.all.forwarding=0 >/dev/null || true
        sysctl -w net.ipv4.conf.default.forwarding=0 >/dev/null || true
        sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null || true
        sysctl -w net.ipv6.conf.default.forwarding=0 >/dev/null || true
        sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null || true
        info "IP 转发已关闭。"
    else
        info "开启 IP 转发 (代理/组网/容器模式就绪)..."
        cat > /etc/sysctl.d/99-ip-forwarding.conf << EOF
# ==========================================
# 代理/组网/容器 专用路由转发配置 (自动生成)
# ==========================================
# 允许 Linux 内核转发非发给本机网卡的数据包
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# 允许外部网络流量被路由或 NAT 映射到本地环回地址 (127.x.x.x)
# 这是 Docker 端口映射和诸多代理软件内网穿透的必备条件
# 为保证安全禁止修改，仅供手动编辑脚本调试
#net.ipv4.conf.all.route_localnet = 1
EOF
        sysctl --system > /dev/null 2>&1
        info "IP 转发已成功开启。"#
    fi
    sleep 2
}

# =========================================================
# 可选软件部署模块
# =========================================================

install_xray() {
    info "开始安装/更新 Xray Core..."
    download_with_fallback "/tmp/xray-install.sh" "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"|| return 1
    bash /tmp/xray-install.sh install -u root

    # 安装第三方规则和定时更新脚本
    setup_xray_geodata || true

    if systemctl is-active --quiet xray; then
        info "Xray 安装成功并已运行！"
    else
        warn "Xray 已安装，但可能因缺少配置文件暂未启动。"
    fi
}
uninstall_xray() {
    info "准备卸载 Xray Core..."
    
    # 1. 执行官方卸载逻辑
    if [[ ! -f "/tmp/xray-install.sh" ]]; then
        download_with_fallback "/tmp/xray-install.sh" "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"|| return 1
    fi
    bash /tmp/xray-install.sh remove >/dev/null 2>&1

    # 2. 停止服务并清理 Systemd 守护进程
    info "执行深度清理..."
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    rm -rf /etc/systemd/system/xray*
    systemctl daemon-reload
    # 清理规则和定时任务
    cleanup_xray_geodata

    # 3. 暴力扫荡所有可能的残留路径 (涵盖 get_status 扫描的范围)
    rm -rf /usr/bin/xray \
           /usr/local/bin/xray \
           /usr/local/etc/xray \
           /etc/xray \
           /opt/xray

    if command -v xray >/dev/null 2>&1; then
        warn "Xray 环境变量可能仍有残留，请手动检查: $(which xray 2>/dev/null)"
    else
        info "Xray 已卸载完毕。"
    fi
}
# --- 第三方规则安装函数 ---
setup_xray_geodata() {
    info "部署 Loyalsoldier 第三方路由规则 (geosite)..."
    local ASSET_DIR="/usr/local/share/xray"
    mkdir -p "$ASSET_DIR"
    local repo_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    # 使用高可用下载模块
    if download_with_fallback "$ASSET_DIR/ls-geosite.dat.new" "$repo_url"; then
        # 防御性校验：确保文件体积大于 100KB (防止镜像站返回错误页面)
        local filesize=$(stat -c%s "$ASSET_DIR/ls-geosite.dat.new" 2>/dev/null || echo 0)
        if [[ $filesize -gt 102400 ]]; then
            mv -f "$ASSET_DIR/ls-geosite.dat.new" "$ASSET_DIR/ls-geosite.dat"
        else
            rm -f "$ASSET_DIR/ls-geosite.dat.new"
            warn "下载的规则文件体积异常，已跳过替换。"
            return 1
        fi
    fi

    # 配置自动更新脚本
    local cron_script="/usr/local/bin/xray-rule-update.sh"
    cat > "$cron_script" << 'EOF'
#!/bin/bash
ASSET_DIR="/usr/local/share/xray"
TARGET_FILE="${ASSET_DIR}/ls-geosite.dat"
TMP_FILE="${TARGET_FILE}.new"
URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
DOWNLOAD_URL="$URL"
# 自动检测环境并加速
if curl -sSL -m 5 https://api.ip.sb/geoip 2>/dev/null | grep -i -q "China"; then
    DOWNLOAD_URL="https://ghfast.top/${URL}"
fi
if curl -fsSL -m 60 -o "$TMP_FILE" "$DOWNLOAD_URL" && [[ -s "$TMP_FILE" ]]; then
    mv -f "$TMP_FILE" "$TARGET_FILE"
    systemctl restart xray >/dev/null 2>&1
else
    rm -f "$TMP_FILE"
fi
EOF
    chmod +x "$cron_script"

    # 写入定时任务 (每周一 03:30)
    if ! crontab -l 2>/dev/null | grep -q "$cron_script"; then
        (crontab -l 2>/dev/null; echo "30 3 * * 1 $cron_script >/dev/null 2>&1") | crontab - || true
    fi
}
# --- 第三方规则卸载函数 ---
cleanup_xray_geodata() {
    info "清理 Xray 第三方规则及自动更新任务..."
    local cron_script="/usr/local/bin/xray-rule-update.sh"
    rm -rf /usr/local/share/xray
    rm -f "$cron_script"
    # 移除 crontab 条目
    if crontab -l 2>/dev/null | grep -q "$cron_script"; then
        (crontab -l 2>/dev/null | grep -v "$cron_script") | crontab - || true
    fi
}

install_easytier() {
    info "开始安装/更新 Easytier..."
    
    # 安装前置依赖检查：静默补齐 unzip
    if ! command -v unzip >/dev/null 2>&1; then
        info "未检测到解压工具 unzip，自动补全依赖..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq unzip >/dev/null 2>&1
    fi

    # 下载官方安装脚本
    download_with_fallback "/tmp/easytier-install.sh" "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh"|| return 1
    
    # 智能判断网络环境，决定是否使用代理参数
    local proxy_args=""
    if [[ "$IS_CN_REGION" == "true" ]]; then
        # 国内环境：传入 ghfast 镜像源参数
        proxy_args="--gh-proxy https://ghfast.top/"
        info "已为 Easytier 安装脚本开启 GitHub 代理: $proxy_args"
    else
        # 海外环境：禁用代理，走官方直连
        proxy_args="--no-gh-proxy"
        info "海外环境，为 Easytier 安装脚本禁用代理: $proxy_args"
    fi

    # 根据 /opt/easytier 目录或命令是否存在，判断是执行安装还是更新
    # 加上 || die 的短路拦截，如果官方脚本中途报错退出，外层脚本立刻阻断并爆红提示
    if [[ -d "/opt/easytier" ]] || command -v easytier-core >/dev/null 2>&1; then
        info "检测到 Easytier 已安装，执行 update 更新操作..."
        bash /tmp/easytier-install.sh update $proxy_args || { error "Easytier 更新失败，请检查上方报错日志！"; return 1; }
    else
        info "检测到 Easytier 未安装，执行全新安装..."
        bash /tmp/easytier-install.sh install $proxy_args || { err "Easytier 安装失败，请检查上方报错日志！"; return 1; }
    fi
    
    # 配置防火墙端口
    ufw allow 11010:11015/tcp comment 'Easytier' >/dev/null 2>&1
    ufw allow 11010:11015/udp comment 'Easytier' >/dev/null 2>&1
    info "Easytier 操作完成，UFW 已放行 11010-11015 端口！"
    info "配置文件位于: /opt/easytier/config/default.conf"
}
uninstall_easytier() {
    info "准备卸载 Easytier..."
    
    if [[ ! -f "/tmp/easytier-install.sh" ]]; then
        download_with_fallback "/tmp/easytier-install.sh" "https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh"|| return 1
    fi
    bash /tmp/easytier-install.sh uninstall >/dev/null 2>&1

    info "执行深度清理..."
    systemctl stop easytier >/dev/null 2>&1
    systemctl disable easytier >/dev/null 2>&1
    rm -rf /etc/systemd/system/easytier*
    systemctl daemon-reload

    # 暴力扫荡 Easytier 的所有二进制文件及 /opt 下的配置目录
    rm -rf /usr/bin/easytier-core \
           /usr/local/bin/easytier-core \
           /opt/easytier \
           /opt/easytier-core

    if command -v easytier-core >/dev/null 2>&1; then
        warn "Easytier 环境变量可能仍有残留，请手动检查: $(which easytier-core 2>/dev/null)"
    else
        info "Easytier 已卸载完毕。"
    fi
}

install_tailscale() {
    local is_update="false"

    # 1. 智能状态侦测
    if command -v tailscale >/dev/null 2>&1; then
        is_update="true"
        info "检测到 Tailscale 已安装，准备拉取最新版本进行更新..."
    else
        info "开始全新安装 Tailscale 客户端..."
    fi

    # 2. 安全获取官方安装脚本 (带有超时控制)
    info "获取官方安装脚本..."
    curl -fsSL --connect-timeout 10 https://tailscale.com/install.sh -o /tmp/tailscale-install.sh || { 
        err "获取安装脚本失败！请检查服务器是否能正常访问 tailscale.com。"
        return 1 
    }

    # 3. 执行安装/更新，并严密捕获报错
    info "执行自动部署流程 (调用系统包管理器拉取核心组件，请耐心等待)..."
    
    # 屏蔽冗长杂乱的正常输出，但一旦返回非 0 状态码，立刻拦截并警告
    sh /tmp/tailscale-install.sh >/dev/null 2>&1 || { 
        err "Tailscale 安装/更新失败！"
        warn "这通常是因为国内网络拉取官方 APT 源 (pkg.tailscale.com) 超时或 GPG 阻断导致。"
        warn "建议开启全局代理后重试，或稍后网络畅通时再次执行。"
        return 1 
    }

    # 4. 防火墙放行 (加入静默容错逻辑，防止未安装 UFW 时报错)
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 41641/udp comment 'Tailscale P2P' >/dev/null 2>&1
    fi

    # 5. 差异化结果反馈与引导
    if [[ "$is_update" == "false" ]]; then
        info "Tailscale 全新部署成功！"
        info "已尝试在防火墙放行 41641/udp 端口 (这对于优化 P2P 直连打洞极其重要)。"
        
        # 使用醒目的提示框引导用户手动绑定
        echo -e "\n${YELLOW}================================================================${NC}"
        echo -e "${GREEN}节点尚未绑定！请退出面板后，在终端手动输入以下命令获取登录链接：${NC}"
        echo -e "${YELLOW}tailscale up${NC}"
        echo -e "${YELLOW}================================================================${NC}\n"
    else
        info "Tailscale 更新成功！底层守护进程已自动接管。"
        
        # 更新完毕后顺手做个健康检查
        if ! systemctl is-active --quiet tailscaled; then
            warn "检测到 tailscaled 守护进程似乎未运行，请稍后手动检查: systemctl status tailscaled"
        fi
    fi
}
uninstall_tailscale() {
    info "准备卸载 Tailscale..."
    
    # 1. 包管理器卸载
    apt-get purge -yq tailscale >/dev/null 2>&1
    
    # 2. 暴力扫荡配置与数据残留
    info "执行深度清理..."
    rm -rf /var/lib/tailscale \
           /etc/tailscale \
           /usr/bin/tailscale \
           /usr/sbin/tailscaled \
           /opt/tailscale

    if command -v tailscale >/dev/null 2>&1; then
        warn "包管理器可能卡死，尝试手动执行强制移除: dpkg --remove --force-all tailscale"
    else
        info "Tailscale 已卸载完毕。"
    fi
}

install_warp() {
    local is_update="false"

    # 1. 智能状态侦测
    if command -v warp-cli >/dev/null 2>&1; then
        is_update="true"
        info "检测到 Cloudflare WARP 已安装，准备拉取最新包进行更新..."
    else
        info "开始安装 Cloudflare WARP 客户端并配置 Socks5 模式..."
    fi

    # 2. 依赖检查与源配置
    info "配置 Cloudflare 官方 APT 源..."
    if ! command -v lsb_release >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq lsb-release gnupg || { err "系统依赖 (lsb-release/gnupg) 安装失败，请检查网络！"; return 1; }
    fi

    # 捕获 GPG 下载报错 (国内直连 pkg.cloudflareclient.com 可能受阻)
    curl -fsSL --connect-timeout 5 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg || { err "GPG 密钥下载失败，请检查网络是否能直连 Cloudflare 源！"; return 1; }
    
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null

    # 3. 安装或更新
    info "拉取包信息并执行安装/更新 (可能需要一些时间)..."
    apt-get update -yq >/dev/null 2>&1 || { err "APT 源更新失败，请检查系统源配置！"; return 1; }
    apt-get install -yq cloudflare-warp || { err "WARP 客户端安装/更新失败！"; return 1; }

    # 清理可能导致 Systemd 幽灵报错的残留空文件
    if [[ -f "/etc/systemd/system/warp-svc.service" && ! -L "/etc/systemd/system/warp-svc.service" ]]; then
        rm -f "/etc/systemd/system/warp-svc.service"
        systemctl daemon-reload
    fi

    # 确保基础服务被成功拉起，并等待 Socket 接口就绪
    info "等待 WARP 基础守护进程初始化..."
    systemctl unmask warp-svc >/dev/null 2>&1
    systemctl enable --now warp-svc >/dev/null 2>&1
    
    local retry=0
    while ! warp-cli --accept-tos status >/dev/null 2>&1; do
        sleep 1
        ((retry++))
        if [[ $retry -ge 10 ]]; then
            err "WARP 守护进程启动超时，无法建立本地通信 Socket！"
            return 1
        fi
    done

    # 4. 差异化配置与容错处理
    if [[ "$is_update" == "false" ]]; then
        info "首次安装，注册并配置 WARP 为代理模式..."
        
        # 国内机器注册极大可能失败，这里进行重点捕获
        # 注册阶段会消耗较多内存进行密码学运算，因此必须在限制内存前执行
        warp-cli --accept-tos registration new >/dev/null 2>&1 || { 
            err "WARP 注册失败！这通常是因为 Cloudflare API 在国内被阻断。请考虑开启全局代理后再试。"
            return 1 
        }

        # 核心精简指令
        # 协议降级与去除遥测
        info "修改隧道协议为WireGuard并去除遥测组件..."
        # 强制使用轻量的 WireGuard 协议，停用复杂的 MASQUE (HTTP/3) 协议
        warp-cli --accept-tos tunnel protocol set WireGuard >/dev/null 2>&1
        # 关闭家庭过滤/防注入等额外 DNS 开销
        warp-cli --accept-tos dns families off >/dev/null 2>&1
        warp-cli --accept-tos dns log disable >/dev/null 2>&1

        warp-cli --accept-tos mode proxy >/dev/null 2>&1 || { err "WARP 设置代理模式失败！"; return 1; }
        warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 || { err "WARP 设置代理端口失败！"; return 1; }
        warp-cli --accept-tos connect >/dev/null 2>&1 || { err "WARP 启动连接失败！"; return 1; }
    else
        info "WARP 更新包安装完成！验证并重新下发优化指令..."
        warp-cli --accept-tos tunnel protocol set WireGuard >/dev/null 2>&1
        warp-cli --accept-tos dns families off >/dev/null 2>&1
        warp-cli --accept-tos dns log disable >/dev/null 2>&1
        warp-cli --accept-tos connect >/dev/null 2>&1
    fi
    
    # Systemd 级性能与内存优化
    info "检查并注入系统级性能限制与日志静音..."
    local need_restart="false"

    # 检查并按需生成 Systemd 覆盖文件
    mkdir -p /etc/systemd/system/warp-svc.service.d
    local override_file="/etc/systemd/system/warp-svc.service.d/override.conf"
    # 如果文件不存在，或者文件内容不包含我们设定的 MemoryHigh，才执行覆写
    if [[ ! -f "$override_file" ]] || ! grep -q "MemoryHigh=80M" "$override_file"; then
        cat > "$override_file" << EOF
[Service]
# 达到 80M 时内核执行 GC 回收
MemoryHigh=80M
# 超过 120M 直接 OOM 击杀防卡死
MemoryMax=120M
# 崩溃后延迟 5 秒重启，防 CPU 飙升
RestartSec=5s
# 屏蔽 journald 抓取 WARP 的调试和冗余输出
LogLevelMax=error
EOF
        need_restart="true"
        info "已注入 Systemd 内存与日志限制规则。"
    fi

    # 将 WARP 私有的统计和日志文件全部软链接到黑洞，彻底斩断磁盘 I/O 遥测
    mkdir -p /var/log/cloudflare-warp
    local log_file="/var/log/cloudflare-warp/cfwarp_service_log.txt"
    local stats_file="/var/log/cloudflare-warp/cfwarp_service_stats.txt"
    # 检查软链接状态，按需切断物理日志
    if [[ $(readlink "$log_file") != "/dev/null" || $(readlink "$stats_file") != "/dev/null" ]]; then
        rm -f "$log_file" "$stats_file"
        ln -sf /dev/null "$log_file"
        ln -sf /dev/null "$stats_file"
        need_restart="true"
        info "已将遥测与诊断日志重定向至 /dev/null。"
    fi


    # 只有当配置真正发生改变时，才执行耗时且会打断业务的 reload 和 restart
    if [[ "$need_restart" == "true" ]]; then
        info "优化配置已变更，重启 warp-svc 以应用新配置..."
        # 重载 systemd 使性能锁生效
        systemctl daemon-reload
        systemctl restart warp-svc

        # 再次轮询等待 Socket 重连，彻底消除闪断报错
        retry=0
        while ! warp-cli --accept-tos status >/dev/null 2>&1; do
            sleep 1
            ((retry++))
            if [[ $retry -ge 10 ]]; then
                err "WARP 重启后失去响应，请检查系统日志！"
                return 1
            fi
        done
        info "优化配置应用成功！"
    else
        info "系统级性能限制已设置，无需重复应用。"
    fi

    info "WARP 全局配置与优化完成，Socks5 代理位于: 127.0.0.1:40000"
}
uninstall_warp() {
    info "准备卸载 Cloudflare WARP 客户端..."
    
    warp-cli --accept-tos disconnect >/dev/null 2>&1
    warp-cli --accept-tos registration delete >/dev/null 2>&1
    apt-get purge -yq cloudflare-warp >/dev/null 2>&1

    info "执行深度清理..."
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -rf /usr/bin/warp-cli \
           /usr/bin/warp-svc \
           /opt/cloudflare-warp \
           /etc/systemd/system/warp-svc.service.d

    if command -v warp-cli >/dev/null 2>&1; then
        warn "包管理器可能卡死，尝试手动执行强制移除: dpkg --remove --force-all cloudflare-warp"
    else
        info "Cloudflare WARP 已卸载完毕。"
    fi
}
install_usque() {
    local is_update="false"
    local was_running="false"

    # 1. 状态感知与生命周期管理
    if [[ -f "/opt/usque/usque" ]]; then
        is_update="true"
        info "检测到 Usque 已安装，准备拉取最新版进行更新..."
        # 精准记忆更新前的运行状态
        if systemctl is-active --quiet usque; then
            was_running="true"
            info "检测到 Usque 服务正在运行，更新后将自动重启服务。"
        else
            info "检测到 Usque 服务处于停止状态，更新后将保持停止。"
        fi
    else
        info "开始全新安装 Usque (轻量级 WARP MASQUE 客户端)..."
    fi

    # 2. 本地依赖检查
    if ! command -v jq >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        info "安装必要依赖 (jq, unzip)..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq jq unzip || { err "依赖安装失败，请尝试手动安装！"; return 1; }
    fi

    # 3. 跨架构自适应支持 (完美兼容 AMD64 和 ARM64)
    local arch=""
    case $(uname -m) in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) err "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac

    # 4. 动态解析 GitHub 最新 Release
    info "查询 GitHub 获取最新版下载链接..."
    local api_url="https://api.github.com/repos/Diniboy1123/usque/releases/latest"
    # 增加超时限制，防止国内机器卡死
    local release_json=$(curl -sSL --connect-timeout 10 "$api_url")
    
    # 巧妙利用 jq 的 select 语法，不再硬编码版本号，永远锁定最新的 linux_架构.zip
    local dl_url=$(echo "$release_json" | jq -r ".assets[] | select(.name | contains(\"linux_${arch}.zip\")) | .browser_download_url" 2>/dev/null)

    if [[ -z "$dl_url" || "$dl_url" == "null" ]]; then
        err "获取 Usque 下载链接失败！可能遇到了 GitHub API 限流，请稍后再试。"
        return 1
    fi

    # 5. 沙盒化下载与部署
    mkdir -p /opt/usque
    local temp_dir="/tmp/usque_install_$$"
    mkdir -p "$temp_dir"
    cd "$temp_dir" || return 1
    
    # 无论成功与否，退出函数时彻底销毁临时沙盒
    trap 'rm -rf "$temp_dir"' EXIT

    info "下载核心文件..."
    # 完美复用我们的 fallback 下载函数，无视国内墙的阻力
    download_with_fallback "usque.zip" "$dl_url" || { err "Usque 下载失败！请检查网络。"; return 1; }
    
    info "解压并部署二进制文件..."
    unzip -q usque.zip || { err "解压失败！压缩包可能已损坏。"; return 1; }
    
    # 强行覆盖目标目录并赋权
    mv -f usque /opt/usque/usque
    chmod +x /opt/usque/usque

    # 6. 交互式 JWT 注册 (仅在全新安装或缺失配置时触发)
    if [[ "$is_update" == "false" || ! -f "/opt/usque/config.json" ]]; then
        echo -e "\n${YELLOW}================================================================${NC}"
        echo -e "${GREEN}Usque 支持通过 Zero Trust 的 JWT Token 直接生成 MASQUE 高级配置。${NC}"
        echo -e "您可以在浏览器登录 Cloudflare Zero Trust 抓取 Token (通常以 eyJ 开头)。"
        echo -e "${YELLOW}================================================================${NC}"
        echo -e "请输入您的完整 JWT Token (按回车可跳过本步，直接自动注册): "
        read -s jwt_token
        echo ""

        if [[ -n "$jwt_token" ]]; then
            info "正在向 Cloudflare 注册设备，请稍候..."
            cd /opt/usque || return 1
            if ./usque register --jwt "$jwt_token" --accept-tos >/dev/null 2>&1; then
                info "✅ 设备注册成功！已在 /opt/usque 目录下生成 config.json。"
            else
                warn "注册失败！Token 可能无效或网络环境受限。您可以随后手动运行注册命令。"
            fi
        else
            info "已跳过自动注册，您可以随后在 /opt/usque 目录下手动执行 register 命令。"
        fi
    fi

    # 7. Systemd 守护进程配置 (每次安装/更新都会幂等覆写以保证配置最新)
    info "配置 Systemd 守护进程..."
    cat > /etc/systemd/system/usque.service << EOF
[Unit]
Description=Usque MASQUE Client (SOCKS5 Proxy)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/usque
ExecStart=/opt/usque/usque socks -b 127.0.0.1 -p 40001
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    # 8. 绝对严谨的状态流转
    if [[ "$is_update" == "true" ]]; then
        if [[ "$was_running" == "true" ]]; then
            info "检测到更新前服务正在运行，重启 usque 服务应用新版本..."
            systemctl restart usque
            info "✅ Usque 更新并重启成功！"
        else
            info "✅ Usque 更新成功！(服务依然保持停止状态)"
        fi
    else
        info "✅ Usque 全新安装成功！默认 socks5 代理端口为 40001"
        info "请手动执行命令启用 Usque 服务: ${YELLOW}systemctl enable usque --now${NC}"
    fi
}
uninstall_usque() {
    if [[ ! -f "/opt/usque/usque" && ! -f "/etc/systemd/system/usque.service" ]]; then
        warn "Usque 未安装，无需卸载。"
        return 0
    fi

    echo -e "\n${YELLOW}警告: 此操作将彻底删除 Usque 及其所有配置文件 (包括 config.json 中的私钥)！${NC}"
    read -p "确定要继续吗？[y/N 默认: N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消卸载。"
        return 0
    fi

    info "停止并禁用 Usque 服务..."
    systemctl stop usque >/dev/null 2>&1
    systemctl disable usque >/dev/null 2>&1
    rm -f /etc/systemd/system/usque.service
    systemctl daemon-reload

    info "删除核心文件与配置..."
    rm -rf /opt/usque

    info "✅ Usque 已卸载完毕。"
}
generate_warp_xray() {
    info "生成基于 WireGuard 协议的 Xray WARP 出站配置..."
    
    # 1. 基础依赖检查
    if ! command -v jq >/dev/null 2>&1; then
        info "安装必要依赖 (jq)..."
        apt-get update -yq >/dev/null 2>&1
        apt-get install -yq jq >/dev/null 2>&1 || { err "依赖 jq 安装失败，请检查网络！"; return 1; }
    fi

    # 2. 创建独立沙盒环境
    local temp_dir="/tmp/warp_generator_$$"
    mkdir -p "$temp_dir"
    cd "$temp_dir" || return 1
    
    # 确保在函数退出时（无论成功还是报错退出）彻底销毁沙盒，实现零残留
    trap 'rm -rf "$temp_dir"' EXIT

    # 3. 智能拉取 wgcf (调用全局高可用下载模块)
    info "临时拉取 wgcf 工具..."
    local arch=""
    case $(uname -m) in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) err "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac

    local wgcf_version="2.2.22"
    local original_url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_version}/wgcf_${wgcf_version}_linux_${arch}"
    
    # 把原始 URL 交给轮询函数，只要成功下载就继续，失败则阻断返回
    download_with_fallback "wgcf" "$original_url" || { err "wgcf 工具核心拉取失败，请检查网络或稍后重试！"; return 1; }
    
    chmod +x wgcf

    # 4. 利用 wgcf 傻瓜式注册账户
    info "委托 wgcf 向 Cloudflare 注册设备..."
    if ! ./wgcf register --accept-tos >/dev/null 2>&1; then
        err "WARP 账户注册失败！请确认服务器网络是否正常。"
        return 1
    fi
    
    if ! ./wgcf generate >/dev/null 2>&1; then
        err "WARP 配置文件生成失败！"
        return 1
    fi

    # 5. 从生成的配置中“榨取”核心数据
    info "提取私钥与设备 ID..."
    
    # 从 wgcf-account.toml 提取 Client ID 和 Private Key
    local client_id=$(grep -m 1 "device_id" wgcf-account.toml | awk -F"'" '{print $2}')
    local private_key=$(grep -m 1 "private_key" wgcf-account.toml | awk -F"'" '{print $2}')
    
    # 扫描全文本，精准提取双栈 IP
    local ipv4=$(grep "^Address" wgcf-profile.conf | grep -oE "172\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1)
    # 增加 A-F 大写兼容，防止 CF 后期改变大小写输出格式
    local ipv6=$(grep "^Address" wgcf-profile.conf | grep -oE "2606:[a-fA-F0-9:]+" | head -n 1)
    
    if [[ -z "$client_id" || -z "$private_key" || -z "$ipv4" ]]; then
        err "配置解析失败，未能提取到完整的账户信息！"
        return 1
    fi

    # 6. 原生计算 reserved (突破 CF 阻断的核心黑科技)
    info "换算 reserved 防封锁特征码..."
    local hex_client_id=$(echo -n "$client_id" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
    local r1=$((16#${hex_client_id:0:2}))
    local r2=$((16#${hex_client_id:2:2}))
    local r3=$((16#${hex_client_id:4:2}))
    local reserved="[${r1}, ${r2}, ${r3}]"

    # 7. 自动并发优选 Endpoint IP
    info "自动优选最低延迟的 Endpoint IP..."
    local cf_ips=("162.159.192.1" "162.159.193.1" "162.159.195.1" "188.114.96.3" "188.114.97.3" "188.114.98.3")
    local best_ip="162.159.192.1"
    local best_ping=9999
    
    for ip in "${cf_ips[@]}"; do
        local avg_ping=$(ping -c 3 -W 1 "$ip" 2>/dev/null | awk -F '/' 'END {print $5}' | cut -d. -f1)
        if [[ -n "$avg_ping" && "$avg_ping" =~ ^[0-9]+$ && "$avg_ping" -lt "$best_ping" ]]; then
            best_ping=$avg_ping
            best_ip=$ip
        fi
    done
    info "✅ 最优 Endpoint 锁定: ${best_ip}:2408 (平均延迟: ${best_ping}ms)"

    # 8. 动态精准探测 Path MTU (禁止分片撞击测试)
    info "通过 ICMP 撞击测试探测链路极限 MTU..."
    local test_payload=1412 # 起始载荷 (对应 MTU 1440)
    local optimal_mtu=1440
    local mtu_found=false

    while (( test_payload >= 1200 )); do
        if ping -c 1 -M do -s "$test_payload" -W 1 "$best_ip" >/dev/null 2>&1; then
            optimal_mtu=$(( test_payload + 28 ))
            mtu_found=true
            break
        fi
        (( test_payload -= 10 ))
    done

    if [[ "$mtu_found" == "false" ]]; then
        warn "⚠️ 链路 MTU 严重受限或服务器禁止 Ping 探测！启用安全回退值: 1280"
        optimal_mtu=1280
    else
        info "✅ 撞击测试通过！最终计算最佳 MTU: ${optimal_mtu}"
    fi

    # 9. 自动获取 CPU 核心数
    # local workers=$(nproc 2>/dev/null || echo 2)
    # info "✅ 自动分配 Workers: ${workers} (基于系统 CPU 核心数)"

    # 10. 拼装高规格 Xray JSON 结构
    local address_json="\"${ipv4}/32\""
    if [[ -n "$ipv6" ]]; then
        # 移除 \n，直接用逗号和空格拼接，让后期的 jq 去自动美化换行
        address_json="\"${ipv4}/32\", \"${ipv6}/128\""
    fi

    local xray_json=$(cat <<EOF
{
  "tag": "warp",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${private_key}",
    "address": [
      ${address_json}
    ],
    "peers": [
      {
        "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "endpoint": "${best_ip}:2408"
      }
    ],
    "mtu": ${optimal_mtu},
    "reserved": ${reserved}
  }
}
EOF
)

    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${YELLOW}🎉 基于 WireGuard 协议的 Xray WARP 出站生成成功：${NC}"
    echo -e "${GREEN}================================================================${NC}\n"
    
    echo "$xray_json" | jq .
    
    echo -e "\n${GREEN}================================================================${NC}"
    info "💡 注意事项："
    info "1. 该配置的 tag 已默认为 "warp"，MTU 已优化为最佳值。"
    info "2. 在 Xray 的 routing -> rules 中，将需要解锁的域名 (如 geosite:openai, geosite:netflix) 指向 "warp"。"
    info "3. 请勿修改 reserved 数组字段，这是防止 CloudFlare 屏蔽非官方客户端的关键。"
}

install_docker() {
    info "开始安装/更新 Docker Engine 与 Docker Compose..."
    
    # 1. 下载官方一键安装脚本
    download_with_fallback "/tmp/get-docker.sh" "https://raw.githubusercontent.com/docker/docker-install/master/install.sh"|| return 1
    
    # 2. 智能判断网络，执行安装
    if [[ "$IS_CN_REGION" == "true" ]]; then
        info "国内环境拦截，自动切换至 Aliyun 镜像源进行极速安装..."
        bash /tmp/get-docker.sh --mirror Aliyun
    else
        info "海外环境，使用官方主干源安装..."
        bash /tmp/get-docker.sh
    fi
    
    # 3. 生产环境性能与可用性优化 (配置 daemon.json)
    info "注入 Docker 生产环境性能优化配置..."
    mkdir -p /etc/docker
    
    # 国内环境附加 Registry 镜像加速池 (防 Docker Hub 被墙)
    local registry_mirrors=""
    if [[ "$IS_CN_REGION" == "true" ]]; then
        registry_mirrors='"registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://mirror.baidubce.com",
        "https://docker.nju.edu.cn"
    ],'
    fi

    # 写入优化配置
    cat > /etc/docker/daemon.json << EOF
{
    ${registry_mirrors}
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    },
    "live-restore": true,
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 5,
    "storage-driver": "overlay2"
}
EOF
    # 释义：
    # log-opts: 限制日志最大 20MB，保留 3 个滚动副本，防止无限变大撑爆硬盘 (最重要)
    # live-restore: 当 dockerd 进程崩溃或升级重启时，保持容器继续运行不掉线
    # max-concurrent-*: 增加镜像拉取/推送的并发线程数，大幅提升下载速度
    # storage-driver: 显式指定最高效的 overlay2 存储驱动

    systemctl daemon-reload
    systemctl enable docker >/dev/null 2>&1
    systemctl restart docker

    # 验证安装
    if command -v docker >/dev/null 2>&1; then
        info "Docker & Docker Compose 安装并优化成功！"
        docker compose version
        warn "注意：Docker 运行容器通常需要开启 IP 转发，请确保你在主菜单开启了该选项。"
    else
        err "Docker 安装失败，请检查网络或系统环境。"
        return 1
    fi
}
uninstall_docker() {
    info "准备卸载 Docker & Docker Compose..."
    
    # 【新增】交互式询问：是否保留核心业务数据
    echo -e "${YELLOW}======================================================${NC}"
    echo -e "卸载时可选择保留或删除已有的业务数据（即【数据卷】与【容器状态】）。"
    echo -e "${YELLOW}======================================================${NC}"
    read -p "是否彻底删除所有的容器、镜像与数据卷? [y/N 默认: N]: " delete_data
    # 如果用户直接敲回车，变量默认为 N
    delete_data=${delete_data:-N} 

    # 1. 停止所有相关服务
    info "停止 Docker 守护进程..."
    systemctl stop docker >/dev/null 2>&1
    systemctl stop docker.socket >/dev/null 2>&1
    systemctl stop containerd >/dev/null 2>&1
    
    # 2. 包管理器彻底卸载程序本体
    info "卸载 Docker 核心程序包..."
    apt-get purge -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras >/dev/null 2>&1
    apt-get autoremove -yq >/dev/null 2>&1
    
    # 3. 基础环境与网络清理 (无论选什么，这些都要删)
    rm -rf /etc/docker \
           /usr/libexec/docker \
           /var/run/docker.sock \
           /usr/local/bin/docker-compose

    # 4. 根据用户的选择处理数据生命周期
    if [[ "$delete_data" =~ ^[Yy]$ ]]; then
        warn "执行彻底清理，抹除所有容器、镜像、网络和数据卷..."
        rm -rf /var/lib/docker \
               /var/lib/containerd
        info "历史数据已全部清空，释放了所有的磁盘空间。"
    else
        info "已为您安全保留核心数据目录 (/var/lib/docker)。"
        info "未来在此服务器重新安装 Docker 后，原有的容器和服务将无缝恢复运行。"
    fi

    # 5. 最终状态校验
    if command -v docker >/dev/null 2>&1; then
        warn "包管理器可能卡死，尝试手动执行强制移除: apt purge -y docker-ce"
    else
        info "Docker 环境已卸载完毕。"
    fi
}

install_go() {
    info "开始安装/修复 Go 语言环境..."
    
    # 1. 智能切换 Go 语言下载源头
    local go_domain="go.dev"
    if [[ "$IS_CN_REGION" == "true" ]]; then
        go_domain="golang.google.cn" # 墙内可直连的 Go 官方国内镜像
        info "国内环境拦截，切换 Go 语言源为国内官方镜像: $go_domain"
    fi

    # 2. 获取 Go 最新版本 (增加 5秒 超时防卡死)
    GO_LATEST_VERSION=$(curl -s --connect-timeout 5 --max-time 10 "https://${go_domain}/VERSION?m=text" | head -n 1)
    if [[ -z "$GO_LATEST_VERSION" ]]; then 
        GO_LATEST_VERSION="go1.22.1"
        warn "获取 Go 最新版本号超时，将使用保底版本: $GO_LATEST_VERSION"
    fi
    
    info "下载并安装 $GO_LATEST_VERSION (显示下载进度)..."
    # 废弃静默的 wget，改用 curl 并显示进度条，加入严苛超时控制
    if ! curl -# -L --connect-timeout 5 -o /tmp/go.tar.gz "https://${go_domain}/dl/${GO_LATEST_VERSION}.linux-amd64.tar.gz"; then
        err "Go 语言环境下载失败，请检查网络！"
        return 1
    fi
    
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    
    # 3. 智能配置 Go Modules 国内代理 (极其重要，否则编译必卡死)
    if [[ "$IS_CN_REGION" == "true" ]]; then
        info "国内环境拦截，配置 GOPROXY 为国内七牛云加速节点..."
        export GOPROXY=https://goproxy.cn,direct
    fi
    
    info "Go 语言环境安装/修复成功！"
}
uninstall_go() {
    info "准备卸载 Go 语言环境及编译缓存..."
    
    # 检查 Go 是否存在
    if [[ ! -d "/usr/local/go" ]] && [[ ! -d "$HOME/go" ]]; then
        warn "系统中未检测到 Go 环境目录 (/usr/local/go 或 ~/go)。"
        return
    fi

    # 删除 Go 的安装目录和编译工具链缓存目录
    rm -rf /usr/local/go
    rm -rf "$HOME/go"
    
    # 清理之前下载遗留的压缩包（如果有的话）
    rm -f /tmp/go.tar.gz

    # 2. 暴力扫荡配置与数据残留
    info "执行深度清理..."
    rm -rf /var/lib/go \
           /etc/go \
           /usr/bin/go \
           /usr/sbin/go \
           /opt/go

    info "Go 语言环境及缓存已卸载完毕。"
}

install_caddy() {
    local is_update="false"
    local was_running="false"
    
    # 智能状态侦测
    if command -v caddy >/dev/null 2>&1 || [[ -f "/usr/bin/caddy" ]]; then
        is_update="true"
        info "检测到 Caddy 已安装，准备拉取最新源码进行编译更新..."
        # 记录更新前服务是否处于运行状态
        if systemctl is-active --quiet derper; then
            was_running="true"
        fi
    else
        info "准备编译并部署带有 layer4 / cloudflare / naiveproxy 插件的 Caddy..."
    fi

    # 确保 Go 环境已就绪
    if ! command -v go >/dev/null 2>&1; then
        err "未检测到 Go 环境！请先在当前菜单选择【1. 修复/更新 Go 环境】。"
        return 1
    fi
    
    # 确保国内编译环境不卡死
    [[ "$IS_CN_REGION" == "true" ]] && export GOPROXY=https://goproxy.cn,direct
    
    # 安装 xcaddy
    info "安装 xcaddy 编译工具..."
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    export PATH=$PATH:~/go/bin
    
    info "开始编译 Caddy (此过程可能耗时几分钟并消耗较多内存，请耐心等待)..."
    cd /tmp
    xcaddy build \
        --with github.com/mholt/caddy-l4 \
        --with github.com/caddy-dns/cloudflare \
        --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
        
    if [[ ! -f "./caddy" ]]; then 
        err "Caddy 编译失败，可能是内存不足或网络中断。"
        return 1
    fi

    info "编译成功，开始规范化部署..."
    # 仅在编译成功后才停机替换，将业务中断时间降至最低
    systemctl stop caddy >/dev/null 2>&1
    mv ./caddy /usr/bin/caddy
    chmod +x /usr/bin/caddy
    # 赋予二进制文件绑定 1024 以下低位端口的权限，免去 root 运行的安全隐患
    setcap cap_net_bind_service=+ep /usr/bin/caddy

    # 只有在全新安装时，才初始化用户和配置文件
    if [[ "$is_update" == "false" ]]; then
        # 创建标准运行环境
        groupadd --system caddy 2>/dev/null
        useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null
        mkdir -p /etc/caddy /etc/ssl/caddy /usr/share/caddy
        chown -R caddy:root /etc/caddy /etc/ssl/caddy
        echo "<h1>Caddy Works!</h1>" > /usr/share/caddy/index.html

        cat > /etc/caddy/Caddyfile << 'EOF'
# ==========================================
# Caddy 全局配置与入口文件
# ==========================================
# 监听 80 端口，配置一个静态文件服务器用于默认展示
:80 {
    root * /usr/share/caddy
    file_server
}
# 注意: 你已经编译了 l4 和 naiveproxy 插件
# 可以在此处添加你的自定义代理配置
EOF

        cat > /etc/systemd/system/caddy.service << 'EOF'
# ==========================================
# Caddy Systemd 守护进程配置文件
# ==========================================
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
# 以低权限系统用户运行，提升安全性
User=caddy
Group=caddy
# 指定运行目录
ReadWritePaths=/var/log/caddy /var/www/html

ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure
TimeoutStopSec=5s

# 资源限制与权限保护
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
# 允许 Caddy 绑定 80/443 端口
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
        systemctl daemon-reload
        
        ufw allow 80/tcp comment 'Caddy HTTP'
        ufw allow 443/tcp comment 'Caddy HTTPS'
        ufw allow 443/udp comment 'Caddy HTTP3'
        
        info "Caddy (带插件版) 部署成功！已开放 80/443 端口。"
    else
        info "Caddy 更新完成，您的自定义 Caddyfile 已被安全保留！"
        # 智能拉起：如果更新前它是运行的，更新后自动拉起；如果是关闭的，保持关闭。
        if [[ "$was_running" == "true" ]]; then
            systemctl start caddy
            info "检测到更新前服务处于运行状态，已自动重启 Caddy 服务。"
        fi
    fi
}
uninstall_caddy() {
    info "准备卸载自定义编译版 Caddy..."
    
    # 1. 停止服务并清理守护进程
    systemctl stop caddy >/dev/null 2>&1
    systemctl disable caddy >/dev/null 2>&1
    rm -rf /etc/systemd/system/caddy*
    systemctl daemon-reload

    # 2. 暴力扫荡所有的配置文件、证书目录、Web目录和二进制文件
    info "执行深度清理..."
    rm -rf /usr/bin/caddy \
           /usr/local/bin/caddy \
           /etc/caddy \
           /usr/share/caddy \
           /etc/ssl/caddy \
           /opt/caddy

    if command -v caddy >/dev/null 2>&1; then
        warn "系统中可能存在通过 apt 安装的官方版，尝试执行: apt purge -yq caddy"
    else
        info "自定义 Caddy 已卸载完毕。"
    fi
}

install_derper() {
    local is_update="false"
    local was_running="false"

    # === 自定义配置区 ===
    local DERP_PORT=34781          # 推荐使用高位端口防扫描
    local TS_VERSION="v1.94.2"     # 必须锁定版本，防止官方源码变动导致魔改失败
    # ====================

    # 智能状态侦测
    if command -v derper >/dev/null 2>&1 || [[ -f "/usr/bin/derper" ]]; then
        is_update="true"
        info "检测到 Tailscale DERPer 已安装，准备拉取最新源码进行编译更新..."
        # 记录更新前服务是否处于运行状态
        if systemctl is-active --quiet derper; then
            was_running="true"
        fi
    else
        info "开始自编译安装 Tailscale DERPer (添加隐身防拨测补丁)..."
    fi

    # 1. 确保 Go 环境已就绪
    if ! command -v go >/dev/null 2>&1; then
        err "未检测到 Go 环境！请先在当前菜单选择【1. 安装 Go 环境】。"
        return 1
    fi
    [[ "$IS_CN_REGION" == "true" ]] && export GOPROXY=https://goproxy.cn,direct


    # 2. 智能配置 GitHub 镜像源与底层网络参数 (防 curl 16 报错)
    local repo_url="https://github.com/tailscale/tailscale.git"
    # 强行跳到系统的 /tmp 基础目录，使用 return 防止面板闪退
    local build_sandbox="/tmp/derp_build_$$"
    mkdir -p "$build_sandbox"
    
    # 使用 subshell () 执行或者在函数末尾显式切回原目录
    # 最优雅的方式是记录当前路径，结束后跳回：
    local original_dir=$(pwd)
    cd "$build_sandbox" || return 1
    
    # 使用 trap 保证哪怕中间报错 return 1 退出，也会执行环境复原
    trap 'cd "$original_dir"; rm -rf "$build_sandbox"' RETURN

    info "拉取 Tailscale $TS_VERSION 源码..."    

    # 调用高可用克隆函数，并传入深度和分支参数
    # 函数会自动确保父级目录存在并处理重试
    if ! git_clone_with_fallback "$build_sandbox/tailscale" "$repo_url" -b "$TS_VERSION" --depth 1; then
        err "Tailscale 源码准备失败，终止安装流程。"
        return 1
    fi
    
    # 只有当克隆 100% 成功后，才安全地进入目标源码文件夹内
    cd "$build_sandbox/tailscale/cmd/derper" || return 1

    info "执行源码魔改 (添加隐身防拨测功能)..."

    # --- 魔改 0: 修改 cert.go，去掉主机名与 ServerName 不匹配时的拦截
    # 这允许我们在客户端直接通过 IP 连接而不会因为证书 SNI 校验失败而断开
    # 使用 .* 泛匹配，无论官方的 if 条件写得多复杂，全部强制替换为 if false {
    #sed -i 's/if hi.ServerName != m.hostname.*/if false {/' cert.go

    # --- 魔改 1: 注入强制断开底层 TCP 连接的 closeConn 函数 ---
    sed -i '/func main()/i \
func closeConn(w http.ResponseWriter) {\
\tif hj, ok := w.(http.Hijacker); ok {\
\t\tif conn, _, err := hj.Hijack(); err == nil {\
\t\t\tconn.Close()\
\t\t}\
\t}\
}\
' derper.go

    # --- 魔改 2: 严格校验 /generate_204 路由 (仅放行官方 UA) ---
    # 双通道匹配：兼容老版本的 derphttp 和新版本的 derpserver 包名
    sed -i 's/mux.HandleFunc("\/generate_204", derphttp.ServeNoContent)/mux.HandleFunc("\/generate_204", func(w http.ResponseWriter, r *http.Request) {\n\t\tif r.UserAgent() == "Go-http-client\/1.1" {\n\t\t\tderphttp.ServeNoContent(w, r)\n\t\t\treturn\n\t\t}\n\t\tcloseConn(w)\n\t})/g' derper.go
    sed -i 's/mux.HandleFunc("\/generate_204", derpserver.ServeNoContent)/mux.HandleFunc("\/generate_204", func(w http.ResponseWriter, r *http.Request) {\n\t\tif r.UserAgent() == "Go-http-client\/1.1" {\n\t\t\tderpserver.ServeNoContent(w, r)\n\t\t\treturn\n\t\t}\n\t\tcloseConn(w)\n\t})/g' derper.go

    # --- 魔改 3: 掐断根路径 / (禁止浏览器访问返回 DERP) ---
    # 防患于未然：同时兼容 fmt.Fprintf 和 io.WriteString
    sed -i 's/fmt.Fprintf(w, "DERP\\n")/closeConn(w)/g' derper.go
    sed -i 's/io.WriteString(w, "DERP\\n")/closeConn(w)/g' derper.go

    # --- 魔改 4: 严格校验核心握手路径 /derp (无 Upgrade 头直接阻断) ---
    # 双通道匹配：同样兼容 derphttp 和 derpserver 的 Handler 包装，并避免大小写导致的误封锁
    sed -i 's/mux.Handle("\/derp", derphttp.Handler(s))/mux.HandleFunc("\/derp", func(w http.ResponseWriter, r *http.Request) {\n\t\tup := r.Header.Get("Upgrade")\n\t\tif up != "derp" \&\& up != "DERP" {\n\t\t\tcloseConn(w)\n\t\t\treturn\n\t\t}\n\t\tderphttp.Handler(s).ServeHTTP(w, r)\n\t})/g' derper.go
    sed -i 's/mux.Handle("\/derp", derpserver.Handler(s))/mux.HandleFunc("\/derp", func(w http.ResponseWriter, r *http.Request) {\n\t\tup := r.Header.Get("Upgrade")\n\t\tif up != "derp" \&\& up != "DERP" {\n\t\t\tcloseConn(w)\n\t\t\treturn\n\t\t}\n\t\tderpserver.Handler(s).ServeHTTP(w, r)\n\t})/g' derper.go
    
    # 防漏校验机制
    # 如果未来官方大改了源码导致 sed 替换失败，这里会立刻拦截，防止编译出裸奔节点
    #if ! grep -q "closeConn(w)" derper.go || ! grep -q "if false {" cert.go; then
    if ! grep -q "closeConn(w)" derper.go; then
        err "源码魔改失败！你当前指定的 Tailscale 版本 ($TS_VERSION) 源码结构已改变，隐身补丁无法打入。请降级版本或手动查阅源码更新 sed 命令。"
        return 1
    fi
    info "代码魔改校验通过！隐身补丁已成功注入。"
    
    info "开始编译 DERPer (此过程可能耗时几分钟并消耗较多内存，请耐心等待)..."
    # 编译到独立的临时文件，防止影响当前运行的服务
    go build -o /tmp/derper_new
    
    if [[ ! -f "/tmp/derper_new" ]]; then
        err "DERPer 编译失败！请检查系统环境或源码状态。"
        return 1
    fi

    info "编译成功，开始规范化部署..."
    systemctl stop derper >/dev/null 2>&1
    mv /tmp/derper_new /usr/bin/derper
    chmod +x /usr/bin/derper
    
    info "探测服务器双栈公网 IP..."
        
    # 严格轮询获取 IPv4 (加 -4 参数，并通过正则校验)
    local server_ipv4=""
    for api in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
        server_ipv4=$(curl -s4 --connect-timeout 3 "$api")
        if [[ "$server_ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        server_ipv4=""
    done

    # 通过本地网卡直接获取公网 IPv6 (排除 Tailscale 虚拟内网及本地链路地址)
    local server_ipv6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | grep -v -E "^(fd|fc)" | head -n 1 || true)

    if [[ -z "$server_ipv4" ]]; then
        warn "未能自动检测到公网 IPv4，将回退到 127.0.0.1，请随后手动修改证书和配置！"
        server_ipv4="127.0.0.1"
    fi

    info "✅ 绑定 IPv4: ${server_ipv4}"
    [[ -n "$server_ipv6" ]] && info "✅ 绑定 IPv6: ${server_ipv6}" || info "⚠️ 未检测到可用 IPv6 路由，仅配置单栈。"
    
    # 只有全新安装时，才生成自签证书和服务文件，执行精准双栈 IP 探测
    if [[ "$is_update" == "false" ]]; then
        info "生成带 IP SAN 的自签证书与身份密钥..."
        local derp_dir="/opt/derper"
        local cert_dir="${derp_dir}/certs"
        mkdir -p "$cert_dir"

        # 动态拼接证书 SAN 扩展，让证书同时被 IPv4 和 IPv6 信任
        local san_ext="subjectAltName=IP:${server_ipv4}"
        if [[ -n "$server_ipv6" ]]; then
            san_ext="${san_ext},IP:${server_ipv6}"
        fi

        # 注意：文件命名依然使用 ipv4.key，因为 systemd 中 -hostname 传入的是 ipv4
        openssl req -x509 -newkey ed25519 -days 3650 -nodes \
            -keyout "${cert_dir}/${server_ipv4}.key" -out "${cert_dir}/${server_ipv4}.crt" \
            -subj "/CN=${server_ipv4}" -addext "${san_ext}" >/dev/null 2>&1

        cat > /etc/systemd/system/derper.service << EOF
[Unit]
Description=Tailscale DERP Relay Server (Stealth Mode)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/derper -a :${DERP_PORT} -hostname ${server_ipv4} -certmode manual -certdir ${cert_dir} -stun -http-port -1 -verify-clients=false
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        
        # 放行防火墙
        ufw allow ${DERP_PORT}/tcp comment 'DERP Relay Stealth' >/dev/null 2>&1
        ufw allow 3478/udp comment 'DERP STUN' >/dev/null 2>&1

        info "DERPer 隐身版部署成功！"
        info "1. 二进制路径: /usr/bin/derper"
        info "2. 证书路径: ${cert_dir}"
        info "3. 中继端口: TCP ${DERP_PORT} | STUN: UDP 3478"
        warn "服务已生成但未开启。请检查配置后执行: systemctl start derper"
    else
        info "DERPer 二进制文件更新成功！您的自签证书和服务配置已安全保留。"
        # 智能拉起：如果更新前它是运行的，更新后自动拉起；如果是关闭的，保持关闭。
        if [[ "$was_running" == "true" ]]; then
            systemctl start derper
            info "检测到更新前服务处于运行状态，已自动重启 DERPer 服务。"
        fi
    fi
            
    # 动态生成带有（或不带有） IPv6 字段的 JSON
    local ipv6_json=""
    if [[ -n "$server_ipv6" ]]; then
        ipv6_json=",\n                    \"IPv6\": \"${server_ipv6}\""
    fi

    # 给用户打印出控制台配置代码，方便复制
    echo -e "\n${YELLOW}================================================================${NC}"
    echo -e "${GREEN}请自行修改以下配置后加入到 Tailscale 控制台的 Access Controls (ACLs) 中：${NC}"
    echo -e "${YELLOW}
\"derpMap\": {
    \"OmitDefaultRegions\": false,
    \"Regions\": {
        \"901\": {
            \"RegionID\": 901,
            \"RegionCode\": \"MyDerp\",
            \"RegionName\": \"My Stealth Node\",
            \"Nodes\": [
                {
                    \"Name\": \"1\",
                    \"RegionID\": 901,
                    \"Hostname\": \"${server_ipv4}\"
                    \"IPv4\": \"${server_ipv4}\"${ipv6_json},
                    \"DERPPort\": ${DERP_PORT},
                    \"InsecureForTests\": true
                    \\\"STUNOnly\": true
                }
            ]
        }
    }
}${NC}"
    echo -e "${GREEN}若要 DERPer 仅辅助打洞而不中继流量，请在服务器手动禁用 DERP 公网端口并在控制台取消 STUNOnly 注释${NC}"
    echo -e "${YELLOW}================================================================${NC}\n"
}
uninstall_derper() {
    info "准备卸载 Tailscale DERPer..."
    
    systemctl stop derper >/dev/null 2>&1
    systemctl disable derper >/dev/null 2>&1
    rm -f /etc/systemd/system/derper.service
    systemctl daemon-reload

    info "清理残留文件..."
    rm -f /usr/bin/derper
    rm -rf /opt/derper
    rm -rf /tmp/derp_build

    # 检查状态
    if command -v derper >/dev/null 2>&1; then
        warn "DERPer 仍有残留，请手动清理 /usr/bin/derper。"
    else
        info "DERPer 已卸载完毕。"
    fi
}

# =========================================================
# TUI 交互式菜单系统
# =========================================================

# 服务状态检测 (精准适配特殊安装路径)
get_status() {
    local cmd=$1
    # 智能处理：提取去掉 "-core" 后缀的名字，用于匹配如 /opt/easytier 这样的目录
    local dir_name="${cmd%-core}" 

    # 依次检查：环境变量、标准 bin 目录、带/不带 core 的 opt 目录
    if command -v "$cmd" >/dev/null 2>&1 || \
       [[ -f "/usr/bin/$cmd" ]] || \
       [[ -f "/usr/local/bin/$cmd" ]] || \
       [[ -f "/opt/$cmd/bin/$cmd" ]] || \
       [[ -f "/opt/$cmd/$cmd" ]] || \
       [[ -f "/opt/$dir_name/bin/$cmd" ]] || \
       [[ -f "/opt/$dir_name/$cmd" ]]; then
        echo -e "${GREEN}[已安装]${NC}"
    else
        echo -e "${YELLOW}[未安装]${NC}"
    fi
}

# 组合状态检测 (支持传入多个命令名，只要命中一个即视为已安装)
get_combined_status() {
    for cmd in "$@"; do
        local dir_name="${cmd%-core}" 
        
        # 依次检查：环境变量、标准 bin 目录、带/不带 core 的 opt 目录
        if command -v "$cmd" >/dev/null 2>&1 || \
           [[ -f "/usr/bin/$cmd" ]] || \
           [[ -f "/usr/local/bin/$cmd" ]] || \
           [[ -f "/opt/$cmd/bin/$cmd" ]] || \
           [[ -f "/opt/$cmd/$cmd" ]] || \
           [[ -f "/opt/$dir_name/bin/$cmd" ]] || \
           [[ -f "/opt/$dir_name/$cmd" ]]; then
            
            # 只要找到一个，立刻输出绿字并中断函数返回成功
            echo -e "${GREEN}[已安装]${NC}"
            return 0
        fi
    done
    # 如果整个循环跑完都没找到任何一个，才输出黄字未安装
    echo -e "${YELLOW}[未安装]${NC}"
}

handle_submenu() {
    local app_name=${1:-}
    local install_func=${2:-}
    local uninstall_func=${3:-}
    local extra_name=${4:-}
    local extra_func=${5:-}
    
    while true; do
        echo -e "\n--- 【 $app_name 管理 】 ---"
        echo "1. 安装或更新"
        echo "2. 卸载"
        # 如果传入了额外的菜单名，就显示第 3 个选项
        if [[ -n "$extra_name" ]]; then
            echo "3. $extra_name"
        fi
        echo "0. 返回上级菜单"
        read -p "请输入对应数字: " sub_choice
        case $sub_choice in
            1) $install_func; pause; break;;
            2) $uninstall_func; pause; break;;
            3) 
                if [[ -n "$extra_func" ]]; then 
                    $extra_func; pause; break; 
                else 
                    echo "无效选项，请重新输入。"; 
                fi
                ;;
            0) break;;
            *) echo "无效选项，请重新输入。";;
        esac
    done
}

handle_warp_submenu() {
    while true; do
        hash -r
        clear

        echo -e "=============================================="
        echo -e "          🚀 WARP & Usque 组件管理"
        echo -e "=============================================="
        echo -e " 1. 安装/更新 CF WARP CLI     $(get_status warp-cli)"
        echo -e " 2. 卸载 CF WARP CLI"        
        echo -e " ---------------------------------------------"
        echo -e " 3. 安装/更新 Usque (MASQUE)  $(get_status usque)"
        echo -e " 4. 卸载 Usque"
        echo -e " ---------------------------------------------"
        echo -e " 5. 生成 Xray WireGuard 出站 JSON"
        echo -e " ---------------------------------------------"
        echo " 0. 返回主菜单"
        echo -e "=============================================="
        read -p "请输入对应的数字选项: " sub_choice

        case $sub_choice in
            1) install_warp; pause;;
            2) uninstall_warp; pause;;
            3) install_usque; pause;;
            4) uninstall_usque; pause;;
            5) generate_warp_xray; pause;;
            0) return 0;;
            *) echo "无效选项，请重新输入。"; sleep 1;;
        esac
    done
}

handle_go_submenu() {
    while true; do
        hash -r
        clear

        echo -e "\n=============================================="
        echo -e "      【 GoLang 环境与编译组件管理 】"
        echo -e "=============================================="
        
        # 动态判定：如果 Go 安装了，显示高级选项；没装，只显示安装
        if command -v go >/dev/null 2>&1 || [[ -d "/usr/local/go" ]]; then
            echo " 1. 修复/更新 Go 环境"
            echo -e " ---------------------------------------------"
            echo -e " 2. 自定义 Caddy    $(get_status caddy)"
            echo -e " 3. Tailscale DERP  $(get_status derper)"
            echo " ---------------------------------------------"
            echo " 4. 卸载 Go 环境"
            echo -e " ---------------------------------------------"
            echo " 0. 返回主菜单"
            echo -e "=============================================="
            read -p "请输入对应数字: " sub_choice
            
            case $sub_choice in
                1) install_go; pause;;
                2) handle_submenu "自定义 Caddy" install_caddy uninstall_caddy;;
                3) handle_submenu "Tailscale DERP" install_derper uninstall_derper;;
                4) uninstall_go; pause; break;; # 卸载 Go 后退回主菜单以刷新全局状态
                0) break;;
                *) echo "无效选项，请重新输入。"; sleep 1;;
            esac
        else
            echo " 1. 安装 Go 环境 (用于编译自定义 Go 应用)"
            echo " 0. 返回主菜单"
            echo -e "=============================================="
            read -p "请输入对应数字: " sub_choice
            
            case $sub_choice in
                1) install_go; pause;;
                0) break;;
                *) echo "无效选项，请重新输入。"; sleep 1;;
            esac
        fi
    done
}

show_main_menu() {
    while true; do
        # 强制清空 Bash 命令路径缓存，解决状态残留问题
        hash -r 
        clear
        # 判断当前的持久化网络环境以供显示
        local net_status_text=""
        if [[ "$IS_CN_REGION" == "true" ]]; then
            net_status_text="${YELLOW}中国大陆 (镜像加速)${NC}"
        else
            net_status_text="${GREEN}海外地区 (官网直连)${NC}"
        fi

        echo -e "=============================================="
        echo -e "      Debian 系统调优与服务部署管理面板"
        echo -e "        网络环境: ${net_status_text}"
        echo -e "=============================================="
        echo " 1. 一键系统基础优化 (可重复执行)"
        echo -e " 2. 切换 IP 转发状态 当前: $(get_ip_forward_status)"
        echo -e "---------------------------------------------"
        echo -e " 3. Xray Core       $(get_status xray)"
        echo -e " 4. Easytier        $(get_status easytier-core)"
        echo -e " 5. Tailscale       $(get_status tailscale)"
        echo -e " 6. CF WARP         $(get_combined_status warp-cli usque)"
        echo -e " 7. Docker 环境     $(get_status docker)"
        echo -e " ---------------------------------------------"
        echo -e " 8. GoLang 环境     $(get_status go)"
        echo -e " ---------------------------------------------"
        echo " 0. 退出脚本"
        echo -e "=============================================="
        read -p "请输入对应的数字选项: " choice
        
        case $choice in
            1) run_base_optimization; pause;;
            2) toggle_ip_forwarding; pause;;
            3) handle_submenu "Xray Core" install_xray uninstall_xray;;
            4) handle_submenu "Easytier" install_easytier uninstall_easytier;;
            5) handle_submenu "Tailscale" install_tailscale uninstall_tailscale;;
            6) handle_warp_submenu;;
            7) handle_submenu "Docker & Compose" install_docker uninstall_docker;;
            8) handle_go_submenu;;
            0) echo "退出脚本，下次见 :)"; exit 0;;
            *) echo "无效选项，请重新输入。"; sleep 1;;
        esac
    done
}

# =========================================================
# 脚本主入口点
# =========================================================

# 必须先执行网络探测加载（函数内部会自动判断是否需要真实发起请求）
global_netcheck

# 修改：不再判断文件是否存在，而是判断里面的变量
if [[ "$BASE_OPTIMIZED" != "true" ]]; then
    echo -e "${YELLOW}检测到这是第一次运行此脚本，开始初始安全校验与基础设置...${NC}"
    check_ssh_security
    run_base_optimization
    
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}初次基础系统优化全部完成！(默认已关闭 IP 转发)${NC}"
    echo -e "如果后续你需要搭建代理/组网，请在菜单中按 7 开启 IP 转发。"
    echo -e "请务必手动执行: ${YELLOW}ufw show added${NC} 确认放行端口无误，再执行 ${YELLOW}ufw enable${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo -e "即将进入管理面板..."
    sleep 4
    show_main_menu
else
    show_main_menu
fi
