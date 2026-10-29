#!/bin/sh
###############################################################################
# 深圳信息职业技术大学 校园网 ePortal 自动认证 (OpenWrt / ImmortalWrt 版)
#
# 依赖（OpenWrt 自带或可 apk/opkg 安装）：
#   - uclient-fetch   (OpenWrt 默认, 提供 wget 兼容)
#   - openssl-util    (apk add openssl-util)  —— 用于 AES-128-ECB 加密
#   - base64          (busybox 自带)
#
# 用法：
#   /usr/bin/suit-portal.sh                 守护进程调用：先查在线，在线就跳过
#   /usr/bin/suit-portal.sh --check         只报当前状态（在线 / 离线 / WAN IP）
#   /usr/bin/suit-portal.sh --auth          手动认证（LuCI「立即认证」按钮）：
#                                           在线则跳过并说明，离线才走完整流程
#   /usr/bin/suit-portal.sh --force-auth    真·强制：不查在线，直接跑完整认证
#                                           （对应 LuCI「强制重新认证」按钮）
#   /usr/bin/suit-portal.sh --probe         排障：打印探测地址的原始响应
#   /usr/bin/suit-portal.sh --trace         排障：逐阶段打印原始 body / 响应头
#   /usr/bin/suit-portal.sh --wifi-resume   逃生口：立即恢复全部无线（无视开关与状态）
#   /usr/bin/suit-portal.sh --wifi-pause    排障：立即暂停无线
#   /etc/init.d/suit-portal start|stop|restart|enable|disable|status
#
# 断网暂停无线（可选，默认关闭）：
#   开启后，检测到离线就关掉无线射频，认证成功后自动恢复。
#   频段粒度由 wifi_pause_2g / wifi_pause_5g 控制（默认两个都关 = 关掉全部无线）。
#   在 LuCI「服务 -> SUIT 校园网自动认证」里勾选，或：
#     uci set suit-portal.main.wifi_pause='1' && uci commit suit-portal
#
# 认证流程（依 HAR 实测还原）：
#   [0] 触发网关拦截 -> 捕获 eportal 入口参数 -> 换到 portal-main, 得 sessionId
#   [1] GET  /cas-sso/login -> 解析 login-page-flowkey(execution) 与 login-croypto(AES密钥)
#   [2] POST /cas-sso/login -> AES-128-ECB/PKCS7 加密密码, 提交, 得 CAS ticket
#   [3] POST /eportal/workFlow/getCurrentNode  -> 推进到 serviceSelection
#   [4] POST /eportal/network/serviceSelection -> 查询运营商
#   [5] POST /eportal/network/serviceLogin     -> 选定运营商, authResult=success 即成功
###############################################################################

#------------------------------------------------------------------------------
# 配置区
#------------------------------------------------------------------------------
PORTAL_HOST="${PORTAL_HOST:-10.10.16.56}"
PORTAL_USER="${PORTAL_USER:-}"
PORTAL_PASS="${PORTAL_PASS:-}"
PORTAL_SERVICE="${PORTAL_SERVICE:-电信宽带}"

# 网关接口（认证出口，通常是 br-lan 或物理 WAN 口）
AUTH_IFACE="${AUTH_IFACE:-}"

# ---- 断网时暂停无线 ----
#
# 【做什么】检测到离线（未认证）时，关掉**全部**无线射频（wifi down）；
#   认证成功后自动恢复（wifi up）。
#
# 【为什么】断网期间设备还连着 WiFi 却上不了网，体验很差 ——
#   应用卡在重试、系统误判"有网"、用户看不出到底断没断。
#   把射频关掉，"没网"这件事立刻可见；认证一成功 WiFi 就回来。
#
# 【默认关闭】0 = 不启用。在 LuCI「服务 -> SUIT 校园网自动认证」里勾选启用，
#   或 `uci set suit-portal.main.wifi_pause='1' && uci commit suit-portal`。
#
# ⚠️ 启用前提：路由器 WAN 必须是**有线接入**（DHCP / PPPoE）。
#    如果 WAN 走的是无线中继（sta 模式），关射频会把 WAN 一起断掉，
#    认证永远不可能成功 —— 那种拓扑下不要开这个开关。
# ⚠️ 关闭期间**所有**设备都搜不到这台路由器的 WiFi（按设计，一直关到认证成功）。
#    请确保你能用**网线**进 LuCI，否则认证持续失败时会被锁在外面。
WIFI_PAUSE="${WIFI_PAUSE:-0}"

# 断网时具体关哪些频段（仅在 WIFI_PAUSE=1 时生效）。
#   1 = 该频段会被关掉，0 = 保留不动。默认两个都关 —— 也就是「关掉全部无线」。
#   例：只想关 5G、给智能家居留 2.4G -> wifi_pause_2g='0' wifi_pause_5g='1'
WIFI_PAUSE_2G="${WIFI_PAUSE_2G:-1}"
WIFI_PAUSE_5G="${WIFI_PAUSE_5G:-1}"

# 无线暂停标志文件：内容是**本次被关掉的 radio 名**（每行一个，如 radio0/radio1）。
#
# 【为什么记列表而不是只记"关过"】频段开关是随时可改的 —— 用户可能在无线
#   已经关着的期间把 5G 关掉、把 2.4G 打开。恢复时必须按**当初实际关掉的那批**
#   来开，而不是按当前开关重新算，否则会出现「关了 radio1、却只把 radio0 打开」，
#   radio1 永远回不来。
#
# 【为什么放 /tmp 而不是 $WORK_DIR】do_auth 开头会 `rm -rf "$WORK_DIR"`，
#   标志放里面会被自己清掉，导致「关了就再也开不回来」。
#   /tmp 是 tmpfs，重启即清空 —— 而重启后 netifd 本来就会重新拉起无线，
#   所以不会有「标志丢了但无线还关着」的残留。
WIFI_FLAG="${WIFI_FLAG:-/tmp/.suit-portal-wifi-paused}"

# HTTP 后端：留空则自动探测 curl > uclient-fetch > wget
HTTP_BACKEND="${HTTP_BACKEND:-}"

# 触发拦截用的探测地址。
#
# 【2026-10-04 修正】原来只用纯 IP（123.123.123.123 等），理由是"本网络 DNS 被封"。
#   实测该理由已不成立（nslookup www.baidu.com 正常解析），而且**纯 IP 反而会失败**：
#     域名探测  http://connect.rom.miui.com/generate_204  -> rc=0  成功
#     域名探测  http://www.baidu.com/                     -> rc=0  成功（29506 字节真实页面）
#     纯 IP 探测 http://123.123.123.123/                  -> rc=4  "Failed to send request:
#     纯 IP 探测 http://114.114.114.114/                              Operation not permitted"
#     纯 IP 探测 http://1.1.1.1/                           -> rc=4  同上
#   所以域名探测在前，纯 IP 仅作兜底。
#
# 【2026-10-10 再修正】把两个纯 IP 兜底地址**删掉**了 —— 实测它们不是"立即失败"，
#   而是**各白等满 6 秒超时**才返回 rc=4：
#     域名 connect.rom.miui.com  -> 0 秒  rc=0
#     域名 wifi.vivo.com.cn      -> 0 秒  rc=0
#     纯 IP 123.123.123.123      -> 6 秒  rc=4（EPERM）
#     纯 IP 114.114.114.114      -> 6 秒  rc=4（EPERM）
#   两个 IP 加起来**每轮认证白耗 12 秒**（实测 Step 0b 总耗时正好 12 秒），
#   而它们从来没有成功过一次 —— 纯粹是负担。删掉后整轮认证 22 秒 -> 10 秒。
PROBE_URLS="${PROBE_URLS:-http://connect.rom.miui.com/generate_204 http://wifi.vivo.com.cn/generate_204}"

# 在线检测地址（域名优先，见上面的实测结论）
ONLINE_CHECK_URL="${ONLINE_CHECK_URL:-http://connect.rom.miui.com/generate_204}"

# 在线检测备用地址（主地址不通时依次尝试）
ONLINE_CHECK_URLS="${ONLINE_CHECK_URLS:-$ONLINE_CHECK_URL http://wifi.vivo.com.cn/generate_204 http://www.baidu.com/}"

# ePortal 入口 URL（兜底用）
#
# 【为什么需要】AC 只在未认证设备**首次**访问外网时劫持并下发这个入口；
#   之后它若认为设备已认证，就直接 DROP TCP，不再劫持，探测就永远拿不到入口。
#   而入口里的 wlanuserip / mac / nasip / wlanacname 等对本机是**固定值**，
#   可以复用 —— 实测复用后仍能换取全新的 sessionId。
#
# 【怎么拿到】在能正常上网时跑一次本脚本，日志里会打印：
#     入口: http://10.10.16.56/eportal/index.jsp?wlanuserip=xxxx&...
#   把那整条 URL 填到这里即可（引号包裹，因为含 & ）。
PORTAL_ENTRY_URL="${PORTAL_ENTRY_URL:-}"

WORK_DIR="${WORK_DIR:-/tmp/suit-portal}"
LOG_FILE="${LOG_FILE:-/var/log/suit-portal.log}"
MAX_LOG_SIZE=65536

# nc 保活秒数：OpenWrt 的 busybox nc 精简版在 stdin EOF 时立即断连，
# 必须用 sleep 把 stdin 多撑一会儿，等 HTTP 响应收完。默认 2 秒足够。
NC_HOLD="${NC_HOLD:-2}"

# 【实机踩坑】nc 的超时上限（秒）
#
# busybox 精简版 nc **没有 -w 选项**，而这台机器上连 `timeout` 命令都没有
# （`command -v timeout` 返回空）。实测连一个不可达地址时，**裸 nc 会挂 135 秒**
# 才放弃 —— 后果很严重：
#   · 开机 / 刚插网线时 WAN 还没起来，第一轮要挂 4 分钟才出结果
#   · 学校服务器不可达时，"5 秒快速重试"实际退化成 135+5 秒一轮
# 所以这里用「后台 + kill -0 轮询 + kill -9」自己实现超时。
# 10 秒足够正常认证走完（实机 POST 全程 2~4 秒），又不至于卡死整轮。
NC_TIMEOUT="${NC_TIMEOUT:-10}"

# uclient-fetch / wget 的连接超时（秒）。探测地址逐个试，太长会拖垮整轮。
HTTP_TIMEOUT="${HTTP_TIMEOUT:-6}"

PKG_DIR="$(dirname "$0")"
CONF_FILE="/etc/portal-auth.conf"

# UCI 配置（OpenWrt 包安装后使用；见 load_conf 的优先级说明）
UCI_CONF="/etc/config/suit-portal"
UCI_PKG="suit-portal"

# ---- 包环境强制项 ----
#
# 【为什么需要】旧版 /etc/portal-auth.conf（手工部署那套）里也定义了
#   LOG_FILE / WORK_DIR / PROBE_URLS / ONLINE_CHECK_URL。load_conf 会 source 它，
#   于是这些"手工时代的旧值"会盖掉包自己的新默认值。实测后果：
#     · 日志被写回 /var/log/portal-auth.log（LuCI 页面读不到）
#     · 探测地址退回纯 IP 那套，而纯 IP 在本网络会 EPERM -> 探测永远失败
#   所以 source 完旧 conf 之后必须把这些"属于运行环境、不属于用户配置"的项再钉回来。
PKG_LOG_FILE="${ENV_LOG_FILE:-/var/log/suit-portal.log}"
PKG_WORK_DIR="${ENV_WORK_DIR:-/tmp/suit-portal}"
PKG_PROBE_URLS="${ENV_PROBE_URLS:-http://connect.rom.miui.com/generate_204 http://wifi.vivo.com.cn/generate_204}"

#------------------------------------------------------------------------------
# 日志
#------------------------------------------------------------------------------
log() {
    _msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$_msg"
    # 日志轮转
    if [ -f "$LOG_FILE" ]; then
        _sz=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
        [ "$_sz" -gt "$MAX_LOG_SIZE" ] && tail -c 16384 "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    echo "$_msg" >>"$LOG_FILE" 2>/dev/null
}

die() { log "错误: $*"; exit 1; }

#------------------------------------------------------------------------------
# 去除字符串首尾空白（空格 / Tab / CR / LF）
#
# 【为什么需要】实测发现配置文件里若有尾随空格，PORTAL_USER 会变成
#   "<账号> " -> urlencode 后成 "<账号>%20" -> 服务端认不出账号，
#   表现为「登录后重新返回登录页」（body 又变回 3 万多字节的 HTML）。
# 因此所有从配置读入的敏感字段都必须 trim。
#------------------------------------------------------------------------------
trim() {
    _t="$1"
    # 去尾部：空格/制表/回车/换行
    _t=$(printf '%s' "$_t" | sed -e 's/[[:space:]]*$//')
    # 去头部
    _t=$(printf '%s' "$_t" | sed -e 's/^[[:space:]]*//')
    printf '%s' "$_t"
}

