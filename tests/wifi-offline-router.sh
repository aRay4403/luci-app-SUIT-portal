#!/bin/sh
###############################################################################
# 「断网 -> 自动关无线 -> 认证成功 -> 自动恢复」真机端到端验证
#
# 做法：把 online_check_urls 临时指向一个不可达地址，让守护进程判定「离线」，
#   观察它是否真的关掉无线；再把配置改回来，观察是否自动恢复。
#
# 【安全】
#   · 全程只动 network.wireless，不碰 network.interface.*，有线不受影响。
#   · 测试期间停掉守护进程避免干扰，末尾一定重新拉起来。
#   · 另挂一个看门狗，130 秒后无条件恢复无线 + 拉起服务，防卡死。
#
# 用法（在路由器上）： sh /tmp/wifi-offline.sh; cat /tmp/wifi-offline.log
###############################################################################

LOG=/tmp/wifi-offline.log
ORIG_UCI=/tmp/uci-before-wifitest.conf
FLAG=/tmp/.suit-portal-wifi-paused
PROG=/usr/bin/suit-portal.sh

exec >"$LOG" 2>&1

upcount() { ubus call network.wireless status 2>/dev/null | grep -c '"up": true'; }
stamp()   { date +%T; }

# ---- 看门狗：无论主流程如何，130 秒后强制恢复 ----
( sleep 130; "$PROG" --wifi-resume >/dev/null 2>&1
  /etc/init.d/suit-portal start >/dev/null 2>&1
  echo "[$(stamp)] 看门狗已执行（无线恢复 + 服务拉起）" ) >/tmp/wifi-offline-watchdog.log 2>&1 &

echo "=== 断网自动关无线 —— 真机验证 ==="

cp /etc/config/suit-portal "$ORIG_UCI"

echo ""
echo "[$(stamp)] ① 停掉守护进程（避免干扰），记录初始状态"
/etc/init.d/suit-portal stop >/dev/null 2>&1
sleep 2
echo "    初始 radio up 数: $(upcount)"

echo ""
echo "[$(stamp)] ② 模拟断网 + 开启 wifi_pause"
uci set suit-portal.main.online_check_urls='http://127.0.0.1:1/'
uci set suit-portal.main.wifi_pause='1'
uci set suit-portal.main.wifi_pause_2g='1'
uci set suit-portal.main.wifi_pause_5g='1'
uci commit suit-portal
uci show suit-portal | grep -E 'wifi_pause|online_check_urls'

echo ""
echo "[$(stamp)] ③ 跑守护进程路径（应判定离线 -> 关无线）"
"$PROG"
RC=$?
echo "    退出码: $RC"
sleep 2
AFTER_OFFLINE=$(upcount)
echo "    离线后 radio up 数: $AFTER_OFFLINE"
if [ -f "$FLAG" ]; then
	echo "    暂停标志: 存在（$(tr '\n' ' ' <"$FLAG")）"
else
	echo "    暂停标志: 不存在"
fi

echo ""
echo "[$(stamp)] ④ 恢复真实配置，再跑一次（应判定在线 -> 恢复无线）"
cp "$ORIG_UCI" /etc/config/suit-portal
uci commit suit-portal
uci show suit-portal | grep -E 'wifi_pause|online_check_urls'
sleep 1
"$PROG"
RC2=$?
echo "    退出码: $RC2"
sleep 3
AFTER_RESUME=$(upcount)
echo "    恢复后 radio up 数: $AFTER_RESUME"
if [ -f "$FLAG" ]; then
	echo "    暂停标志: 仍存在（异常）"
else
	echo "    暂停标志: 已清除"
fi

echo ""
echo "[$(stamp)] ⑤ 重新启动守护进程"
/etc/init.d/suit-portal start >/dev/null 2>&1
sleep 2
echo "    服务状态: $(/etc/init.d/suit-portal status 2>&1 | head -1)"

echo ""
echo "=== 判定 ==="
# 【为什么看日志而不是看最终 radio 状态】主流程是同步跑的：等脚本返回时，
#   如果认证成功，无线**已经恢复**了 —— 此时再量 radio up 必然是 2，
#   根本量不出「中间确实关过」。所以改成在日志里找那两个动作。
if grep -q "无线已关闭" "$LOG"; then
	echo "✅ 离线时确实关掉了无线（日志：无线已关闭）"
else
	echo "❌ 日志里没有「无线已关闭」—— 离线时没关"
fi
if grep -q "无线已恢复" "$LOG"; then
	echo "✅ 认证成功后确实恢复了无线（日志：无线已恢复）"
else
	echo "❌ 日志里没有「无线已恢复」—— 恢复没生效"
fi
[ ! -f "$FLAG" ] && echo "✅ 暂停标志已清除" || echo "❌ 暂停标志残留"
if ping -c 2 -w 3 "<上游网关IP>" >/dev/null 2>&1; then
	echo "✅ 有线（WAN）连通正常"
else
	echo "⚠ 上游网关不可达，需人工确认"
fi

echo ""
echo "[$(stamp)] === 结束 ==="
