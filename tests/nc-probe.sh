#!/bin/sh
###############################################################################
# nc 行为诊断（在 OpenWrt / ImmortalWrt 实机上跑）
#
# 目的：搞清楚本机 nc 到底怎么调才能拿到完整 HTTP 响应
# 用法：sh nc-probe.sh
# 把全部输出发回
###############################################################################

H="10.10.16.56"
P="80"

echo "########## 0) 环境 ##########"
echo "nc 路径: $(command -v nc)"
echo "nc 类型: $(ls -l $(command -v nc) 2>/dev/null)"
echo "busybox: $(command -v busybox)"
echo "--- busybox nc 帮助 ---"
busybox nc --help 2>&1 | head -20
echo "--- nc --help ---"
nc --help 2>&1 | head -20
echo

echo "########## 1) 方式A：echo | nc host port （当前脚本用法）##########"
printf 'GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc "$H" "$P" > /tmp/nc-a.txt 2>/tmp/nc-a.err
echo "退出码: $?"
echo "输出字节数: $(wc -c </tmp/nc-a.txt 2>/dev/null || echo N/A)"
echo "stderr: $(cat /tmp/nc-a.err 2>/dev/null)"
echo "--- 前 25 行 ---"
head -25 /tmp/nc-a.txt 2>/dev/null
echo

echo "########## 2) 方式B：加 -w 超时 ##########"
printf 'GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc -w 5 "$H" "$P" > /tmp/nc-b.txt 2>/tmp/nc-b.err
echo "退出码: $?"
echo "输出字节数: $(wc -c </tmp/nc-b.txt 2>/dev/null || echo N/A)"
echo "--- 前 25 行 ---"
head -25 /tmp/nc-b.txt 2>/dev/null
echo

echo "########## 3) 方式C：用 -q 0（EOF 后立即退出）##########"
printf 'GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc -q 0 "$H" "$P" > /tmp/nc-c.txt 2>/tmp/nc-c.err
echo "退出码: $?"
echo "输出字节数: $(wc -c </tmp/nc-c.txt 2>/dev/null || echo N/A)"
echo "--- 前 25 行 ---"
head -25 /tmp/nc-c.txt 2>/dev/null
echo

echo "########## 4) 方式D：HTTP/1.1 ##########"
printf 'GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc "$H" "$P" > /tmp/nc-d.txt 2>/dev/null
echo "退出码: $?"
echo "输出字节数: $(wc -c </tmp/nc-d.txt 2>/dev/null || echo N/A)"
echo "--- 前 25 行 ---"
head -25 /tmp/nc-d.txt 2>/dev/null
echo

echo "########## 5) 方式E：先看 TCP 通不通（nc -z 不对就跳过）##########"
nc -z -w 3 "$H" "$P" 2>&1 && echo "端口 $P 可连" || echo "nc -z 不支持或不可连（正常）"
echo "--- 直接 telnet 风格：echo 空 + 等 3 秒 ---"
(printf ''; sleep 1) | nc -w 3 "$H" "$P" > /tmp/nc-e.txt 2>/tmp/nc-e.err
echo "退出码: $?"
echo "输出字节数: $(wc -c </tmp/nc-e.txt 2>/dev/null || echo N/A)"
head -15 /tmp/nc-e.txt 2>/dev/null
echo

echo "########## 6) 方式F：GET /self/index ##########"
printf 'GET /self/index HTTP/1.0\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n' "$H" \
    | nc -w 5 "$H" "$P" > /tmp/nc-f.txt 2>/dev/null
echo "退出码: $?"
echo "输出字节数: $(wc -c </tmp/nc-f.txt 2>/dev/null || echo N/A)"
echo "--- 全部内容（前 40 行）---"
head -40 /tmp/nc-f.txt 2>/dev/null
echo

echo "########## 7) 对比：uclient-fetch 请求同一路径 ##########"
uclient-fetch -O - "http://$H/" 2>&1 | head -20
echo

echo "########## 8) 用 wget(busybox) 看响应头 ##########"
busybox wget -S -O /dev/null "http://$H/" 2>&1 | head -25
echo

echo "########## 完毕 ##########"