#------------------------------------------------------------------------------
# 加载配置文件
#------------------------------------------------------------------------------
load_conf() {
    # ---- 优先级：环境变量 > UCI > 旧版 shell 配置 > 脚本内置默认值 ----
    #
    # 1) 旧版 shell 配置（兼容手工部署过的机器：脚本 + /etc/portal-auth.conf 那套）
    #
    # 【2026-10-04 修复 · 实机踩坑，很关键】
    #   原来这里是无条件 `. "$CONF_FILE"`，再用下面的 UCI「非空才覆盖」。
    #   后果：机器上只要残留 /etc/portal-auth.conf（内含旧账号密码），
    #   用户在 LuCI 里把账号密码清空后，PORTAL_USER/PORTAL_PASS 会被旧文件
    #   重新填回来 —— 现象是「配置明明清空了，脚本还在用旧账号认证」，
    #   而且会把使用者不该看到的凭据悄悄带进运行态。
    #   现在改成：**只有不存在 UCI 配置时**才读旧文件（纯手工部署的机器走这条），
    #   一旦有 /etc/config/suit-portal，UCI 就是唯一来源，清空即真清空。
    #   旧配置的迁移由 /etc/uci-defaults/99-suit-portal 在安装时完成，不会丢。
    if [ ! -f "$UCI_CONF" ] && [ -f "$CONF_FILE" ]; then
        . "$CONF_FILE" 2>/dev/null
    fi

    # 2) UCI 覆盖（OpenWrt 包安装后的正规配置位置，LuCI 页面写的就是这里）
    if command -v uci >/dev/null 2>&1 && [ -f "$UCI_CONF" ]; then
        _u=$(uci -q get "$UCI_PKG.main.username" 2>/dev/null) && [ -n "$_u" ] && PORTAL_USER="$_u"
        _u=$(uci -q get "$UCI_PKG.main.password" 2>/dev/null) && [ -n "$_u" ] && PORTAL_PASS="$_u"
        _u=$(uci -q get "$UCI_PKG.main.service"  2>/dev/null) && [ -n "$_u" ] && PORTAL_SERVICE="$_u"
        _u=$(uci -q get "$UCI_PKG.main.portal_host" 2>/dev/null) && [ -n "$_u" ] && PORTAL_HOST="$_u"
        _u=$(uci -q get "$UCI_PKG.main.entry_url" 2>/dev/null) && [ -n "$_u" ] && PORTAL_ENTRY_URL="$_u"
        _u=$(uci -q get "$UCI_PKG.main.online_check_urls" 2>/dev/null) && [ -n "$_u" ] && ONLINE_CHECK_URLS="$_u"
        _u=$(uci -q get "$UCI_PKG.main.wifi_pause" 2>/dev/null) && [ -n "$_u" ] && WIFI_PAUSE="$_u"
        _u=$(uci -q get "$UCI_PKG.main.wifi_pause_2g" 2>/dev/null) && [ -n "$_u" ] && WIFI_PAUSE_2G="$_u"
        _u=$(uci -q get "$UCI_PKG.main.wifi_pause_5g" 2>/dev/null) && [ -n "$_u" ] && WIFI_PAUSE_5G="$_u"
    fi

    # 3) 环境变量最高（便于测试时临时覆盖）
    [ -n "$ENV_PORTAL_USER" ] && PORTAL_USER="$ENV_PORTAL_USER"
    [ -n "$ENV_PORTAL_PASS" ] && PORTAL_PASS="$ENV_PORTAL_PASS"
    [ -n "$ENV_WIFI_PAUSE" ] && WIFI_PAUSE="$ENV_WIFI_PAUSE"
    [ -n "$ENV_WIFI_PAUSE_2G" ] && WIFI_PAUSE_2G="$ENV_WIFI_PAUSE_2G"
    [ -n "$ENV_WIFI_PAUSE_5G" ] && WIFI_PAUSE_5G="$ENV_WIFI_PAUSE_5G"

    # 3.5) 包环境强制项（理由见文件头 PKG_* 的注释）
    LOG_FILE="$PKG_LOG_FILE"
    WORK_DIR="$PKG_WORK_DIR"
    PROBE_URLS="$PKG_PROBE_URLS"
    [ -z "$ONLINE_CHECK_URLS" ] && \
        ONLINE_CHECK_URLS="http://connect.rom.miui.com/generate_204 http://wifi.vivo.com.cn/generate_204 http://www.baidu.com/"

    # 统一 trim，防止配置里的首尾空白污染账号密码
    PORTAL_HOST=$(trim "$PORTAL_HOST")
    PORTAL_USER=$(trim "$PORTAL_USER")
    PORTAL_PASS=$(trim "$PORTAL_PASS")
    PORTAL_SERVICE=$(trim "$PORTAL_SERVICE")
    HTTP_BACKEND=$(trim "$HTTP_BACKEND")
}

#------------------------------------------------------------------------------
# HTTP 传输层适配
#
# 优先 curl（本机调试/带 curl 的固件），其次 uclient-fetch，最后 wget。
# 三者行为差异由本层抹平，上层只管调用 http_get / http_post。
#
# 关键约束（实测）：
#   - OpenWrt 的 uclient-fetch 不支持 -S（打印响应头）
#   - 本网关拦截返回的是 200 + 注入 JS，不是 302，所以不依赖响应头也能跑
#   - 但 eportal/index.jsp -> portal-main 这一步是真 302，需要拿到 Location
#     curl 用 -D 拿头；uclient-fetch 靠 stderr 的 "Redirected to ... on HOST"
#------------------------------------------------------------------------------
_HTTP_REDIRECT=""

#------------------------------------------------------------------------------
# Cookie 管理（自维护，不依赖后端的 cookie jar）
#
# 【为什么必须有】HAR 实测（entry 70 / 86）显示：CAS 的会话靠 cookie 名
#   `SESSION=<uuid>`（Path=/cas-sso/，HttpOnly）维持。浏览器最先访问
#   http://10.10.16.56/ 时服务端下发 SESSION，之后**所有** /cas-sso/ 请求
#   都带着它。POST 时若不带这个 cookie，CAS 会把它当成「一次全新的 GET 登录页」，
#   直接返回 33870+ 字节的登录页 HTML（HTTP 200），而**不是** 302 到 ticket。
#
#   实机现象与之完全吻合：POST 返回 33984 字节 HTML，rc=0，redirect 为空。
#   这就是 Step 2 一直拿不到 ticket 的根因。
#
# uclient-fetch / busybox wget 都没有 cookie jar，所以这里自己维护一个
#   「名字 -> 值」的平文件，每次响应后从 Set-Cookie 抽取并合并。
#------------------------------------------------------------------------------
COOKIE_FILE="$WORK_DIR/.cookies"

cookie_clear() {
    : >"$COOKIE_FILE" 2>/dev/null
}

# 从响应头文件里收集所有 Set-Cookie，合并进 COOKIE_FILE
# 处理规则：
#   - 取 "名字=值" 段（分号前）
#   - Max-Age=0 / 空值 视为删除
#   - 同名覆盖（浏览器行为：后写覆盖先写；同名多 cookie 场景此处简化为取最新）
cookie_absorb_file() {
    _hf="$1"
    [ -f "$_hf" ] || return 0
    # 抽取所有 Set-Cookie 行的第一段（到分号为止）
    sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*\([^;[:space:]]*\).*/\1/p' "$_hf" 2>/dev/null | \
    while IFS= read -r _pair; do
        [ -z "$_pair" ] && continue
        _name=$(printf '%s' "$_pair" | sed -n 's/^\([^=]*\)=.*/\1/p')
        _val=$(printf '%s' "$_pair" | sed -n 's/^[^=]*=\(.*\)$/\1/p')
        [ -z "$_name" ] && continue
        # 删除已有同名行
        [ -f "$COOKIE_FILE" ] && grep -v "^${_name}=" "$COOKIE_FILE" >"$COOKIE_FILE.n" 2>/dev/null
        [ -f "$COOKIE_FILE.n" ] && mv "$COOKIE_FILE.n" "$COOKIE_FILE" 2>/dev/null
        # 值非空才记录（空值 = 删除）
        if [ -n "$_val" ]; then
            printf '%s=%s\n' "$_name" "$_val" >>"$COOKIE_FILE"
        fi
    done
}

# 把 COOKIE_FILE 拼成 "a=1; b=2"
cookie_header() {
    [ -s "$COOKIE_FILE" ] || { printf ''; return 0; }
    awk 'BEGIN{ORS=""} { if (NR>1) printf "; "; printf "%s", $0 }' "$COOKIE_FILE" 2>/dev/null
}

#------------------------------------------------------------------------------
# 裸 HTTP（用 nc 实现）—— 唯一能可靠拿到「响应头 + Set-Cookie」的手段
#
# 【为什么需要】实机实测（ImmortalWrt 25.12.2）：
#   - uclient-fetch **没有** cookie 支持，也**没有**打印响应头的选项
#     （`-S` 报 unrecognized option；参考 uclient 源码，CLI 里根本没有这两项）
#   - busybox wget 同样没有 --save-cookies
#   - 而 CAS 认证**必须**带 `SESSION` cookie（见上方说明）
#
#   => 必须自己发裸 HTTP 请求，从原始响应里读 Set-Cookie。
#      `nc` 路由器一定有（实测 /usr/bin/nc）。
#
# 用法: nc_get <host> <port> <path_and_query> [extra_headers_file] <output_file>
#   输出文件内容 = 完整原始响应（响应头 + 空行 + body）
#------------------------------------------------------------------------------
nc_available() {
    command -v nc >/dev/null 2>&1
}

# 拆分 PORTAL_HOST 为 host / port
#   "10.10.16.56"        -> host=10.10.16.56  port=80
#   "127.0.0.1:18080"    -> host=127.0.0.1    port=18080
portal_host_only() {
    printf '%s' "$1" | sed -n 's/^\([^:]*\).*/\1/p'
}
portal_port_only() {
    _p=$(printf '%s' "$1" | sed -n 's/^[^:]*:\([0-9]*\).*/\1/p')
    [ -z "$_p" ] && _p=80
    printf '%s' "$_p"
}

#------------------------------------------------------------------------------
# 取当前 WAN 口的 IPv4 地址（不带掩码）
#
# 【为什么需要】校园网 AC 是按「终端 IP + MAC」定位会话的。路由器 WAN 走 DHCP，
#   续租/重连换网段是常态（实测同一台设备隔几天就会换到别的网段）。
#   入口 URL 里那份加密的 wlanuserip 一旦和当前 WAN IP 对不上，AC 就会拒认。
#   所以每次认证前都要拿它做一次一致性校验。
#------------------------------------------------------------------------------
wan_ip() {
    # 优先问 ubus（拿到的是接口真实地址），失败再退回 ip route
    _wi=""
    if command -v ubus >/dev/null 2>&1; then
        _wi=$(ubus call network.interface.wan status 2>/dev/null | \
              tr ',' '\n' | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1)
    fi
    if [ -z "$_wi" ]; then
        _wi=$(ip route show default 2>/dev/null | \
              sed -n 's/.*src[[:space:]]\([0-9.]*\).*/\1/p' | head -1)
    fi
    printf '%s' "$_wi"
}

#------------------------------------------------------------------------------
# 把新捕获的入口 URL 回写进配置文件
#
# 【为什么】入口 URL 里的 wlanuserip 是加密写死的。路由器 DHCP 换网段后，
#   旧入口就是废数据；只有 AC 还在劫持时探测才能拿到「带当前 IP」的新入口。
#   一旦拿到就存下来，这样下次 AC 停止劫持时，兜底用的也是**对的**那条。
#
# 【安全】只替换 PORTAL_ENTRY_URL= 这一行，配置文件其余内容原样保留。
#   sed 替换串里必须转义 &（URL 里全是 &），否则 & 会被展开成整个匹配串。
#------------------------------------------------------------------------------
save_entry_url() {
    _su_new="$1"
    [ -z "$_su_new" ] && return 0
    [ "$_su_new" = "$PORTAL_ENTRY_URL" ] && return 0

    # 优先写 UCI（OpenWrt 包环境；LuCI 页面上也能直接看到）
    if command -v uci >/dev/null 2>&1 && [ -f "$UCI_CONF" ]; then
        if uci -q set "$UCI_PKG.main.entry_url=$_su_new" 2>/dev/null && \
           uci -q commit "$UCI_PKG" 2>/dev/null; then
            log "      已回写 UCI entry_url（带当前 IP 的新入口）"
            return 0
        fi
    fi

    # 退回旧版 shell 配置
    [ -f "$CONF_FILE" ] || return 0
    [ -w "$CONF_FILE" ] || return 0
    grep -q '^[[:space:]]*PORTAL_ENTRY_URL=' "$CONF_FILE" 2>/dev/null || return 0

    _su_esc=$(printf '%s' "$_su_new" | sed 's/&/\\&/g')
    _su_tmp="$WORK_DIR/.conf.new"
    sed "s|^[[:space:]]*PORTAL_ENTRY_URL=.*|PORTAL_ENTRY_URL='$_su_esc'|" \
        "$CONF_FILE" >"$_su_tmp" 2>/dev/null || return 0
    [ -s "$_su_tmp" ] || return 0
    cat "$_su_tmp" >"$CONF_FILE" && \
        log "      已回写 PORTAL_ENTRY_URL（带当前 IP 的新入口）"
}

