#!/bin/sh
###############################################################################
# 在路由器后台采样：CPU 空闲率 + NFQUEUE 累计包数 + 负载
# 输出 /tmp/sample.txt，每行: HH:MM:SS idle=<0-100> q=<累计包数> load=<1分钟负载>
###############################################################################
: >/tmp/sample.txt
i=0
while [ $i -lt 100 ]; do
    idle=$(top -bn1 2>/dev/null | grep -oE "[0-9]+% idle" | head -1 | cut -d'%' -f1)
    pk=$(nft list chain inet UA3F POSTROUTING 2>/dev/null |
        grep -oE "packets [0-9]+" | tail -1 | cut -d' ' -f2)
    load=$(cut -d' ' -f1 </proc/loadavg)
    echo "$(date +%H:%M:%S) idle=${idle} q=${pk} load=${load}"
    i=$((i + 1))
    sleep 2
done
