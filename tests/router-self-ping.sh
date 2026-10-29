#!/bin/sh
###############################################################################
# 路由器自检：ping 自己（回环 + 自身 LAN IP），同时采样 CPU 与 lan1 流量
#
# 目的：如果路由器 ping 自己都出现尖峰 -> 路由器 CPU/内部有问题
#       如果 ping 自己干净                 -> 路由器无责，尖峰在链路或对端
###############################################################################
N="${1:-80}"

rx0=$(cat /sys/class/net/lan1/statistics/rx_bytes 2>/dev/null || echo 0)
tx0=$(cat /sys/class/net/lan1/statistics/tx_bytes 2>/dev/null || echo 0)

echo "时刻     回环ms  自身LANms  CPU空闲%  lan1流量(KB/s)"
i=0
while [ $i -lt "$N" ]; do
    a=$(ping -c 1 -W 2 127.0.0.1 2>/dev/null | grep -oE "time=[0-9.]+" | head -1 | cut -d= -f2)
    b=$(ping -c 1 -W 2 192.168.1.1 2>/dev/null | grep -oE "time=[0-9.]+" | head -1 | cut -d= -f2)
    idle=$(top -bn1 2>/dev/null | grep -oE "[0-9]+% idle" | head -1 | cut -d'%' -f1)
    rx1=$(cat /sys/class/net/lan1/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/lan1/statistics/tx_bytes 2>/dev/null || echo 0)
    kbps=$(( (rx1 - rx0 + tx1 - tx0) / 1024 ))
    rx0=$rx1; tx0=$tx1
    mark=""
    [ -n "$b" ] && [ "$(printf '%.0f' "$b" 2>/dev/null || echo 0)" -ge 3 ] && mark="  <== 尖峰"
    echo "$(date +%H:%M:%S)  ${a:-TO}  ${b:-TO}  ${idle}  ${kbps}${mark}"
    i=$((i + 1))
    sleep 1
done