#------------------------------------------------------------------------------
# nc 超时包装
#
# 环境：busybox nc 无 -w，系统无 timeout 命令。裸 nc 遇不可达地址会挂 135 秒。
# 实现：请求先写进临时文件，再 `{ cat 请求; sleep NC_HOLD; } | nc ...` 放后台，
#      主进程每秒 kill -0 探活，超时就 kill -9。
#
# 用法: _nc_timed <outfile> <host> <port> <reqfile>
# 返回: 0 = nc 自己正常结束（此时再看 outfile 是否非空）；1 = 超时被杀
#------------------------------------------------------------------------------
_nc_timed() {
    _t_out="$1"; _t_host="$2"; _t_port="$3"; _t_req="$4"

    : >"$_t_out"
    { cat "$_t_req"; sleep "$NC_HOLD"; } |
        nc "$_t_host" "$_t_port" >"$_t_out" 2>/dev/null &
    _t_pid=$!

    _t_i=0
    while [ "$_t_i" -lt "$NC_TIMEOUT" ]; do
        kill -0 "$_t_pid" 2>/dev/null || break
        sleep 1
        _t_i=$((_t_i + 1))
    done

    if kill -0 "$_t_pid" 2>/dev/null; then
        # 还在跑 = 卡住了，杀掉。管道上游的 cat/sleep 会随管道关闭退出。
        kill -9 "$_t_pid" 2>/dev/null
        wait "$_t_pid" 2>/dev/null
        return 1
    fi
    wait "$_t_pid" 2>/dev/null
    return 0
}

nc_get() {
    _nchost="$1"; _ncport="$2"; _ncpath="$3"; _nchdr="$4"; _ncout="$5"

    # 【实机踩坑 · 必读】OpenWrt 的 /usr/bin/nc 是 busybox **精简版**：
    #   Usage: nc [IPADDR PORT]
    # 它**不支持任何选项**（-w / -v 全部报 usage 并退出 1），而且 stdin 一 EOF
    # 就立刻断开连接 —— 服务端响应还没回来就被切掉，表现为「0 字节 + 退出码 1」。
    # 所以必须：
    #   (1) 不加任何选项，只写 `nc HOST PORT`
    #   (2) 用 sleep 把 stdin 多保持一会儿，等响应收完
    # 实测 sleep 2 即可拿到完整响应头（357 字节的 302）。
    _ncreq="$WORK_DIR/.ncreq.get"
    {
        printf 'GET %s HTTP/1.0\r\n' "$_ncpath"
        printf 'Host: %s\r\n' "$_nchost"
        printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
        printf 'Accept: */*\r\n'
        printf 'Accept-Language: zh-CN,zh;q=0.9\r\n'
        printf 'Connection: close\r\n'
        if [ -f "$_nchdr" ]; then
            cat "$_nchdr"
        fi
        printf '\r\n'
    } >"$_ncreq"

    _nc_timed "$_ncout" "$_nchost" "$_ncport" "$_ncreq"
    _ncrc=$?
    [ "$_ncrc" -eq 0 ] && [ -s "$_ncout" ]
}

#------------------------------------------------------------------------------
# nc POST：发裸 HTTP POST 请求
#
# 【为什么需要】uclient-fetch 的 POST 在 OpenWrt 上有两个致命坑（实测）：
#   1) 跟随 302 时会把 POST 降级成 GET —— 导致服务端收到 GET，返回登录页 HTML
#      （实机现象：body 34016 字节 ≈ 登录页 33870 + 146）
#   2) 对 Content-Type / Origin 的处理不透明，且无法打印响应头拿 Set-Cookie
#   => POST 也走 nc 最稳妥。
#
# 用法: nc_post <host> <port> <path_and_query> <body_file> <ctype> [referer] <out_raw>
#------------------------------------------------------------------------------
nc_post() {
    _nphost="$1"; _ncport="$2"; _ncpath="$3"; _ncbody="$4"
    _ncctype="${5:-application/x-www-form-urlencoded}"; _ncref="$6"; _ncout="$7"

    _nclen=$(wc -c <"$_ncbody" 2>/dev/null || echo 0)
    _ck=$(cookie_header)

    _ncreq="$WORK_DIR/.ncreq.post"
    {
        printf 'POST %s HTTP/1.0\r\n' "$_ncpath"
        printf 'Host: %s\r\n' "$_nphost"
        printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
        printf 'Content-Type: %s\r\n' "$_ncctype"
        printf 'Content-Length: %s\r\n' "$_nclen"
        printf 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n'
        printf 'Accept-Language: zh-CN,zh;q=0.9\r\n'
        printf 'Origin: http://%s\r\n' "$_nphost"
        [ -n "$_ncref" ] && printf 'Referer: %s\r\n' "$_ncref"
        [ -n "$_ck" ] && printf 'Cookie: %s\r\n' "$_ck"
        printf 'Connection: close\r\n'
        printf '\r\n'
        cat "$_ncbody"
    } >"$_ncreq"

    _nc_timed "$_ncout" "$_nphost" "$_ncport" "$_ncreq"
    _nprc=$?
    [ "$_nprc" -eq 0 ] && [ -s "$_ncout" ]
}

# 从 nc 的原始响应里抽出 body（跳过响应头，直到空行）
nc_body() {
    _raw="$1"
    sed -n '/^\r*$/,$p' "$_raw" 2>/dev/null | sed '1d'
}

# 从 nc 原始响应里抽状态码
nc_status() {
    sed -n '1s/^HTTP\/[0-9.]*[[:space:]]*\([0-9]\{3\}\).*/\1/p' "$1" 2>/dev/null | head -1
}

# 从 nc 原始响应里抽 Location（可能有多行，取最后一个 = 最终跳转）
nc_location() {
    sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' "$1" 2>/dev/null | tail -1 | sed 's/[[:space:]]*$//'
}

detect_backend() {
    if [ -n "$HTTP_BACKEND" ] && command -v "$HTTP_BACKEND" >/dev/null 2>&1; then
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        HTTP_BACKEND="curl"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        HTTP_BACKEND="uclient-fetch"
    elif command -v wget >/dev/null 2>&1; then
        HTTP_BACKEND="wget"
    else
        HTTP_BACKEND=""
    fi
}

# 从 curl 的 -D 头文件里取 Location
_extract_loc_from_headers() {
    sed -n 's/^[Ll]ocation:[[:space:]]*\([^[:space:]\r]*\).*/\1/p' "$1" 2>/dev/null | head -1
}

# 从 uclient-fetch/wget 的 stderr 里取跳转目标
#
# 【关键】uclient-fetch 输出形如:
#   Redirected to /portal/portal-main?sessionId=xxx&...&accessTime=2026-09-28 12:42:17.951&... on 10.10.16.56
# 注意 URL 里可能含空格（accessTime 参数），所以不能简单用 [^[:space:]] 截断。
# 做法：取 "Redirected to " 之后、行尾 " on <ip>[:port]" 之前的全部内容。
_extract_loc_from_stderr() {
    sed -n 's/.*Redirected to \(.*\) on [0-9][0-9.]*\(:[0-9]*\)\{0,1\}$/\1/p' "$1" 2>/dev/null | head -1
}

#------------------------------------------------------------------------------
# http_get <url> [referer]
#   -> body 写入 $WORK_DIR/body
#   -> 原始输出写入 $WORK_DIR/err
#   -> 重定向目标 -> 全局 _HTTP_REDIRECT
#   -> 返回 0 成功 / 1 失败
#------------------------------------------------------------------------------
http_get() {
    _url="$1"; _referer="${2:-}"
    _HTTP_REDIRECT=""
    : >"$WORK_DIR/body"; : >"$WORK_DIR/err"
    _ck=$(cookie_header)

    case "$HTTP_BACKEND" in
        curl)
            curl -s -k --max-time 15 \
                ${_referer:+-e "$_referer"} \
                ${_ck:+-H "Cookie: $_ck"} \
                -D "$WORK_DIR/hdr" -o "$WORK_DIR/body" \
                "$_url" >"$WORK_DIR/err" 2>&1
            _rc=$?
            cookie_absorb_file "$WORK_DIR/hdr"
            _HTTP_REDIRECT=$(_extract_loc_from_headers "$WORK_DIR/hdr")
            ;;
        uclient-fetch)
            # 注意：不加 -q，因为 -q 可能连 "Redirected to" 一起吞掉
            # 加超时保护，避免实机上卡死
            # cookie 用 --header 手工带（本后端无 cookie jar）
            _to="${HTTP_TIMEOUT:-6}"
            uclient-fetch -O "$WORK_DIR/body" --timeout="$_to" \
                ${_referer:+--header="Referer: $_referer"} \
                ${_ck:+--header="Cookie: $_ck"} \
                "$_url" >"$WORK_DIR/err" 2>&1
            _rc=$?
            _HTTP_REDIRECT=$(_extract_loc_from_stderr "$WORK_DIR/err")
            [ -z "$_HTTP_REDIRECT" ] && \
                _HTTP_REDIRECT=$(sed -n 's/.*[Ll]ocation:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$WORK_DIR/err" | head -1)
            cookie_absorb_file "$WORK_DIR/err"
            ;;
        wget)
            wget -q -O "$WORK_DIR/body" \
                ${_ck:+--header="Cookie: $_ck"} \
                "$_url" >"$WORK_DIR/err" 2>&1
            _rc=$?
            _HTTP_REDIRECT=$(_extract_loc_from_stderr "$WORK_DIR/err")
            cookie_absorb_file "$WORK_DIR/err"
            ;;
        *)
            return 1 ;;
    esac

    [ $_rc -eq 0 ] && return 0
    [ -n "$_HTTP_REDIRECT" ] && return 0
    [ -s "$WORK_DIR/body" ] && return 0
    return 1
}

#------------------------------------------------------------------------------
# http_post <url> <body_file> <content_type> [referer]
#------------------------------------------------------------------------------
http_post() {
    _url="$1"; _bodyfile="$2"; _ctype="${3:-application/x-www-form-urlencoded}"; _referer="${4:-}"
    _HTTP_REDIRECT=""
    : >"$WORK_DIR/body"; : >"$WORK_DIR/err"
    _ck=$(cookie_header)

    case "$HTTP_BACKEND" in
        curl)
            curl -s -k --max-time 15 \
                -X POST \
                -H "Content-Type: $_ctype" \
                ${_referer:+-e "$_referer"} \
                ${_ck:+-H "Cookie: $_ck"} \
                --data-binary @"$_bodyfile" \
                -D "$WORK_DIR/hdr" -o "$WORK_DIR/body" \
                "$_url" >"$WORK_DIR/err" 2>&1
            _rc=$?
            cookie_absorb_file "$WORK_DIR/hdr"
            _HTTP_REDIRECT=$(_extract_loc_from_headers "$WORK_DIR/hdr")
            ;;
        uclient-fetch)
            _to="${HTTP_TIMEOUT:-6}"
            uclient-fetch -O "$WORK_DIR/body" --timeout="$_to" \
                --header="Content-Type: $_ctype" \
                ${_referer:+--header="Referer: $_referer"} \
                ${_ck:+--header="Cookie: $_ck"} \
                --post-file="$_bodyfile" \
                "$_url" >"$WORK_DIR/err" 2>&1
            _rc=$?
            _HTTP_REDIRECT=$(_extract_loc_from_stderr "$WORK_DIR/err")
            [ -z "$_HTTP_REDIRECT" ] && \
                _HTTP_REDIRECT=$(sed -n 's/.*[Ll]ocation:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$WORK_DIR/err" | head -1)
            cookie_absorb_file "$WORK_DIR/err"
            ;;
        wget)
            wget -q -O "$WORK_DIR/body" \
                --header="Content-Type: $_ctype" \
                ${_ck:+--header="Cookie: $_ck"} \
                --post-file="$_bodyfile" \
                "$_url" >"$WORK_DIR/err" 2>&1
            _rc=$?
            _HTTP_REDIRECT=$(_extract_loc_from_stderr "$WORK_DIR/err")
            cookie_absorb_file "$WORK_DIR/err"
            ;;
        *)
            return 1 ;;
    esac

    [ $_rc -eq 0 ] && return 0
    [ -n "$_HTTP_REDIRECT" ] && return 0
    [ -s "$WORK_DIR/body" ] && return 0
    return 1
}

