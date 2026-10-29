#!/bin/sh
# 用历史捕获的 eportal 入口 URL 直接请求，看能否拿到 sessionId
U='http://10.10.16.56/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'

echo "=== 请求 eportal 入口（复用历史参数）==="
uclient-fetch -O - --timeout=12 "$U" 2>&1 | head -25
echo
echo "=== 探测外网 ==="
uclient-fetch -O - --timeout=8 "http://123.123.123.123/" 2>&1 | head -6
