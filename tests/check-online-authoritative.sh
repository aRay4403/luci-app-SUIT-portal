#!/bin/sh
###############################################################################
# 权威在线判定：conntrack 实际连接 + eportal userOnline
# 不依赖「探测外网 IP」这种会被策略影响的方式
###############################################################################

echo "===== 1. 实际已建立的外网 TCP 连接（最有说服力）====="
echo "--- 非局域网的 ESTABLISHED 连接 ---"
cat /proc/net/nf_conntrack 2>/dev/null | grep ESTABLISHED | grep -v "src=192.168.1." | head -10
echo "ESTABLISHED 总数: $(cat /proc/net/nf_conntrack 2>/dev/null | grep -c ESTABLISHED)"
echo "SYN_SENT 总数:    $(cat /proc/net/nf_conntrack 2>/dev/null | grep -c SYN_SENT)"

echo
echo "===== 2. eportal userOnline（服务端权威）====="
ENTRY_PATH='/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'
{
  printf 'GET %s HTTP/1.0\r\n' "$ENTRY_PATH"
  printf 'Host: 10.10.16.56\r\n'
  printf 'User-Agent: Mozilla/5.0\r\n'
  printf 'Connection: close\r\n\r\n'
  sleep 2
} | nc 10.10.16.56 80 > /tmp/chk.raw 2>/dev/null
LOC=$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' /tmp/chk.raw | tail -1 | sed 's/[[:space:]]*$//')
SID=$(printf '%s' "$LOC" | sed -n 's/.*sessionId=\([^&]*\).*/\1/p')
echo "新 sessionId=$SID"

uclient-fetch -O - --timeout=8 --header="Content-Type: application/json" \
  --post-data="{\"sessionId\":\"$SID\"}" \
  "http://10.10.16.56/eportal/network/userOnline" 2>&1 | grep -vE "^(Downloading|Connecting|Writing|-|Download)" 

echo
echo "===== 3. 外网 TCP 探测（仅供参考）====="
uclient-fetch -O - --timeout=10 "http://123.123.123.123/" 2>&1 | head -6

echo
echo "===== 完毕 ====="
