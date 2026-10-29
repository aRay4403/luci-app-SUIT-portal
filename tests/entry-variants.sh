#!/bin/sh
# 测试：入口 URL 的加密参数是否是 userIp 的唯一来源
# 目的：若不带加密参数时 eportal 改用 TCP 源 IP，就能彻底摆脱「写死入口 URL」的坑。
BASE='http://10.10.16.56/eportal/index.jsp'
CACHED="$BASE"'?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'

echo "当前 WAN IP: $(ifstatus wan 2>/dev/null | sed -n 's/.*"address": "\([0-9.]*\)".*/\1/p' | head -1)"

i=0
for u in \
    "$CACHED" \
    "$BASE" \
    "$BASE?t=wireless-v2" \
    "$BASE?wlanuserip=<加密IP>" \
    "$BASE?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&nasip=<加密NASIP>&mac=<加密MAC>&t=wireless-v2" \
; do
    i=$((i + 1))
    echo "=== [$i] ${u%$BASE}"
    uclient-fetch -O /dev/null -T 10 "$u" 2>&1 \
        | grep -a "Redirected\|HTTP error\|Failed" | head -2 \
        | sed 's/^/    /'
done
