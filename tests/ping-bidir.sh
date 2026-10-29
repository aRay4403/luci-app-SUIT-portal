#!/bin/sh
###############################################################################
# 反向探测：从路由器 ping 局域网内的电脑（192.168.1.200）
#
# 目的：区分「延迟出在路由器/链路」还是「出在 Windows 本机」
#   · 路由器侧计时也出现尖峰 → 路由器 CPU / 链路的问题
#   · 路由器侧一直 <1ms，而 Windows 本机 ping 偶发几十 ms → 是 Windows 自己的调度延迟
#
# 同时采样 CPU 空闲率和 NFQUEUE 累计包数，便于看尖峰是否撞上高负载
###############################################################################
TARGET="${1:-192.168.1.200}"
N="${2:-60}"

echo "目标: $TARGET  次数: $N"
echo "时刻        RTT(ms)  CPU空闲%  NFQUEUE累计包数"
i=0
while [ $i -lt "$N" ]; do
    idle=$(top -bn1 2>/dev/null | grep -oE "[0-9]+% idle" | head -1 | cut -d'%' -f1)
    pk=$(nft list chain inet UA3F POSTROUTING 2>/dev/null |
        grep -oE "packets [0-9]+" | tail -1 | cut -d' ' -f2)
    t=$(ping -c 1 -W 2 "$TARGET" 2>/dev/null |
        grep -oE "time=[0-9.]+" | head -1 | cut -d'=' -f2)
    echo "$(date +%H:%M:%S)  ${t:-TIMEOUT}   ${idle}   ${pk}"
    i=$((i + 1))
    sleep 1
done
