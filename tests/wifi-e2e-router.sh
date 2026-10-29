#!/bin/sh
###############################################################################
# 「断网暂停无线」—— 真机端到端验证（在路由器上跑）
#
# 做什么：
#   ① 记录初始状态（radio up 数、无线接口列表）
#   ② 调 --wifi-pause，确认 radio 真的 down 了、标志文件写对了
#   ③ 调 --wifi-resume，确认 radio 回来了、标志清掉了
#   ④ 有线连通性自检 —— 确认只动了无线，没误伤 WAN/LAN
#
# 【安全边界】全程只碰 network.wireless，绝不碰 network.interface.*，
#   所以有线（WAN=eth1 / LAN=br-lan）不受影响。
#
# 用法（在路由器上）：
#   PROG=/tmp/suit-portal-new.sh sh /tmp/wifi-e2e.sh; cat /tmp/wifi-e2e.log
###############################################################################

PROG="${PROG:-/tmp/suit-portal-new.sh}"
LOG=/tmp/wifi-e2e.log
FLAG=/tmp/.suit-portal-wifi-paused

exec >"$LOG" 2>&1

upcount() { ubus call network.wireless status 2>/dev/null | grep -c '"up": true'; }
ifaces()  { iw dev 2>/dev/null | sed -n 's/.*Interface \(.*\)/\1/p' | tr '\n' ' '; }
stamp()   { date +%T; }

echo "=== 真机「断网暂停无线」端到端验证 ==="
echo "脚本: $PROG"
echo ""

echo "[$(stamp)] ① 初始状态"
INIT_UP=$(upcount)
INIT_IF=$(ifaces)
echo "    radio up 数: $INIT_UP"
echo "    无线接口: $INIT_IF"

echo ""
echo "[$(stamp)] ② 暂停无线（--wifi-pause）"
rm -f "$FLAG"
"$PROG" --wifi-pause
sleep 3
PAUSE_UP=$(upcount)
PAUSE_IF=$(ifaces)
echo "    radio up 数: $PAUSE_UP"
echo "    无线接口: ${PAUSE_IF:-<无>}"
echo "    标志文件内容: $(cat "$FLAG" 2>/dev/null | tr '\n' ' ')"

echo ""
echo "[$(stamp)] ③ 恢复无线（--wifi-resume）"
"$PROG" --wifi-resume
sleep 8
RESUME_UP=$(upcount)
RESUME_IF=$(ifaces)
echo "    radio up 数: $RESUME_UP"
echo "    无线接口: $RESUME_IF"
if [ -f "$FLAG" ]; then echo "    标志文件: 仍存在"; else echo "    标志文件: 已清除"; fi

echo ""
echo "=== 判定 ==="
if [ "$PAUSE_UP" -lt "$INIT_UP" ]; then
	echo "✅ 暂停生效：radio up 从 $INIT_UP 降到 $PAUSE_UP"
else
	echo "❌ 暂停未生效：radio up 仍为 $PAUSE_UP"
fi
if [ "$RESUME_UP" -eq "$INIT_UP" ]; then
	echo "✅ 恢复成功：radio up 回到 $RESUME_UP"
else
	echo "❌ 恢复异常：radio up = $RESUME_UP（初始 $INIT_UP）"
fi
if [ ! -f "$FLAG" ]; then echo "✅ 标志文件已清除"; else echo "❌ 标志文件残留"; fi

echo ""
echo "[$(stamp)] ④ 有线连通性自检（确认没被误伤）"
if ping -c 2 -w 3 "<上游网关IP>" >/dev/null 2>&1; then
	echo "✅ 上游网关 <上游网关IP> 可达（WAN 正常）"
else
	echo "⚠ 上游网关 <上游网关IP> 不可达（可能本来就不通，需人工确认）"
fi
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
echo "    LAN 地址: ${LAN_IP:-<无>}"
if [ -n "$LAN_IP" ]; then echo "✅ LAN 接口正常持有地址"; else echo "❌ LAN 地址丢失"; fi

echo ""
echo "[$(stamp)] === 结束 ==="
