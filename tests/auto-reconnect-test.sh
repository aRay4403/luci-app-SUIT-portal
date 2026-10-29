#!/bin/sh
###############################################################################
# 模拟掉线 -> 验证守护进程能否自动重新认证
###############################################################################

echo "===== 1. 掉线前状态 ====="
/usr/bin/portal-auth.sh --check

echo
echo "===== 2. 主动下线（制造掉线）====="
ENTRY_PATH='/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'
{
  printf 'GET %s HTTP/1.0\r\n' "$ENTRY_PATH"
  printf 'Host: 10.10.16.56\r\n'
  printf 'User-Agent: Mozilla/5.0\r\n'
  printf 'Connection: close\r\n\r\n'
  sleep 2
} | nc 10.10.16.56 80 > /tmp/rr.raw 2>/dev/null
SID=$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' /tmp/rr.raw 2>/dev/null | tail -1 | sed -n 's/.*sessionId=\([^&]*\).*/\1/p')
echo "当前 sid=$SID"

uclient-fetch -O - --timeout=8 --header="Content-Type: application/json" \
  --post-data="{\"sessionId\":\"$SID\"}" \
  "http://10.10.16.56/eportal/network/offline" 2>&1 | grep -E '"code"|"message"' | head -3

echo
echo "===== 3. 掉线后立即确认 ====="
/usr/bin/portal-auth.sh --check

echo
echo "===== 4. 等待 50 秒（守护进程 30 秒一轮）====="
sleep 50

echo
echo "===== 5. 等待后状态（应已自动恢复）====="
/usr/bin/portal-auth.sh --check

echo
echo "===== 6. 日志（看是否自动重认证）====="
tail -30 /var/log/portal-auth.log
