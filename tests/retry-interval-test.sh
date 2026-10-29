#!/bin/sh
###############################################################################
# 验证"认证失败时的重试间隔 = 5 秒"
#
# 手法：把 PORTAL_HOST 临时指向一个不可达的内网 IP（10.10.16.99），
#      认证必然失败，但不会向学校服务器发错误密码（不触发任何账号风控）。
#      测完立刻用备份还原配置。
#
# 不碰 MAC 地址，不改账号密码。
###############################################################################

ENTRY_PATH='/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'

cp /etc/portal-auth.conf /tmp/pa.conf.bak2
echo "备份完成: $(wc -c </tmp/pa.conf.bak2) 字节"

echo
echo "===== 1. 先踢下线（用硬编码地址，不依赖配置）====="
{
    printf 'GET %s HTTP/1.0\r\n' "$ENTRY_PATH"
    printf 'Host: 10.10.16.56\r\n'
    printf 'User-Agent: Mozilla/5.0\r\n'
    printf 'Connection: close\r\n\r\n'
    sleep 2
} | nc 10.10.16.56 80 >/tmp/ri.raw 2>/dev/null
SID=$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' /tmp/ri.raw 2>/dev/null |
    tail -1 | sed -n 's/.*sessionId=\([^&]*\).*/\1/p')
if [ -n "$SID" ]; then
    uclient-fetch -O - --timeout=8 --header='Content-Type: application/json' \
        --post-data="{\"sessionId\":\"$SID\"}" \
        "http://10.10.16.56/eportal/network/offline" 2>&1 |
        grep -E '"code"' | head -1
    echo "已踢下线 $(date '+%H:%M:%S')"
else
    echo "没拿到 sessionId，跳过踢线"
fi

echo
echo "===== 2. 改坏服务器地址，制造持续失败 ====="
sed -i 's|^PORTAL_HOST=.*|PORTAL_HOST="10.10.16.99"|' /etc/portal-auth.conf
echo "现在 PORTAL_HOST=$(sed -n 's/^PORTAL_HOST=//p' /etc/portal-auth.conf)"

echo
echo "===== 3. 观察 45 秒（看重试是不是每 5 秒一次）====="
sleep 45

echo "每轮重试的起始时间戳:"
grep -n "离线，开始认证" /var/log/portal-auth.log | tail -12 |
    sed -n 's/^.*\[2026-09-28 \([0-9:]*\)\].*/\1/p' |
    awk 'NR==1{p=$1; printf "  %s  <- 起点\n", $1}
         NR>1{split(p,a,":"); split($1,b,":");
              d=(b[1]*3600+b[2]*60+b[3])-(a[1]*3600+a[2]*60+a[3]);
              printf "  %s  (+%d 秒)\n", $1, d; p=$1}'

echo
echo "状态文件记录的间隔: $(cat /var/run/portal-auth.state 2>/dev/null) 秒（失败时应为 5）"

echo
echo "===== 4. 还原配置，确认自动恢复 ====="
cp /tmp/pa.conf.bak2 /etc/portal-auth.conf
echo "已还原 PORTAL_HOST=$(sed -n 's/^PORTAL_HOST=//p' /etc/portal-auth.conf)"
TR=$(date +%s)
_i=0
while [ $_i -lt 25 ]; do
    sleep 2
    _i=$((_i + 1))
    if /usr/bin/portal-auth.sh --check >/dev/null 2>&1; then
        echo "已在线！还原后恢复耗时 $(($(date +%s) - TR)) 秒"
        break
    fi
done
[ $_i -ge 25 ] && echo "50 秒未恢复，手动兜底" && /usr/bin/portal-auth.sh --force >/dev/null 2>&1

echo
echo "===== 最终 ====="
/usr/bin/portal-auth.sh --check
echo "守护进程当前间隔: $(cat /var/run/portal-auth.state 2>/dev/null) 秒"
echo "--- 日志尾部 ---"
tail -5 /var/log/portal-auth.log
