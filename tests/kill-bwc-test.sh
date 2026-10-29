#!/bin/sh
###############################################################################
# 清掉所有 luci-bwc，观察：① 负载是否回落 ② 它会不会重生 ③ 谁在拉起它
###############################################################################
echo "=== 清理前 ==="
echo "负载: $(cut -d' ' -f1 /proc/loadavg)   luci-bwc 数量: $(ps w | grep -c '[l]uci-bwc')"

echo
echo "=== 是否有 collectd / 统计类服务 ==="
ps w | grep -E "[c]ollectd|[r]rd|[s]tatistics" | cut -c1-100

echo
echo "=== 杀掉所有 luci-bwc ==="
for p in $(ps w | grep "[l]uci-bwc" | awk '{print $1}'); do
    echo "  kill $p"
    kill -9 "$p" 2>/dev/null
done

echo
echo "=== 清理后观察（每 10 秒一次，共 60 秒）==="
i=0
while [ $i -lt 6 ]; do
    sleep 10
    i=$((i + 1))
    echo "  ${i}0 秒后: 负载=$(cut -d' ' -f1 /proc/loadavg)  luci-bwc数量=$(ps w | grep -c '[l]uci-bwc')"
done

echo
echo "=== 若重生，查看其父进程 ==="
LB=$(ps w | grep "[l]uci-bwc" | head -1 | awk '{print $1}')
if [ -n "$LB" ]; then
    echo "重生实例 PID=$LB"
    PP=$(awk '{print $4}' "/proc/$LB/stat" 2>/dev/null)
    echo "父进程 PID=$PP"
    ps w | grep -E "^[[:space:]]*$PP[[:space:]]" | cut -c1-140
else
    echo "未重生 —— 说明是被外部周期性拉起的"
fi

echo
echo "=== 最终负载 ==="
cat /proc/loadavg
