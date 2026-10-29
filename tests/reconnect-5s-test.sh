#!/bin/sh
###############################################################################
# 断网恢复实测（在路由器上跑）
#   阶段 A：主动下线 -> 量出守护进程多久自动恢复
#   阶段 B：临时把入口 URL 改坏 -> 量出"认证失败"时的重试间隔是不是 5 秒
#           -> 还原配置 -> 确认能恢复
#
# 不碰 MAC 地址，不删改账号密码（只临时改 PORTAL_ENTRY_URL 并还原）
###############################################################################

ENTRY_PATH='/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'

kick_offline() {
    {
        printf 'GET %s HTTP/1.0\r\n' "$ENTRY_PATH"
        printf 'Host: 10.10.16.56\r\n'
        printf 'User-Agent: Mozilla/5.0\r\n'
        printf 'Connection: close\r\n\r\n'
        sleep 2
    } | nc 10.10.16.56 80 >/tmp/r5.raw 2>/dev/null
    _sid=$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' /tmp/r5.raw 2>/dev/null |
        tail -1 | sed -n 's/.*sessionId=\([^&]*\).*/\1/p')
    if [ -z "$_sid" ]; then
        echo "  !! 没拿到 sessionId，改用备用方式下线"
        return 1
    fi
    uclient-fetch -O - --timeout=8 --header='Content-Type: application/json' \
        --post-data="{\"sessionId\":\"$_sid\"}" \
        "http://10.10.16.56/eportal/network/offline" 2>&1 |
        grep -E '"code"|"message"' | head -3
    return 0
}

echo "===== 阶段 A：主动下线，量自动恢复耗时 ====="
cp /etc/portal-auth.conf /tmp/pa.conf.bak
echo "[A0] 当前: $(/usr/bin/portal-auth.sh --check)"
T0=$(date +%s)
echo "[A1] T0=$(date '+%H:%M:%S') 踢下线:"
kick_offline
echo "[A2] 刚下线: $(/usr/bin/portal-auth.sh --check)"

_i=0
while [ $_i -lt 30 ]; do
    sleep 2
    _i=$((_i + 1))
    if /usr/bin/portal-auth.sh --check >/dev/null 2>&1; then
        echo "[A3] 已在线！恢复耗时 $(( $(date +%s) - T0 )) 秒"
        break
    fi
done
[ $_i -ge 30 ] && echo "[A3] 60 秒内未恢复（异常）"

echo
echo "===== 阶段 B：制造认证失败，量重试间隔 ====="
sed -i "s|^PORTAL_ENTRY_URL=.*|PORTAL_ENTRY_URL='http://10.10.16.56/eportal/index.jsp?BROKEN=1'|" /etc/portal-auth.conf
echo "[B0] 入口已改坏: $(grep -c 'BROKEN' /etc/portal-auth.conf) 处"
echo "[B1] T0=$(date '+%H:%M:%S') 踢下线:"
kick_offline
echo "[B2] 观察 22 秒..."
sleep 22
echo "[B3] 失败期间的日志时间戳（间隔应≈5秒）:"
tail -8 /var/log/portal-auth.log |
    sed -n 's/^\[2026-09-28 \([0-9:]*\)\].*/\1/p' |
    awk 'NR==1{p=$1; print "  "$1"  <- 起点"} NR>1{split(p,a,":"); split($1,b,":"); d=(b[1]*3600+b[2]*60+b[3])-(a[1]*3600+a[2]*60+a[3]); printf "  %s  (+%d 秒)\n", $1, d; p=$1}'

echo
echo "===== 阶段 C：还原配置，确认能恢复 ====="
cp /tmp/pa.conf.bak /etc/portal-auth.conf
echo "[C0] 已还原，BROKEN 残留 $(grep -c 'BROKEN' /etc/portal-auth.conf) 处"
TC=$(date +%s)
_j=0
while [ $_j -lt 20 ]; do
    sleep 2
    _j=$((_j + 1))
    if /usr/bin/portal-auth.sh --check >/dev/null 2>&1; then
        echo "[C1] 已在线！恢复耗时 $(( $(date +%s) - TC )) 秒"
        break
    fi
done
[ $_j -ge 20 ] && echo "[C1] 40 秒内未恢复（异常，手动跑 --force 兜底）" && /usr/bin/portal-auth.sh --force >/dev/null 2>&1

echo
echo "===== 最终状态 ====="
/usr/bin/portal-auth.sh --check
echo "守护进程最近一次间隔: $(cat /var/run/portal-auth.state 2>/dev/null) 秒"
echo "--- 日志尾部 ---"
tail -12 /var/log/portal-auth.log