# 把可能是相对路径的重定向补全为绝对 URL
abs_url() {
    _u="$1"
    case "$_u" in
        http*) printf '%s' "$_u" ;;
        /*)    printf '%s%s' "http://${PORTAL_HOST}" "$_u" ;;
        "")    printf '' ;;
        *)     printf '%s/%s' "http://${PORTAL_HOST}" "$_u" ;;
    esac
}

#------------------------------------------------------------------------------
# 二进制 -> 十六进制
#
# 【实测环境】路由器（ImmortalWrt 25.12.2）：有 hexdump，**无 od / xxd / base64**
# 优先 hexdump；退路用 openssl 构造（不依赖 od）；再不行明确报错。
#------------------------------------------------------------------------------
bin2hex() {
    _in="$1"

    # 主路径：hexdump（busybox 自带，实测可用）
    if command -v hexdump >/dev/null 2>&1; then
        hexdump -v -e '/1 "%02x"' "$_in" 2>/dev/null
        return $?
    fi

    # 退路 1：od
    if command -v od >/dev/null 2>&1; then
        od -An -tx1 -v "$_in" 2>/dev/null | tr -d ' \n'
        return $?
    fi

    # 退路 2：xxd
    if command -v xxd >/dev/null 2>&1; then
        xxd -p "$_in" 2>/dev/null | tr -d '\n'
        return $?
    fi

    # 退路 3：openssl 自我转换
    #   思路：把二进制读成 base64，再把 base64 的每个字符映射回 6 bit…
    #   实现繁琐且易错，这里不做；直接失败并提示装包。
    return 1
}

#------------------------------------------------------------------------------
# AES-128-ECB / PKCS7 加密，输出 base64
#   对应前端 CryptoJS: AES.encrypt(plain, Base64.parse(croypto), {mode:ECB, padding:Pkcs7})
#------------------------------------------------------------------------------
aes_encrypt() {
    _plain="$1"; _key_b64="$2"

    command -v openssl >/dev/null 2>&1 || return 1

    # base64 密钥 -> 原始 16 字节 -> hex
    # 【注意】路由器无 base64 命令（busybox 未编译），统一用 openssl base64
    _tmpk="$WORK_DIR/.key.bin"
    printf '%s' "$_key_b64" | openssl base64 -d -A >"$_tmpk" 2>/dev/null
    [ -s "$_tmpk" ] || return 1

    _ksz=$(wc -c <"$_tmpk" 2>/dev/null)
    [ "$_ksz" != "16" ] && return 1

    _key_hex=$(bin2hex "$_tmpk")
    [ ${#_key_hex} -ne 32 ] && return 1

    # openssl 的 aes-128-ecb 默认就是 PKCS7 填充
    # 输出用 openssl base64 编码（路由器无 base64 命令）
    printf '%s' "$_plain" | openssl enc -aes-128-ecb -K "$_key_hex" -nosalt 2>/dev/null | \
        openssl base64 -A 2>/dev/null | tr -d '\n'
}

#------------------------------------------------------------------------------
# URL 编码（逐字节处理，兼容 busybox；不依赖 od/awk 的多字节行为）
#   仅保留 RFC3986 unreserved 字符: A-Z a-z 0-9 - _ . ~
#
# 实现：先转 hex，再按「每字节」映射。完全避开多字节字符问题。
# 账号密码基本都是 ASCII，所以主路径稳定。
#------------------------------------------------------------------------------
urlencode() {
    _s="$1"

    _hex=""
    if command -v hexdump >/dev/null 2>&1; then
        _hex=$(printf '%s' "$_s" | hexdump -v -e '/1 "%02x"' 2>/dev/null)
    elif command -v od >/dev/null 2>&1; then
        _hex=$(printf '%s' "$_s" | od -An -tx1 -v 2>/dev/null | tr -d ' \n')
    fi

    # 无 hex 工具时的退化路径：纯 ASCII 字符级处理
    if [ -z "$_hex" ]; then
        _out=""
        _rest="$_s"
        while [ -n "$_rest" ]; do
            _c=$(printf '%s' "$_rest" | cut -c1)
            _rest=$(printf '%s' "$_rest" | cut -c2-)
            case "$_c" in
                [A-Za-z0-9_.~-]) _out="$_out$_c" ;;
                '') : ;;
                *) _out="$_out%$(printf '%02X' "'$_c" 2>/dev/null)" ;;
            esac
        done
        printf '%s' "$_out"
        return 0
    fi

    # hex -> URL 编码：每 2 个 hex 字符一组
    _out=""
    while [ ${#_hex} -ge 2 ]; do
        _b="${_hex%${_hex#??}}"   # 前两个字符
        _hex="${_hex#??}"
        case "$_b" in
            # unreserved：0-9 A-Z a-z - _ . ~
            2d|5f|2e|7e|3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a])
                _out="${_out}$(printf '%b' "\\$(printf '%03o' "$((0x$_b))")")" ;;
            *)
                _out="${_out}%$(printf '%s' "$_b" | tr 'a-f' 'A-F')" ;;
        esac
    done
    printf '%s' "$_out"
}

#------------------------------------------------------------------------------
# base64 风格字段的百分号编码（快）
#
# 【为什么必须做 · 实机血案 2026-10-04】
#   CAS 登录表单是 application/x-www-form-urlencoded。浏览器提交时会把
#   croypto / password / captcha_payload 里的 '+' 编成 %2B、'=' 编成 %3D：
#       HAR 实测（下面是脱敏示意值，真实值每次认证都不同）：
#                           croypto=5RpNbPt4pc869u8a1b4frA%3D%3D
#                           password=RVET5N6VgbAfq82H%2BBmC8A%3D%3D
#   如果原样提交，服务端 form-decode 会把 '+' 还原成**空格**，base64 密文被破坏，
#   AES 解出来是垃圾 -> 服务端回 "用户名或密码错误"(HTTP 401)。
#
#   之前误判为「不能 urlencode」，是因为当时那次的密码密文恰好不含 '+'，纯属运气。
#   AES 密文 16 字节 -> base64 24 字符，约 1/3 的概率含 '+'，所以表现为「时好时坏」。
#
#   execution 字段是 base64url（只有 [A-Za-z0-9_-]，无 + / =），编码前后一致，
#   为将来稳健也一并过一遍。
#
# 注意：这里不用 urlencode()，因为那是对每个字节 fork 一次子进程，
#       对 6773 字符的 execution 要 fork 上万次，路由器上会卡到超时。
#       base64 字段只可能出现 + / = % 四种需转义字符，sed 一次搞定。
#------------------------------------------------------------------------------
b64urlencode() {
    printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/+/%2B/g' -e 's|/|%2F|g' -e 's/=/%3D/g'
}

# 安全取文件字节数：文件不存在时返回 0。
# 直接用 `wc -c <file` 在文件缺失时会由 shell 打 "can't open ...: no such file"
# 到 stderr（`2>/dev/null` 挂在 wc 上挡不住重定向失败），把日志搅乱。
fsize() {
    [ -f "$1" ] || { printf '0'; return 0; }
    wc -c <"$1" 2>/dev/null || printf '0'
}

#------------------------------------------------------------------------------
# 从 HTML 中提取 <p id="xxx">VALUE</p>
#------------------------------------------------------------------------------
extract_p() {
    _html="$1"; _id="$2"
    printf '%s' "$_html" | sed -n "s/.*<p[^>]*id=[\"']${_id}[\"'][^>]*>\([^<]*\)<\/p>.*/\1/p" | head -1
}

#------------------------------------------------------------------------------
# 在线检测（2026-10-04 重写）
#
# 【旧版为什么错 · 实机血案】
#   旧版把「服务端 userOnline」当权威判据，而那个接口必须先拿 PORTAL_ENTRY_URL
#   换 sessionId。入口 URL 里的 wlanuserip 是**加密写死**的，路由器 WAN 地址一变
#   （DHCP 换网段，完全正常），它就成了过期数据：
#     · 服务端按旧 IP 建会话 -> 回 online:false
#     · 脚本据此认定「离线」-> 守护进程每 5 秒重认证一次
#     · 而设备其实**一直在线**，AC 每次都回 ACK_AUTH_REFUSE
#   实测：入口 URL 里是旧网段地址，而实际 WAN 已经换到新网段，
#   同时 LAN 侧 4120 条 conntrack / 139 条 ESTABLISHED，百度能拿到 29506 字节真实页面。
#   结论：**不能拿依赖入口 URL 的接口做在线判据**，它会把「入口过期」误报成「掉线」。
#
# 【新版判据】直接探测外网（域名优先，实测可靠）：
#   · rc=0 且 body/redirect 无门户特征 -> 在线
#   · 命中门户特征（eportal / cas-sso / 认证主机 / location.href）-> 离线（确定）
#   · 所有探测地址都失败 -> 离线（无法确认，按离线处理，交给认证流程）
#------------------------------------------------------------------------------
check_online() {
    for _cu in $ONLINE_CHECK_URLS; do
        http_get "$_cu" >/dev/null 2>&1
        _crc=$?
        _cb=$(cat "$WORK_DIR/body" 2>/dev/null)
        _cloc="${_HTTP_REDIRECT:-}"

        # 命中门户劫持特征 => 明确离线，不必再试其它地址
        case "$_cb$_cloc" in
            *"$PORTAL_HOST"*|*eportal*|*cas-sso*|*location.href*|*portal-main*)
                return 1 ;;
        esac

        # 请求成功且干净 => 在线
        [ "$_crc" -eq 0 ] && return 0
    done
    return 1
}

#------------------------------------------------------------------------------
# 服务端在线判定：/eportal/network/userOnline
#
# 【定位变更 2026-10-04】不再作为主判据（见 check_online 的说明），
#   只在 --check 里作为「补充说明」使用。并且加了**入口新鲜度校验**：
#   入口 URL 换出来的会话 userIp 若与当前 WAN IP 不符，说明入口已过期，
#   此时必须返回 2（无法判定），绝不能返回 1（未认证）—— 那正是旧版的病根。
#
# 返回: 0=已认证  1=未认证  2=无法判定
#------------------------------------------------------------------------------
portal_user_online() {
    [ -z "$PORTAL_ENTRY_URL" ] && return 2
    _co_base="http://${PORTAL_HOST}"
    _co_host=$(portal_host_only "$PORTAL_HOST")
    _co_port=$(portal_port_only "$PORTAL_HOST")
    _co_ep=$(printf '%s' "$PORTAL_ENTRY_URL" | sed 's|^[a-z]*://[^/]*||')

    _co_sid=""; _co_ip=""
    if nc_available; then
        : >"$WORK_DIR/.co.hdr"
        if nc_get "$_co_host" "$_co_port" "$_co_ep" "$WORK_DIR/.co.hdr" "$WORK_DIR/.co.raw"; then
            _co_loc=$(nc_location "$WORK_DIR/.co.raw")
            _co_sid=$(printf '%s' "$_co_loc" | sed -n 's/.*sessionId=\([^&]*\).*/\1/p')
            _co_ip=$(printf '%s' "$_co_loc" | sed -n 's/.*userIp=\([^&]*\).*/\1/p')
        fi
    fi
    [ -z "$_co_sid" ] && return 2

    # 入口新鲜度：会话里的 userIp 必须等于当前 WAN IP，否则入口已过期
    _co_wan=$(wan_ip)
    if [ -n "$_co_wan" ] && [ -n "$_co_ip" ] && [ "$_co_wan" != "$_co_ip" ]; then
        log "      [userOnline] 入口已过期：会话 userIp=$_co_ip，当前 WAN=$_co_wan"
        return 2
    fi

    printf '{"sessionId":"%s"}' "$_co_sid" >"$WORK_DIR/.co.json"
    http_post "${_co_base}/eportal/network/userOnline" "$WORK_DIR/.co.json" \
              "application/json" "${_co_base}/portal/portal-main" >/dev/null 2>&1

    _co_o=$(tr -d ' \t\r\n' <"$WORK_DIR/body" 2>/dev/null)
    case "$_co_o" in
        *'"online":true'*)  return 0 ;;
        *'"online":false'*) return 1 ;;
    esac
    return 2
}

