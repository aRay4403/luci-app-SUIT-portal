#!/bin/sh
###############################################################################
# 一键诊断（在路由器上跑，把全部输出发回）
#   sh nc2.sh
###############################################################################

H="10.10.16.56"
P="80"
W="/tmp/nc2"; rm -rf "$W"; mkdir -p "$W"

echo "########## A. 基本信息 ##########"
echo "nc        : $(command -v nc)"
echo "nc 真实体 : $(readlink -f "$(command -v nc)" 2>/dev/null)"
echo "busybox   : $(busybox 2>&1 | head -1)"
echo "openssl   : $(command -v openssl)"
echo

echo "########## B. nc 连通性（GET /）##########"
printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$H" | nc -w 5 "$H" "$P" > "$W/b.txt" 2>"$W/b.err"
echo "退出码=$?  字节=$(wc -c <"$W/b.txt")  stderr=[$(cat "$W/b.err")]"
echo "--- 原始内容 ---"
cat "$W/b.txt"
echo "--- 结束 ---"
echo

echo "########## C. nc GET /self/index ##########"
printf 'GET /self/index HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc -w 5 "$H" "$P" > "$W/self.txt" 2>/dev/null
echo "字节=$(wc -c <"$W/self.txt")"
head -20 "$W/self.txt"
echo

echo "########## D. uclient-fetch 对比 GET / ##########"
uclient-fetch -O - "http://$H/" 2>&1 | head -12
echo

echo "########## E. uclient-fetch POST 行为（关键）##########"
echo "x=1" > "$W/p.bin"
echo "--- E1: POST 到 /cas-sso/login（无参数，看是否被当 GET）---"
uclient-fetch -O - --header="Content-Type: application/x-www-form-urlencoded" \
    --post-file="$W/p.bin" "http://$H/cas-sso/login" 2>&1 | head -20
echo
echo "--- E2: 同样请求，但打印响应码 ---"
uclient-fetch -q -O "$W/e2.out" --header="Content-Type: application/x-www-form-urlencoded" \
    --post-file="$W/p.bin" "http://$H/cas-sso/login" 2>&1
echo "退出码=$? 输出字节=$(wc -c <"$W/e2.out" 2>/dev/null)"
echo

echo "########## 完毕 ##########"
