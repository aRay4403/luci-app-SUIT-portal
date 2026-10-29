#!/bin/sh
###############################################################################
# 下线 -> 等待 -> 重新认证 -> 等待放行 -> 验证
# 注意：绝不修改 MAC
###############################################################################

echo "===== 1. 下线 ====="
uclient-fetch -O - --timeout=8 --header="Content-Type: application/json" \
  --post-data='{"sessionId":"<会话ID>"}' \
  "http://10.10.16.56/eportal/network/offline" 2>&1 | tail -6

uclient-fetch -O /dev/null --timeout=8 \
  "http://10.10.16.56/cas-sso/logout?service=http%3A%2F%2F10.10.16.56%2Fportal%2Fpc%2FofflineSuccess" 2>&1 | head -4

echo
echo "===== 2. 等待 10 秒 ====="
sleep 10

echo
echo "===== 3. 重新认证 ====="
sh /tmp/full-flow.sh

echo
echo "===== 4. 等待 30 秒（等 AC 放行）====="
sleep 30

echo
echo "===== 5. 验证外网 ====="
uclient-fetch -O - --timeout=12 "http://123.123.123.123/" 2>&1 | head -10

echo
echo "===== 6. 再等 30 秒，二次验证 ====="
sleep 30
uclient-fetch -O - --timeout=12 "http://123.123.123.123/" 2>&1 | head -10
echo
echo "===== 完毕 ====="