#------------------------------------------------------------------------------
# 无线暂停 / 恢复（断网时关掉 WiFi，认证成功后开回来）
#
# 【做什么】见文件头 WIFI_PAUSE 的注释。
#
# 【怎么关】优先用 ubus 逐个 radio 精确控制（不重载 wireless 配置）：
#       ubus call network.wireless down '{"device":"radio0"}'
#   ubus 不可用、或拿不到 radio 列表时，退回 OpenWrt 自带的 `wifi down|up`。
#
# 【状态】WIFI_FLAG 存在 = 无线是**本脚本**关的。只有这种情况才由本脚本恢复，
#   避免误动用户自己在 LuCI 里关掉的无线。
#------------------------------------------------------------------------------

# 列出所有 radio 名（radio0 / radio1 / ...）
wifi_all_radios() {
    command -v uci >/dev/null 2>&1 || return 0
    uci -q show wireless 2>/dev/null | \
        sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p'
}

# 取某个 radio 的频段，输出 2g / 5g / unknown
#
# 【判据】优先读 `wireless.<radio>.band`（OpenWrt 21.02+ 的标准字段，
#   ImmortalWrt 25.12 一定用它）。老配置没有 band 时退回用 channel 推：
#   1-14 = 2.4G，36 及以上 = 5G。两样都拿不到就返回 unknown —— 未知频段**不碰**，
#   宁可少关一个，也不能因为猜错把该保留的频段关掉。
wifi_radio_band() {
    _b=$(uci -q get "wireless.$1.band" 2>/dev/null)
    case "$_b" in
        2g|2.4g) printf '2g'; return 0 ;;
        5g)      printf '5g'; return 0 ;;
    esac

    _ch=$(uci -q get "wireless.$1.channel" 2>/dev/null)
    case "$_ch" in
        ''|auto|0)    printf 'unknown' ;;
        [1-9]|1[0-4]) printf '2g' ;;
        [0-9]*)       printf '5g' ;;
        *)            printf 'unknown' ;;
    esac
}

# 按 2.4G / 5G 开关筛出「本次该关」的 radio 列表（每行一个）
wifi_target_radios() {
    for _r in $(wifi_all_radios); do
        case "$(wifi_radio_band "$_r")" in
            2g) [ "$WIFI_PAUSE_2G" = "1" ] && printf '%s\n' "$_r" ;;
            5g) [ "$WIFI_PAUSE_5G" = "1" ] && printf '%s\n' "$_r" ;;
            *)  : ;;        # unknown：不动
        esac
    done
}

# 底层：对指定 radio 执行 down / up。用法：_wifi_apply down radio0 radio1
#   返回 0 = 至少有一个成功。
_wifi_apply() {
    _wa="$1"; shift
    [ $# -eq 0 ] && return 1

    _wa_ok=0
    for _r in "$@"; do
        if command -v ubus >/dev/null 2>&1 && \
           ubus call network.wireless "$_wa" "{\"device\":\"$_r\"}" >/dev/null 2>&1; then
            _wa_ok=1
        fi
    done

    # ubus 一个都没成功、且目标正好是「全部 radio」时，退回 `wifi down|up`。
    # 只在全关时兜底 —— `wifi` 是整体操作，部分关的场景用它会把不该关的一起关掉。
    if [ "$_wa_ok" != "1" ] && command -v wifi >/dev/null 2>&1; then
        _wa_all=$(wifi_all_radios | wc -l)
        if [ "$#" -eq "$_wa_all" ] && wifi "$_wa" >/dev/null 2>&1; then
            _wa_ok=1
        fi
    fi

    [ "$_wa_ok" = "1" ]
}

wifi_pause() {
    [ "$WIFI_PAUSE" = "1" ] || return 0
    [ -s "$WIFI_FLAG" ] && return 0        # 已经关着，别重复操作

    _wp_list=$(wifi_target_radios | tr '\n' ' ')
    if [ -z "$_wp_list" ]; then
        log "      已启用断网暂停无线，但没有匹配的频段（检查 2.4G / 5G 开关）"
        return 0
    fi

    log "      暂停无线（断网中，认证成功后自动恢复）: $_wp_list"
    if _wifi_apply down $_wp_list; then
        printf '%s\n' $_wp_list >"$WIFI_FLAG"
        log "      无线已关闭（$_wp_list）"
    else
        # 关不掉不算致命：认证本身走 WAN，跟无线无关，继续跑
        log "      ⚠ 无线暂停失败（不影响认证流程，继续）"
    fi
}

wifi_resume() {
    [ -s "$WIFI_FLAG" ] || return 0        # 不是本脚本关的，不碰

    # 按**当初记下的那批 radio** 恢复，而不是按当前开关重算 ——
    # 见 WIFI_FLAG 的注释（关着的期间用户可能改过频段开关）。
    _wr_list=$(tr '\n' ' ' <"$WIFI_FLAG" 2>/dev/null)
    [ -z "$_wr_list" ] && { rm -f "$WIFI_FLAG"; return 0; }

    log "      恢复无线: $_wr_list"
    if _wifi_apply up $_wr_list; then
        rm -f "$WIFI_FLAG"
        log "      无线已恢复"
    else
        # 保留标志，下一轮还会再试 —— 否则会卡在「关了开不回来」
        log "      ⚠ 无线恢复失败，将在下一轮重试（也可手动执行 --wifi-resume）"
    fi
}

# 逃生口：无视开关与标志，把全部 radio 无条件拉起来。
#   给「标志文件丢了 / 状态异常」兜底用，也是 LuCI「恢复无线」按钮的后端。
wifi_force_resume() {
    rm -f "$WIFI_FLAG"
    _wfr_list=$(wifi_all_radios | tr '\n' ' ')
    if [ -n "$_wfr_list" ]; then
        _wifi_apply up $_wfr_list
    elif command -v wifi >/dev/null 2>&1; then
        wifi up >/dev/null 2>&1
    fi
}

#------------------------------------------------------------------------------
# 认证流程各阶段
#
# 【2026-10-10 重构】原来 do_auth() 是个 480 行的巨型函数，现按原注释里的
#   Step 边界拆成下面这些子函数。**纯搬移，逻辑一行没改** —— 内部仍然是原来
#   的全局变量风格（POSIX sh 没有 local），临时变量靠 `_` 前缀约定区分。
#   好处：单个函数不再超过 110 行，出错时一眼能定位到是哪一步。
#
# 状态传递：各阶段之间靠全局变量（_base / _sid / _phost / _pport / _chosen ...），
#   失败时用 die() 直接终止 —— 和拆分前完全一致。
#------------------------------------------------------------------------------

auth_session_init() {
    # ===== Step 0a: 建立会话（拿 SESSION cookie）=====
    #
    # 【HAR 实测 · 决定性】
    #   浏览器会话里，cookie `SESSION=<uuid>` 是在**最先**访问 http://10.10.16.56/
    #   时由服务端下发的（Path=/cas-sso/，HttpOnly）。
    #   该 cookie 一直带到之后的每一个 /cas-sso/ 请求，包括最终那次 POST 登录。
    #   少了它，POST 会被 CAS 当成「一次新的 GET」，返回登录页 HTML（实机 33984 字节）
    #   而不是 302 到 auth-success.html?ticket=...。
    #
    # 【实现选择】uclient-fetch / busybox wget 都拿不到 Set-Cookie（无 cookie 支持、
    #   无打印响应头选项），所以这里**优先用 nc 发裸 HTTP**，从原始响应里读 Set-Cookie。
    #   nc 不可用时才退回普通 http_get（虽然大概率拿不到 cookie，但至少不报错）。
    log "[0/5] 建立会话（获取 SESSION cookie）..."

    _sess=""
    _cookie_src=""
    _phost=$(portal_host_only "$PORTAL_HOST")
    _pport=$(portal_port_only "$PORTAL_HOST")
    if nc_available; then
        _hdrfile="$WORK_DIR/.probe.hdr"; : >"$_hdrfile"

        # 【决定性修复 · 实机验证】
        #   CAS 的 `SESSION` cookie 不是从根路径 `/` 下发的，而是由
        #   `/cas-sso/logout` 的 302 响应下发（HAR entry 4 实测：Set-Cookie: SESSION=<uuid>）。
        #   少了这个 cookie，后续 POST /cas-sso/login 会返回 **401**（而不是 302 带 ticket）。
        #   实机对照：先 logout -> 302 + ticket；不 logout -> 401 + 登录页。
        _logout_path="/cas-sso/logout?service=http%3A%2F%2F${PORTAL_HOST}%2Fportal%2Fpc%2FofflineSuccess"
        if nc_get "$_phost" "$_pport" "$_logout_path" "$_hdrfile" "$WORK_DIR/.raw"; then
            log "      logout 响应: HTTP $(nc_status "$WORK_DIR/.raw")"
            cookie_absorb_file "$WORK_DIR/.raw"
            _sess=$(sed -n 's/^SESSION=//p' "$COOKIE_FILE" 2>/dev/null | head -1)
        fi

        # 兜底：若 logout 未下发，再试根路径及其跳转
        if [ -z "$_sess" ]; then
            if nc_get "$_phost" "$_pport" "/" "$_hdrfile" "$WORK_DIR/.raw"; then
                cookie_absorb_file "$WORK_DIR/.raw"
                _sess=$(sed -n 's/^SESSION=//p' "$COOKIE_FILE" 2>/dev/null | head -1)
            fi
            if [ -z "$_sess" ]; then
                _loc=$(nc_location "$WORK_DIR/.raw")
                case "$_loc" in
                    /*)
                        if nc_get "$_phost" "$_pport" "$_loc" "$_hdrfile" "$WORK_DIR/.raw2"; then
                            cookie_absorb_file "$WORK_DIR/.raw2"
                            _sess=$(sed -n 's/^SESSION=//p' "$COOKIE_FILE" 2>/dev/null | head -1)
                        fi ;;
                esac
            fi
        fi
    fi

    # 退回普通方式（curl 后端能拿到；uclient-fetch 后端拿不到）
    if [ -z "$_sess" ]; then
        http_get "${_base}/" >/dev/null 2>&1
        _sess=$(sed -n 's/^SESSION=//p' "$COOKIE_FILE" 2>/dev/null | head -1)
    fi

    if [ -n "$_sess" ]; then
        log "      SESSION=$(printf '%s' "$_sess" | cut -c1-24)... (已存入 cookie jar)"
    else
        # 拿不到不算致命：Step 1 请求登录页时会再收集一次 Set-Cookie
        log "      根路径未下发 SESSION，将在取登录页时再试"
    fi

}

auth_probe_entry() {
    # ===== Step 0b: 触发网关拦截, 捕获 eportal 入口参数 =====
    #
    # 【机制说明 · 实测自 HAR】
    #   本网关不是标准 HTTP 302 重定向, 而是在响应体里注入一段 JS:
    #     <script>top.self.location.href='http://10.10.16.56/eportal/index.jsp?wlanuserip=...&mac=...'</script>
    #   该 body 约 478~494 字节, HTTP 状态是 200。
    #   所以：不能靠 Location 响应头, 必须从 body 里正则提取 location.href 的 URL。
    #
    #   拿到 eportal/index.jsp?<加密参数> 后, 再请求它, 它会 302 到:
    #     /portal/portal-main?sessionId=xxx&userIp=...&userMac=...&nasIp=...&customPageId=...
    #   这些是明文, 直接解析即可。
    log "[0/5] 触发网关拦截..."
    _eportal_url=""

    # 【2026-10-04 顺序反转】原来「固定入口优先、跳过探测」，这是病根之一：
    #   固定入口里 wlanuserip 是**加密写死的旧 IP**，WAN 地址一变就失效。
    #   现在改成「**先探测**」—— 只要 AC 还在劫持，拿到的入口一定带**当前** IP，
    #   天然不会过期。探测拿不到才退回固定入口（下面会做新鲜度校验）。
    for _probe in $PROBE_URLS; do
        http_get "$_probe" >/dev/null 2>&1

        # (a) 先从 body 里找注入的 JS 跳转
        _body=$(cat "$WORK_DIR/body" 2>/dev/null)
        _hit=""
        if [ -n "$_body" ]; then
            _hit=$(printf '%s' "$_body" | \
                sed -n "s/.*location\.href[[:space:]]*=[[:space:]]*['\"]\(http[^'\"]*\)['\"].*/\1/p" | head -1)
            [ -z "$_hit" ] && _hit=$(printf '%s' "$_body" | \
                sed -n "s/.*location\.replace([[:space:]]*['\"]\(http[^'\"]*\)['\"].*/\1/p" | head -1)
            [ -z "$_hit" ] && _hit=$(printf '%s' "$_body" | \
                sed -n "s/.*window\.location[[:space:]]*=[[:space:]]*['\"]\(http[^'\"]*\)['\"].*/\1/p" | head -1)
        fi

        # (b) 退一步：看 stderr 有没有真 302
        if [ -z "$_hit" ] && [ -n "$_HTTP_REDIRECT" ]; then
            _hit="$_HTTP_REDIRECT"
        fi

        case "$_hit" in
            *eportal*|*"$PORTAL_HOST"*)
                _eportal_url=$(abs_url "$_hit")
                _entry_fresh=1
                log "      探测 $_probe -> 捕获入口（含当前 IP）"
                break ;;
        esac
    done

    if [ -z "$_eportal_url" ]; then
        # 【兜底】AC 只在「未认证设备首次访问外网」时劫持；一旦它认为设备已认证
        #   （哪怕只是半认证）就直接 DROP TCP，不再劫持，此时探测永远拿不到入口
        #   （实机现象：SYN_SENT 无响应）。这时只能复用历史上抓到的那条。
        #   ⚠ 但它是**旧 IP**，AC 大概率回 ACK_AUTH_REFUSE，下面会明确告警。
        if [ -n "$PORTAL_ENTRY_URL" ]; then
            log "      探测未劫持，改用配置的固定入口 URL 兜底"
            _eportal_url="$PORTAL_ENTRY_URL"
            _entry_fresh=0
        else
            die "未捕获网关跳转，且未配置 PORTAL_ENTRY_URL 兜底。
       说明：AC 当前不劫持（可能认为本机已认证），且没有可复用的入口 URL。
       获取方式：在能正常上网时执行一次本脚本，或从日志里找 '入口: http://...eportal/index.jsp?...'，
       把它配置到 /etc/portal-auth.conf 的 PORTAL_ENTRY_URL。"
        fi
    fi
    log "      入口: $(printf '%s' "$_eportal_url" | cut -c1-100)..."

    # 请求 eportal 入口 -> 302 到 portal-main (带 sessionId 等明文参数)
    #
    # 【重要】uclient-fetch 会自动跟随这个 302，但目标 URL 里的 accessTime
    # 含未编码空格，跟随后会得到 "HTTP error 400"。这不影响我们 ——
    # 我们需要的信息全在 "Redirected to ..." 那一行里，直接解析即可，**不再请求它**。
    http_get "$_eportal_url" >/dev/null 2>&1
    _loc2="$_HTTP_REDIRECT"

    # 若 eportal 入口也返回 JS 跳转，同样提取
    if [ -z "$_loc2" ]; then
        _b2=$(cat "$WORK_DIR/body" 2>/dev/null)
        _loc2=$(printf '%s' "$_b2" | \
            sed -n "s/.*location\.href[[:space:]]*=[[:space:]]*['\"]\(http[^'\"]*\)['\"].*/\1/p" | head -1)
    fi
    log "      入口跳转: $(printf '%s' "$_loc2" | cut -c1-120)"

    if [ -z "$_loc2" ]; then
        die "入口未产生跳转（sessionId 未取得）"
    fi
    _main_url=$(abs_url "$_loc2")

    # 从 Location 里解析明文参数（注意 URL 可能含空格，[^&]* 是正确的，因为参数值到 & 或行尾为止）
    _sid=$(printf '%s' "$_main_url" | sed -n 's/.*[?&]sessionId=\([^&]*\).*/\1/p')
    _userip=$(printf '%s' "$_main_url" | sed -n 's/.*[?&]userIp=\([^&]*\).*/\1/p')
    _usermac=$(printf '%s' "$_main_url" | sed -n 's/.*[?&]userMac=\([^&]*\).*/\1/p')
    _nasip=$(printf '%s' "$_main_url" | sed -n 's/.*[?&]nasIp=\([^&]*\).*/\1/p')
    _pageid=$(printf '%s' "$_main_url" | sed -n 's/.*[?&]customPageId=\([^&]*\).*/\1/p')

    [ -z "$_sid" ] && die "未取得 sessionId"
    log "      sessionId=$_sid"
    log "      userIp=$_userip userMac=$_usermac nasIp=$_nasip customPageId=$_pageid"

    # ===== 入口新鲜度校验（2026-10-04 新增）=====
    #   入口 URL 里的 wlanuserip 是加密写死的；WAN 地址一变（DHCP 换网段很正常），
    #   服务端就按**旧 IP** 建会话，AC 那边根本没这个终端 -> ACK_AUTH_REFUSE。
    #   这里把「会话里的 userIp」与「当前 WAN IP」对比，不一致就明确告警，
    #   免得再把「入口过期」误当成「密码错 / 网络断」查半天。
    _cur_wan=$(wan_ip)
    if [ -n "$_cur_wan" ] && [ -n "$_userip" ] && [ "$_cur_wan" != "$_userip" ]; then
        log "      ⚠ 入口已过期：会话 userIp=$_userip，当前 WAN IP=$_cur_wan"
        log "        该入口是旧 IP 的产物，AC 极可能回 ACK_AUTH_REFUSE。"
        log "        需等 AC 重新劫持（或重启 WAN 口），本脚本会自动捕获并回写新入口。"
    elif [ "${_entry_fresh:-0}" = "1" ]; then
        save_entry_url "$_eportal_url"
    fi

}

