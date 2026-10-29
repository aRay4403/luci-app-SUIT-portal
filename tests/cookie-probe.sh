#!/bin/sh
# 诊断：找出 SESSION cookie 到底从哪个响应下发
# 用法：sh cookie-probe.sh
# 在路由器上跑，把输出发回

H="10.10.16.56"
P="80"

echo "########## 0) 工具盘点 ##########"
for c in nc curl wget uclient-fetch openssl; do
    printf '%-14s: %s\n' "$c" "$(command -v $c 2>/dev/null || echo 无)"
done
echo

echo "########## 1) 裸 HTTP 抓响应头（nc）##########"
echo "--- GET / ---"
printf 'GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept-Language: zh-CN\r\nConnection: close\r\n\r\n' "$H" \
    | nc "$H" "$P" 2>&1 | head -30
echo
echo "--- GET /self/index ---"
printf 'GET /self/index HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc "$H" "$P" 2>&1 | head -30
echo

echo "########## 2) uclient-fetch 支持的选项（确认有无 cookie/响应头能力）##########"
uclient-fetch --help 2>&1 | head -40
echo
