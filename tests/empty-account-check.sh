#!/bin/sh
###############################################################################
# 空账号端到端验收：清空 UCI 账号密码后跑一次认证，应给出中文指引而非旧行为。
# 现场保护：无论成功失败，退出前都把账号密码还原。
###############################################################################
set -u

UCI=/etc/config/suit-portal
SCRIPT=/usr/bin/suit-portal.sh

echo "===== 0. 前置：遗留配置文件是否仍在（用来证明修复真的生效） ====="
if [ -f /etc/portal-auth.conf ]; then
	echo "  /etc/portal-auth.conf 存在（含旧凭据）—— 这正是之前的污染源"
	grep -E '^PORTAL_USER=' /etc/portal-auth.conf | sed 's/=.*/=<非空>/'
else
	echo "  /etc/portal-auth.conf 不存在"
fi

echo
echo "===== 1. 停服务，避免守护进程并发干扰 ====="
/etc/init.d/suit-portal stop 2>&1 | head -3
sleep 1

echo
echo "===== 2. 清空 UCI 账号密码 ====="
uci -q set suit-portal.main.username=''
uci -q set suit-portal.main.password=''
uci -q commit suit-portal
uci show suit-portal | grep -E 'username|password'

echo
echo "===== 3. 跑一次认证（--force-verbose）====="
"$SCRIPT" --force-verbose 2>&1
RC=$?
echo "退出码: $RC"

echo
echo "===== 4. 判定 ====="
if [ "$RC" -ne 0 ]; then
	echo "  [OK] 退出码非 0"
else
	echo "  [!!] 退出码为 0，未按预期失败"
fi

echo
echo "===== 5. 还原账号密码 ====="
uci -q set suit-portal.main.username='<你的账号>'
uci -q set suit-portal.main.password='<你的密码>'
uci -q commit suit-portal
uci show suit-portal | grep -E 'username|password'
/etc/init.d/suit-portal start >/dev/null 2>&1
sleep 1
echo "服务: $(/etc/init.d/suit-portal status 2>&1 | head -1)"

echo
echo "===== 6. 还原后自检 ====="
"$SCRIPT" --check 2>&1

exit 0