auth_cas_reinit() {
    # ===== Step 0c: 取登录页前，按正确顺序重建 CAS 会话 =====
    #
    # 【顺序关键 · 实机验证】成功路径的严格顺序是：
    #     ① 先拿 sessionId（eportal 入口）
    #     ② 再 /cas-sso/logout 建立会话（下发 SESSION）
    #     ③ 取登录页  ④ POST 登录
    #   如果先 logout 再拿 sessionId，Step 0b 的探测/入口请求会把 cookie 覆盖掉，
    #   POST 时带的就不是 logout 下发的那个 SESSION —— 实测会得到 **401**。
    #   所以这里清空 cookie，严格按 ②③④ 重来一遍。
    cookie_clear
    if nc_available; then
        _lh="$WORK_DIR/.logout0.hdr"; : >"$_lh"
        _lp="/cas-sso/logout?service=http%3A%2F%2F${PORTAL_HOST}%2Fportal%2Fpc%2FofflineSuccess"
        if nc_get "$_phost" "$_pport" "$_lp" "$_lh" "$WORK_DIR/.logout0.raw"; then
            cookie_absorb_file "$WORK_DIR/.logout0.raw"
            log "      CAS 会话: $(sed -n 's/^SESSION=//p' "$COOKIE_FILE" 2>/dev/null | head -1 | cut -c1-12)..."
        fi
    fi

}

auth_get_login_page() {
    # ===== Step 1: 获取登录页, 解析 execution 与 croypto =====
    #
    # 【HAR 实测】浏览器请求的 URL 尾部比脚本原先多了 `&accept-language=zh-CN`
    #   GET /cas-sso/login?flowSessionId=...&customPageId=...&preview=false
    #       &appType=normal&language=zh-CN&timer=...&nasIp=...&userIp=...&userMac=...
    #       &accept-language=zh-CN
    #   并且带 Referer: http://<host>/portal/entry/pc/authenticate;flowParams=undefined;from=
    #   这里补上，尽量逼近浏览器行为（CAS 可能据此判定会话有效性）。
    log "[1/5] 获取登录页..."
    _login_qs="flowSessionId=${_sid}&customPageId=${_pageid}&preview=false&appType=normal&language=zh-CN&timer=$(date +%s)000"
    [ -n "$_nasip" ] && _login_qs="${_login_qs}&nasIp=${_nasip}"
    [ -n "$_userip" ] && _login_qs="${_login_qs}&userIp=${_userip}"
    [ -n "$_usermac" ] && _login_qs="${_login_qs}&userMac=${_usermac}"
    _login_qs="${_login_qs}&accept-language=zh-CN"
    _login_url="${_base}/cas-sso/login?${_login_qs}"
    _login_referer="${_base}/portal/entry/pc/authenticate;flowParams=undefined;from="
    _login_path="/cas-sso/login?${_login_qs}"

    # 优先 nc：一次拿到 body(execution/croypto) + Set-Cookie(SESSION)
    _got_login=0
    if nc_available; then
        _hdrf="$WORK_DIR/.login.hdr"
        printf 'Referer: %s\r\n' "$_login_referer" >"$_hdrf"
        if nc_get "$_phost" "$_pport" "$_login_path" "$_hdrf" "$WORK_DIR/.login.raw"; then
            cookie_absorb_file "$WORK_DIR/.login.raw"
            nc_body "$WORK_DIR/.login.raw" >"$WORK_DIR/body"
            [ -s "$WORK_DIR/body" ] && _got_login=1
            _ls=$(nc_status "$WORK_DIR/.login.raw")
            log "      登录页: HTTP $_ls, body $(wc -c <"$WORK_DIR/body") 字节, cookie=[$(cookie_header)]"
        fi
    fi

    if [ "$_got_login" != "1" ]; then
        http_get "$_login_url" "$_login_referer" >/dev/null 2>&1
        if [ ! -s "$WORK_DIR/body" ]; then
            # 可能被 302 到别处，跟随一次
            if [ -n "$_HTTP_REDIRECT" ]; then
                http_get "$(abs_url "$_HTTP_REDIRECT")" "$_login_referer" >/dev/null 2>&1
            fi
        fi
    fi
    _page=$(cat "$WORK_DIR/body" 2>/dev/null)
    [ -z "$_page" ] && die "登录页为空"

    _execution=$(extract_p "$_page" "login-page-flowkey")
    _croypto=$(extract_p "$_page" "login-croypto")

    [ -z "$_execution" ] && die "未解析出 execution (login-page-flowkey)"
    [ -z "$_croypto" ] && die "未解析出 croypto (AES密钥)"
    log "      execution=$(printf '%s' "$_execution" | cut -c1-40)... (len ${#_execution})"
    log "      croypto=$_croypto"
    log "      SESSION=$(sed -n 's/^SESSION=//p' "$COOKIE_FILE" 2>/dev/null | head -1 | cut -c1-20)..."

}

