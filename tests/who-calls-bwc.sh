#!/bin/sh
###############################################################################
# 确认 luci-bwc 是被谁反复调用的
###############################################################################
echo "=== 当前 luci-bwc 进程 ==="
ps w | grep "[l]uci-bwc" | head -3

LB=$(ps w | grep "[l]uci-bwc" | head -1 | awk '{print $1}')
if [ -n "$LB" ]; then
    PP=$(awk '{print $4}' "/proc/$LB/stat" 2>/dev/null)
    echo "luci-bwc PID=$LB  父进程 PID=$PP"
    echo "--- 父进程详情 ---"
    ps w | grep -E "^[[:space:]]*$PP[[:space:]]" | cut -c1-140
fi

echo
echo "=== uhttpd 进程数（含活跃请求子进程）==="
ps w | grep -c "[u]httpd"

echo
echo "=== 5 秒内 luci-bwc 出现次数（每秒一次）==="
i=0
while [ $i -lt 5 ]; do
    printf "%s " "$(ps w | grep -c '[l]uci-bwc')"
    sleep 1
    i=$((i + 1))
done
echo

echo
echo "=== 当前负载 ==="
cat /proc/loadavg