auth_submit_login() {
    # ===== Step 2: AES 加密密码并提交 =====
    #
    # 【HAR 实测 · 逐字段对齐 entry 86】
    #   成功那次 POST 的 body（原文，未 urlencode）：
    #     username=<账号>
    #     &type=UsernamePassword
    #     &_eventId=submit
    #     &geolocation=
    #     &execution=<6773 字符，含 + / = 原样>
    #     &captcha_code=
    #     &croypto=5RpNbPt4pc869u8a1b4frA==      <- 原样，未编码（脱敏示意值）
    #     &password=RVET5N6VgbAfq82H+BmC8A==     <- 原样，未编码
    #     &captcha_payload=ZzYyXxWwVvUuTtSsRrQqPp==
    #
    #   三个必须修正的点：
    #     ① 带 Cookie: SESSION=...       （缺则被当成新 GET，返回登录页）
    #     ② execution/croypto/password **不做 urlencode**（原样提交；编码后服务端解不出）
    #     ③ 补 captcha_payload 字段
    log "[2/5] 提交登录..."
    log "      账号=[${PORTAL_USER}] (长度 ${#PORTAL_USER})  密码长度 ${#PORTAL_PASS}"
    _encpw=$(aes_encrypt "$PORTAL_PASS" "$_croypto")
    [ -z "$_encpw" ] && die "密码加密失败（检查 openssl 与 croypto）"

    # captcha_payload：HAR + 前端 JS 实测确认
    #
    # 【前端源码】sso-public/cas-login-new/main.js:
    #   h.setAttribute("name", "captcha_payload");
    #   h.setAttribute("value", Bn.aesEncrypt(l, JSON.stringify(this.captcha_payload)));
    # 而 this.captcha_payload 初始值就是 `{}`（只有启用 geetest/google 验证码时才被填充）。
    # 本网络 recaptchaVendor=system（无第三方验证码），所以它恒为 `{}`。
    #
    # 于是：captcha_payload = AES("{ }", croypto)
    # 验证：用那次 croypto 加密 "{}" 得到一段 24 字符 base64（值已脱敏），
    #       与 HAR entry 86 里该字段**逐字节一致**。
    _enc_captcha=$(aes_encrypt "{}" "$_croypto")
    [ -z "$_enc_captcha" ] && die "captcha_payload 加密失败"

    # 【重要 · 2026-10-04 修正】提交时对 base64 风格字段做百分号编码，与浏览器一致。
    #   原样提交会让服务端把密文里的 '+' 解码成空格 -> "用户名或密码错误"。
    #   详见 b64urlencode() 的注释。
    _post="username=$(urlencode "$PORTAL_USER")"
    _post="${_post}&type=UsernamePassword"
    _post="${_post}&_eventId=submit"
    _post="${_post}&geolocation="
    _post="${_post}&execution=$(b64urlencode "$_execution")"
    _post="${_post}&captcha_code="
    _post="${_post}&croypto=$(b64urlencode "$_croypto")"
    _post="${_post}&password=$(b64urlencode "$_encpw")"
    _post="${_post}&captcha_payload=$(b64urlencode "$_enc_captcha")"

    printf '%s' "$_post" >"$WORK_DIR/postdata"

    # ---- 提交方式：优先 nc（避开 uclient-fetch 把 POST 降级成 GET 的坑）----
    # 清空 err：它是 http_* 的 stderr 落盘处，POST 前必须清掉，
    # 否则下面 _resp_hdr 会读到上一步（入口/登录页）的陈旧输出，诊断串台。
    : >"$WORK_DIR/err"
    _phost=$(portal_host_only "$PORTAL_HOST")
    _pport=$(portal_port_only "$PORTAL_HOST")
    _login_path=$(printf '%s' "$_login_url" | sed -n 's|^[a-z]*://[^/]*\(/.*\)$|\1|p')
    [ -z "$_login_path" ] && _login_path="/cas-sso/login"

    if nc_available; then
        if nc_post "$_phost" "$_pport" "$_login_path" "$WORK_DIR/postdata" \
                   "application/x-www-form-urlencoded" "$_login_url" "$WORK_DIR/.post.raw"; then
            cookie_absorb_file "$WORK_DIR/.post.raw"
            _pstatus=$(nc_status "$WORK_DIR/.post.raw")
            _HTTP_REDIRECT=$(nc_location "$WORK_DIR/.post.raw")
            nc_body "$WORK_DIR/.post.raw" >"$WORK_DIR/body"
            _rsize=$(wc -c <"$WORK_DIR/body" 2>/dev/null || echo 0)
            log "      POST 完成: HTTP $_pstatus, body ${_rsize} 字节, redirect=$(printf '%s' "$_HTTP_REDIRECT" | cut -c1-70)"
            [ "$VERBOSE" = "1" ] && {
                log "      发送的 Cookie: $(cookie_header)"
                log "      响应头前 10 行:"
                head -10 "$WORK_DIR/.post.raw" | sed 's/^/        /'
            }
        else
            log "      ⚠ nc POST 无响应，回退 http_post"
            http_post "$_login_url" "$WORK_DIR/postdata" "application/x-www-form-urlencoded" "$_login_url" >/dev/null 2>&1
        fi
    else
        http_post "$_login_url" "$WORK_DIR/postdata" "application/x-www-form-urlencoded" "$_login_url" >/dev/null 2>&1
    fi
    _rc=$?
    _resp_hdr=$(cat "$WORK_DIR/err" 2>/dev/null)
    _ticket=$(printf '%s' "$_HTTP_REDIRECT" | sed -n 's/.*ticket=\([^&[:space:]]*\).*/\1/p' | head -1)
    [ -z "$_ticket" ] && _ticket=$(printf '%s' "$_resp_hdr" | sed -n 's/.*ticket=\([^&[:space:]]*\).*/\1/p' | head -1)

    # 判定成功：出现 ticket，或重定向指向 portal-main / eportal
    case "$_HTTP_REDIRECT" in
        *ticket=*|*eportal*|*portal-main*)
            log "      登录成功, ticket=$(printf '%s' "$_ticket" | cut -c1-30)..." ;;
        *)
            # 失败时把关键证据打出来，便于一次定位
            log "      ── 失败诊断 ──"
            log "      POST URL: $(printf '%s' "$_login_url" | cut -c1-120)"
            log "      postdata 字节数: $(fsize "$WORK_DIR/postdata")"
            log "      execution 长度: ${#_execution}"
            log "      发送 Cookie: [$(cookie_header)]"
            log "      响应 body 字节数: $(fsize "$WORK_DIR/body")"
            log "      响应 body 前 300 字节:"
            head -c 300 "$WORK_DIR/body" 2>/dev/null | sed 's/^/        /'
            log "      ── 诊断结束 ──"
            _errtxt=$(printf '%s' "$_resp_hdr" | head -3 | tr '\n' ' ')
            die "登录失败（未取得 ticket）。原始输出: ${_errtxt}"
            ;;
    esac

}

auth_advance_workflow() {
    # ===== Step 3: 推进工作流 =====
    log "[3/5] 推进认证工作流..."
    printf '{"sessionId":"%s","flowKey":"portal_auth"}' "$_sid" >"$WORK_DIR/json"
    http_post "${_base}/eportal/workFlow/getCurrentNode" "$WORK_DIR/json" "application/json" "${_base}/portal/portal-main" >/dev/null 2>&1
    _node=$(cat "$WORK_DIR/body" 2>/dev/null)

    _nodepath=$(printf '%s' "$_node" | sed -n 's/.*"currentNodePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    log "      当前节点: ${_nodepath:-未知}"

}

auth_query_services() {
    # ===== Step 4: 查询运营商 =====
    log "[4/5] 查询运营商..."
    printf '{"sessionId":"%s"}' "$_sid" >"$WORK_DIR/json"
    http_post "${_base}/eportal/network/serviceSelection" "$WORK_DIR/json" "application/json" "${_base}/portal/portal-main" >/dev/null 2>&1
    _sel=$(cat "$WORK_DIR/body" 2>/dev/null)

    # 提取所有 key 值（用 tr 把 JSON 打散成每行一个 token，再抓 key 后的字符串）
    _services=$(printf '%s' "$_sel" | tr ',{}[]' '\n\n\n\n\n' | \
        sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    log "      可选: $(printf '%s' "$_services" | tr '\n' ' ')"

    # 选定运营商：优先用户配置，否则取第一个非 default
    _chosen="$PORTAL_SERVICE"
    if ! printf '%s' "$_services" | grep -qx "$_chosen"; then
        _chosen=$(printf '%s' "$_services" | grep -vx "default" | head -1)
    fi
    [ -z "$_chosen" ] && _chosen="$PORTAL_SERVICE"
    log "      选定: $_chosen"

}

# Step 5 —— 提交运营商。
#
# 【返回值是三态，不是布尔】原来这段在 do_auth 内部用 `return 0` 提前结束整个
#   认证流程（ACK_AUTH_REFUSE 但外网可通 = 设备其实已在线）。抽成函数后没法
#   再用 return 提前结束调用方，所以改成返回码，由 do_auth 决定是否短路：
#     0 = 受理成功，继续跑 5b/5c
#     1 = 认证失败
#     2 = 已确认在线（提前成功，跳过 5b/5c）
auth_submit_service() {
    # ===== Step 5: 完成认证 =====
    log "[5/5] 提交运营商完成认证..."
    printf '{"sessionId":"%s","service":"%s"}' "$_sid" "$_chosen" >"$WORK_DIR/json"
    http_post "${_base}/eportal/network/serviceLogin" "$WORK_DIR/json" "application/json" "${_base}/portal/portal-main" >/dev/null 2>&1
    _fin=$(cat "$WORK_DIR/body" 2>/dev/null)

    # 【实机踩坑】服务端返回的是**带缩进的格式化 JSON**：
    #   { "code" : 200, "data" : { "authResult" : "success" } }
    # 冒号两边都有空格，直接匹配 '"authResult":"success"' 会失败
    # （曾误报「认证失败: 响应异常」，但 body 里明明是 success）。
    # => 先去掉所有空白再匹配，最稳。
    _fin_c=$(printf '%s' "$_fin" | tr -d ' \t\r\n')
    case "$_fin_c" in
        *'"authResult":"success"'*)
            log "      运营商受理成功 (authResult=success)"
            ;;
        *)
            _msg=$(printf '%s' "$_fin_c" | sed -n 's/.*"authMessage":"\([^"]*\)".*/\1/p')
            log "认证失败: ${_msg:-响应异常}"

            # 【2026-10-04 自愈】ACK_AUTH_REFUSE = AC 拒绝本次 portal 请求。
            #   实测它最常见的原因**不是故障**，而是这台设备本来就已经在线
            #   （AC 不允许重复认证）。旧版据此认定失败，于是守护进程每 5 秒
            #   重认证一次、每次都被拒 —— 明明有网却永远在重试。
            #   这里回头探测一次外网：能通就按成功处理，直接收敛。
            case "$_msg" in
                *ACK_AUTH_REFUSE*)
                    if check_online; then
                        log "      → 外网探测可通：设备其实已在线（AC 拒绝重复认证），按成功处理"
                        return 2
                    fi
                    log "      → 外网仍不通；入口 URL 很可能已过期（见上方新鲜度告警）"
                    ;;
            esac

            log "      原始响应: $(printf '%s' "$_fin" | cut -c1-200)"
            return 1
            ;;
    esac

    return 0
}

auth_confirm_finish() {
    # ===== Step 5b: 确认工作流走到 finish =====
    # 【HAR 实测 · entry 97】serviceLogin 之后浏览器会再查一次 getCurrentNode，
    #   此时 currentNodePath 从 "serviceSelection" 变成 "finish" —— 这是认证完成的标志。
    printf '{"sessionId":"%s","flowKey":"portal_auth"}' "$_sid" >"$WORK_DIR/json"
    http_post "${_base}/eportal/workFlow/getCurrentNode" "$WORK_DIR/json" "application/json" "${_base}/portal/portal-main" >/dev/null 2>&1
    _npath=$(printf '%s' "$(cat "$WORK_DIR/body" 2>/dev/null)" | tr -d ' \t\r\n' | \
        sed -n 's/.*"currentNodePath":"\([^"]*\)".*/\1/p')
    log "      工作流节点: ${_npath:-未知}"

}

auth_verify_online() {
    # ===== Step 5c: 查询在线状态（权威判定）=====
    # 【HAR 实测 · entry 109】/eportal/network/userOnline 返回
    #   {"data":{"online":true,...}} —— 这是服务端认定的在线状态，
    #   比探测外网 IP 可靠得多（校园网可能只放行部分端口/协议）。
    printf '{"sessionId":"%s"}' "$_sid" >"$WORK_DIR/json"
    http_post "${_base}/eportal/network/userOnline" "$WORK_DIR/json" "application/json" "${_base}/portal/portal-main" >/dev/null 2>&1
    _onl=$(printf '%s' "$(cat "$WORK_DIR/body" 2>/dev/null)" | tr -d ' \t\r\n')
    case "$_onl" in
        *'"online":true'*)
            log "      服务端确认在线 (userOnline=true)"
            log "认证成功！(${_chosen})"
            return 0
            ;;
        *'"online":false'*)
            log "      服务端仍显示离线 (userOnline=false)"
            log "认证未生效：运营商已受理但网关未放行"
            log "      原始响应: $(printf '%s' "$_onl" | cut -c1-200)"
            return 1
            ;;
        *)
            # 拿不到 userOnline 也不代表失败：退回探测外网
            if check_online; then
                log "认证成功！(${_chosen})  [经外网探测确认]"
                return 0
            fi
            log "认证结果未知（userOnline 无有效响应，外网探测也不通）"
            log "      原始响应: $(printf '%s' "$_onl" | cut -c1-200)"
            return 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# 认证主流程
#
# 只负责「前置检查 + 按顺序驱动各阶段」。每一步的实现在上面那些 auth_* 函数里，
# 这里保持成一张能一眼看完的流程图。
#------------------------------------------------------------------------------
do_auth() {
    _base="http://${PORTAL_HOST}"

    # 账号/密码为空时给出明确指引 —— 发布的包默认就是空的，必须用户自己填。
    if [ -z "$PORTAL_USER" ] || [ -z "$PORTAL_PASS" ]; then
        die "尚未配置校园网账号/密码。请打开 LuCI「服务 -> SUIT 校园网自动认证」填写并保存；或执行 uci set suit-portal.main.username='你的账号' && uci set suit-portal.main.password='你的密码' && uci commit suit-portal && /etc/init.d/suit-portal restart"
    fi
    command -v openssl >/dev/null 2>&1 || die "缺少 openssl，请执行: apk add openssl-util"

    rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
    cookie_clear

    auth_session_init
    auth_probe_entry
    auth_cas_reinit
    auth_get_login_page
    auth_submit_login
    auth_advance_workflow
    auth_query_services

    # Step 5 的三态返回码：0=继续 / 1=失败 / 2=已确认在线（提前成功）
    auth_submit_service
    case $? in
        0) : ;;
        2) return 0 ;;
        *) return 1 ;;
    esac

    auth_confirm_finish
    auth_verify_online        # 这一步的返回码就是 do_auth 的返回码
}


#------------------------------------------------------------------------------
# 入口
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# 子命令实现
#
# 【2026-10-10 重构】从 main() 里搬出来的两段独立逻辑（原 case 分支里一百多行
#   的 --trace、以及 --probe），外加四个认证入口共用的收尾动作。
#------------------------------------------------------------------------------

# 跑一次认证，成功就恢复无线。返回值 = 认证结果（0 = 成功）。
#   --auth / --force / --verbose / 守护进程路径 四个入口共用这一套收尾，
#   省得同一段 do_auth + _rc + wifi_resume 抄四遍。
auth_run_and_resume() {
    do_auth
    _rc=$?
    [ "$_rc" -eq 0 ] && wifi_resume
    return "$_rc"
}

# --probe：把网关拦截返回的原始 body 打出来（调试用）
probe_flow() {
    # 调试用：把网关拦截返回的原始 body 打出来
    log "后端=$HTTP_BACKEND"
    for _p in $PROBE_URLS; do
        http_get "$_p" >/dev/null 2>&1
        log "--- $_p (rc=$?) ---"
        log "[redirect] ${_HTTP_REDIRECT:-<无>}"
        log "[body] $(head -c 400 "$WORK_DIR/body" 2>/dev/null)"
    done
}

# --trace：深度诊断，完整打印每个阶段的原始 body / stderr / redirect
trace_flow() {
    # 深度诊断：完整打印每个阶段的原始 body / stderr / redirect
    VERBOSE=1
    log "后端=$HTTP_BACKEND"
    rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
    cookie_clear

    log "===== 阶段 0a：建立会话（GET / ）====="
    _phost=$(portal_host_only "$PORTAL_HOST")
    _pport=$(portal_port_only "$PORTAL_HOST")
    log "  nc 可用: $(nc_available && echo 是 || echo 否)   host=$_phost port=$_pport"
    _hdrfile="$WORK_DIR/.probe.hdr"; : >"$_hdrfile"
    if nc_available && nc_get "$_phost" "$_pport" "/" "$_hdrfile" "$WORK_DIR/.raw"; then
        log "  HTTP 状态: $(nc_status "$WORK_DIR/.raw")"
        log "  跳转: $(nc_location "$WORK_DIR/.raw")"
        log "  原始响应头（前 25 行）:"
        head -25 "$WORK_DIR/.raw" 2>/dev/null | sed 's/^/    /'
        cookie_absorb_file "$WORK_DIR/.raw"

        _loc=$(nc_location "$WORK_DIR/.raw")
        case "$_loc" in
            /*)
                log "  跟随跳转到: $_loc"
                if nc_get "$_phost" "$_pport" "$_loc" "$_hdrfile" "$WORK_DIR/.raw2"; then
                    log "  跳转后响应头（前 25 行）:"
                    head -25 "$WORK_DIR/.raw2" 2>/dev/null | sed 's/^/    /'
                    cookie_absorb_file "$WORK_DIR/.raw2"
                fi ;;
        esac
    fi
    log "  cookie jar:"
    sed 's/^/    /' "$COOKIE_FILE" 2>/dev/null
    log "  发送用 Cookie 头: [$(cookie_header)]"

    log "===== 阶段 0b：探测网关拦截 ====="
    _eu=""
    for _p in $PROBE_URLS; do
        log "--- GET $_p ---"
        http_get "$_p" >/dev/null 2>&1
        _r=$?
        log "  rc=$_r  redirect=<${_HTTP_REDIRECT:-无}>"
        log "  body 前200字节: $(head -c 200 "$WORK_DIR/body" 2>/dev/null)"
        log "  stderr: $(head -c 200 "$WORK_DIR/err" 2>/dev/null)"
        _h=$(printf '%s' "$(cat "$WORK_DIR/body" 2>/dev/null)" | \
            sed -n "s/.*location\.href[[:space:]]*=[[:space:]]*['\"]\(http[^'\"]*\)['\"].*/\1/p" | head -1)
        if [ -n "$_h" ]; then _eu="$_h"; break; fi
    done
    [ -z "$_eu" ] && { log "未捕获入口，终止"; return 1 2>/dev/null || exit 1; }
    log "===== 阶段 1：请求 eportal 入口 ====="
    log "URL: $(printf '%s' "$_eu" | cut -c1-150)"
    http_get "$_eu" >/dev/null 2>&1
    _r=$?
    log "  rc=$_r  redirect=<${_HTTP_REDIRECT:-无}>"
    log "  body 前400字节: $(head -c 400 "$WORK_DIR/body" 2>/dev/null)"
    log "  body 字节数: $(wc -c <"$WORK_DIR/body" 2>/dev/null)"
    log "  stderr 全文:"
    cat "$WORK_DIR/err" 2>/dev/null | sed 's/^/    /'

    # 解析 sessionId 等
    _tsid=$(printf '%s' "${_HTTP_REDIRECT}" | sed -n 's/.*[?&]sessionId=\([^&]*\).*/\1/p')
    _tpage=$(printf '%s' "${_HTTP_REDIRECT}" | sed -n 's/.*[?&]customPageId=\([^&]*\).*/\1/p')
    _tnasip=$(printf '%s' "${_HTTP_REDIRECT}" | sed -n 's/.*[?&]nasIp=\([^&]*\).*/\1/p')
    _tuserip=$(printf '%s' "${_HTTP_REDIRECT}" | sed -n 's/.*[?&]userIp=\([^&]*\).*/\1/p')
    _tusermac=$(printf '%s' "${_HTTP_REDIRECT}" | sed -n 's/.*[?&]userMac=\([^&]*\).*/\1/p')
    log "  sessionId=$_tsid customPageId=$_tpage"
    [ -z "$_tsid" ] && { log "未取得 sessionId，终止"; exit 1; }

    log "===== 阶段 2：获取登录页 ====="
    _tlq="flowSessionId=${_tsid}&customPageId=${_tpage}&preview=false&appType=normal&language=zh-CN&timer=$(date +%s)000"
    [ -n "$_tnasip" ] && _tlq="${_tlq}&nasIp=${_tnasip}"
    [ -n "$_tuserip" ] && _tlq="${_tlq}&userIp=${_tuserip}"
    [ -n "$_tusermac" ] && _tlq="${_tlq}&userMac=${_tusermac}"
    _tlq="${_tlq}&accept-language=zh-CN"
    _tlu="http://${PORTAL_HOST}/cas-sso/login?${_tlq}"
    _tref="http://${PORTAL_HOST}/portal/entry/pc/authenticate;flowParams=undefined;from="
    http_get "$_tlu" "$_tref" >/dev/null 2>&1
    _tpage_html=$(cat "$WORK_DIR/body" 2>/dev/null)
    _texec=$(extract_p "$_tpage_html" "login-page-flowkey")
    _tcry=$(extract_p "$_tpage_html" "login-croypto")
    log "  execution=${_texec:-<无>} (len ${#_texec})"
    log "  croypto=${_tcry:-<无>}"
    log "  body 字节数: $(wc -c <"$WORK_DIR/body" 2>/dev/null)"
    log "  cookie jar:"
    sed 's/^/    /' "$COOKIE_FILE" 2>/dev/null
    [ -z "$_texec" ] && { log "未取得 execution，终止"; exit 1; }

    log "===== 阶段 3：AES 加密 + 提交登录 ====="
    log "  账号=[${PORTAL_USER}] (长度 ${#PORTAL_USER})  密码长度 ${#PORTAL_PASS}"
    _tenc=$(aes_encrypt "$PORTAL_PASS" "$_tcry")
    log "  密码密文: ${_tenc:-<加密失败>}"
    [ -z "$_tenc" ] && { log "加密失败，终止"; exit 1; }
    _tcap=$(aes_encrypt "{}" "$_tcry")
    log "  captcha_payload 密文: ${_tcap:-<加密失败>}"

    _tpost="username=$(urlencode "$PORTAL_USER")&type=UsernamePassword&_eventId=submit&geolocation=&execution=$(b64urlencode "$_texec")&captcha_code=&croypto=$(b64urlencode "$_tcry")&password=$(b64urlencode "$_tenc")&captcha_payload=$(b64urlencode "$_tcap")"
    log "  POST body 总长: ${#_tpost}"
    log "  POST body 前240字符: $(printf '%s' "$_tpost" | cut -c1-240)"
    printf '%s' "$_tpost" >"$WORK_DIR/postdata"
    log "  --- 实际发送（带 cookie）---"
    log "  发送的 Cookie: $(cookie_header)"
    http_post "$_tlu" "$WORK_DIR/postdata" "application/x-www-form-urlencoded" "$_tref" >/dev/null 2>&1
    _r=$?
    log "  rc=$_r"
    log "  redirect=<${_HTTP_REDIRECT:-无}>"
    log "  body 字节数: $(wc -c <"$WORK_DIR/body" 2>/dev/null)"
    log "  body 前300字节: $(head -c 300 "$WORK_DIR/body" 2>/dev/null)"
    log "  stderr 全文:"
    cat "$WORK_DIR/err" 2>/dev/null | sed 's/^/    /'
}

main() {
    load_conf

    # 无线开关这两个子命令不需要 HTTP 后端，放在 detect_backend 之前处理 ——
    # 否则在缺 curl/uclient-fetch 的环境里，连「恢复无线」这个逃生口都跑不了。
    case "$1" in
        --wifi-resume)
            if wifi_force_resume; then
                echo "无线已恢复（全部频段）"
            else
                echo "无线恢复失败：检查 /etc/config/wireless 与 wireless 服务" >&2
                exit 1
            fi
            exit 0
            ;;
        --wifi-pause)
            WIFI_PAUSE=1
            wifi_pause
            exit 0
            ;;
    esac

    detect_backend
    if [ -z "$HTTP_BACKEND" ]; then
        echo "错误: 未找到任何 HTTP 客户端（需要 curl / uclient-fetch / wget）" >&2
        exit 1
    fi
    mkdir -p "$WORK_DIR" 2>/dev/null

    case "$1" in
        --backend)
            echo "HTTP 后端: $HTTP_BACKEND"
            ;;
        --check)
            if check_online; then
                echo "在线（外网可访问）"
            else
                _ck_wan=$(wan_ip)
                [ -n "$_ck_wan" ] && echo "当前 WAN IP: $_ck_wan"
                portal_user_online
                case $? in
                    0) echo "已认证，但外网 TCP 不通（AC 未放行）" ;;
                    1) echo "离线（服务端判定：未认证）" ;;
                    *) echo "离线（外网不通，且无法向服务端确认）" ;;
                esac
            fi
            ;;
        --auth)
            # 手动认证的**默认**入口 —— LuCI「立即认证」按钮走这条。
            #
            # 和守护进程用同一套判断：先看在线，在线就不重复认证。
            # 为什么不让它无脑强制：已经在线时再跑一遍完整认证是白跑 ——
            #   1) 要建会话、取登录页、AES 加密、走 5 步工作流，一来一回十几秒；
            #   2) AC 对重复认证常常直接回 ACK_AUTH_REFUSE，看着像失败。
            #
            # 真要强制重跑（比如怀疑在线判定不准），用 --force-auth / --force-verbose，
            # 对应 LuCI 上的「强制重新认证」按钮。
            VERBOSE=1
            if check_online; then
                wifi_resume
                log "已在线，无需重复认证。"
                log "  （要强制重跑一遍完整认证流程，点「强制重新认证」或用 --force-auth）"
                exit 0
            fi
            log "离线，开始认证..."
            auth_run_and_resume
            exit $?
            ;;
        --force|--force-auth)
            # 真·强制：不查在线，直接跑完整认证流程
            auth_run_and_resume
            exit $?
            ;;
        --verbose|--force-verbose)
            VERBOSE=1
            auth_run_and_resume
            exit $?
            ;;
        --probe) probe_flow ;;
        --trace) trace_flow ;;
        *)
            # 守护进程路径（init.d 不带参数调用）
            if check_online; then
                # 在线 -> 确保无线是开着的（可能上一轮断网时被关掉了）
                wifi_resume
                log "已在线，无需认证。"
                exit 0
            fi
            log "离线，开始认证..."
            wifi_pause          # 断网 -> 关掉无线（总开关没启用时是空操作）
            auth_run_and_resume
            exit $?
            ;;
    esac
}

main "$@"
