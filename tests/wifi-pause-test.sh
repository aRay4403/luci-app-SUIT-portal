#!/bin/sh
###############################################################################
# 「断网暂停无线」—— 离线单测
#
# 把 uci / ubus / wifi 三个外部命令全部 stub 掉，验证纯逻辑：
#   · 频段识别（band 字段优先，channel 回退）
#   · 2.4G / 5G 开关的过滤结果
#   · wifi_pause / wifi_resume 的幂等性
#   · ⭐「按当初记录的那批 radio 恢复」—— 关着的时候用户改开关也不出错
#   · 总开关关闭时是彻底的空操作
#   · 命令行入口 --wifi-pause / --wifi-resume
#
# 不碰真机、不发网络请求，Windows Git Bash 也能跑。
#
# 用法： sh tests/wifi-pause-test.sh
###############################################################################
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PROG="$ROOT/pkg/suit-portal/usr/bin/suit-portal.sh"

TMP=$(mktemp -d 2>/dev/null)
[ -n "$TMP" ] || TMP="$HERE/.wifi-tmp.$$"
mkdir -p "$TMP/stub" "$TMP/work"

# 【必须】统一成 POSIX 路径。
#   Git Bash 的 `mktemp -d` 返回的是 Windows 风格路径（C:\Users\...\Temp\tmp.xxx），
#   这种路径塞进 PATH 会被 `:` 当成分隔符截断（`C:` 里的冒号！），
#   stub 目录直接失效 —— 表现为「stub 明明写好了，脚本却找不到 uci」。
TMP=$(cd "$TMP" && pwd)

FAIL=0
ok()  { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
bad() { printf '  \033[31m❌ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1（期望 [$3]，实际 [$2]）"; }
say() { printf '\n%s\n' "$*"; }

# ============================================================================
# stub：uci / ubus / wifi
# ============================================================================
cat >"$TMP/stub/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
  show)
    [ "$2" = "wireless" ] && printf '%s\n' \
      'wireless.radio0=wifi-device' \
      'wireless.radio0.band=2g' \
      'wireless.default_radio0=wifi-iface' \
      'wireless.radio1=wifi-device' \
      'wireless.radio1.band=5g' \
      'wireless.default_radio1=wifi-iface'
    ;;
  get)
    case "$2" in
      wireless.radio0.band)    printf '2g\n' ;;
      wireless.radio1.band)    printf '5g\n' ;;
      wireless.radio0.channel) printf '6\n' ;;
      wireless.radio1.channel) printf '149\n' ;;
      # suit-portal.main.* 一律返回空 —— 让脚本用自己的默认值
    esac
    ;;
esac
exit 0
EOF

cat >"$TMP/stub/ubus" <<'EOF'
#!/bin/sh
# ubus call network.wireless <down|up> '{"device":"radioX"}'
if [ "$1" = "call" ]; then
  _d=$(printf '%s' "$4" | sed -n 's/.*"device":"\([^"]*\)".*/\1/p')
  printf '%s %s\n' "$3" "$_d" >>"${UBUS_LOG:-/dev/null}"
fi
exit 0
EOF

cat >"$TMP/stub/wifi" <<'EOF'
#!/bin/sh
printf 'wifi %s\n' "$1" >>"${WIFI_LOG:-/dev/null}"
exit 0
EOF

# ⚠️ 必须自己兜一个 rm。
#   本机（WorkBuddy 宿主）把 `rm` 注入成了 safe-bin/rm 这个 shim：
#   单次调用要 ~8 秒，连续调用几次之后直接挂死 —— 实测第 3 次 wifi_pause
#   （内部 rm -f 标志文件）就再也回不来了。
#   真机（OpenWrt busybox）没有这层，所以这只是**测试环境**的坑，不是脚本的 bug。
cat >"$TMP/stub/rm" <<'EOF'
#!/bin/sh
exec /usr/bin/rm "$@"
EOF

chmod +x "$TMP/stub/uci" "$TMP/stub/ubus" "$TMP/stub/wifi" "$TMP/stub/rm" 2>/dev/null

# 本机把 `rm` 注入成了 safe-bin/rm 这个 shell **函数** ——
# 函数优先于 PATH，光在 PATH 前面塞 stub/rm 是盖不住的。
# 必须先把函数定义删掉，PATH 里的 stub 才会生效。
unset -f rm 2>/dev/null

export PATH="$TMP/stub:$PATH"
export UBUS_LOG="$TMP/ubus.log"
export WIFI_LOG="$TMP/wifi.log"
export WIFI_FLAG="$TMP/wifi.flag"
export LOG_FILE="$TMP/test.log"
export WORK_DIR="$TMP/work"

: >"$UBUS_LOG"; : >"$WIFI_LOG"; : >"$LOG_FILE"

# ============================================================================
# 载入脚本（去掉末尾的 main "$@"，只取函数定义）
# ============================================================================
sed '$d' "$PROG" >"$TMP/prog-lib.sh"
# shellcheck disable=SC1090
. "$TMP/prog-lib.sh"

LOG_FILE="$TMP/test.log"
WIFI_PAUSE=1
WIFI_PAUSE_2G=1
WIFI_PAUSE_5G=1

say "=========================================="
say " 断网暂停无线 —— 离线单测"
say "=========================================="

# ---------------------------------------------------------------------------
say "[1] 频段识别（band 字段）"
eq "radio0 -> 2.4G" "$(wifi_radio_band radio0)" "2g"
eq "radio1 -> 5G"   "$(wifi_radio_band radio1)" "5g"

# 没有 band 字段时用 channel 推（把 stub 换成只给 channel 的场景）
cat >"$TMP/stub/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
  show) [ "$2" = "wireless" ] && printf '%s\n' \
      'wireless.radio0=wifi-device' 'wireless.radio1=wifi-device' ;;
  get) case "$2" in
      wireless.radio0.channel) printf '6\n' ;;
      wireless.radio1.channel) printf '149\n' ;;
      wireless.radio2.channel) printf 'auto\n' ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$TMP/stub/uci" 2>/dev/null
eq "无 band、channel=6 -> 2.4G"    "$(wifi_radio_band radio0)" "2g"
eq "无 band、channel=149 -> 5G"    "$(wifi_radio_band radio1)" "5g"
eq "channel=auto -> unknown（不碰）" "$(wifi_radio_band radio2)" "unknown"

# 换回带 band 的 stub
cat >"$TMP/stub/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1" in
  show) [ "$2" = "wireless" ] && printf '%s\n' \
      'wireless.radio0=wifi-device' 'wireless.radio0.band=2g' \
      'wireless.radio1=wifi-device' 'wireless.radio1.band=5g' ;;
  get) case "$2" in
      wireless.radio0.band) printf '2g\n' ;;
      wireless.radio1.band) printf '5g\n' ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$TMP/stub/uci" 2>/dev/null

# ---------------------------------------------------------------------------
say "[2] 频段过滤"
eq "默认（两个都关）"      "$(wifi_target_radios | tr '\n' ' ')" "radio0 radio1 "
WIFI_PAUSE_2G=0
eq "只关 5G"               "$(wifi_target_radios | tr '\n' ' ')" "radio1 "
WIFI_PAUSE_2G=1; WIFI_PAUSE_5G=0
eq "只关 2.4G"             "$(wifi_target_radios | tr '\n' ' ')" "radio0 "
WIFI_PAUSE_2G=0; WIFI_PAUSE_5G=0
eq "两个都保留 -> 空列表"  "$(wifi_target_radios | tr '\n' ' ')" ""
WIFI_PAUSE_2G=1; WIFI_PAUSE_5G=1

# ---------------------------------------------------------------------------
say "[3] wifi_pause / wifi_resume 基本行为"
rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
wifi_pause >/dev/null 2>&1
eq "暂停：下发 down radio0 + radio1" "$(tr '\n' ' ' <"$UBUS_LOG")" "down radio0 down radio1 "
eq "暂停：标志文件记录被关的 radio"  "$(tr '\n' ' ' <"$WIFI_FLAG")" "radio0 radio1 "

: >"$UBUS_LOG"
wifi_pause >/dev/null 2>&1
eq "重复调用幂等（不再下发 down）" "$(wc -c <"$UBUS_LOG" | tr -d ' ')" "0"

wifi_resume >/dev/null 2>&1
eq "恢复：下发 up radio0 + radio1" "$(tr '\n' ' ' <"$UBUS_LOG")" "up radio0 up radio1 "
[ -f "$WIFI_FLAG" ] && bad "恢复后标志应被删除" || ok "恢复后标志已删除"

: >"$UBUS_LOG"
wifi_resume >/dev/null 2>&1
eq "无标志时恢复是空操作（不误动用户自己关的无线）" "$(wc -c <"$UBUS_LOG" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
say "[4] 总开关关闭 = 彻底不动"
rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
WIFI_PAUSE=0
wifi_pause >/dev/null 2>&1
eq "WIFI_PAUSE=0 -> 不下发任何命令" "$(wc -c <"$UBUS_LOG" | tr -d ' ')" "0"
[ -f "$WIFI_FLAG" ] && bad "不应产生标志文件" || ok "未产生标志文件（后续也不会去恢复）"
WIFI_PAUSE=1

# ---------------------------------------------------------------------------
say "[5] 只关 5G：2.4G 完全不受影响"
WIFI_PAUSE_2G=0; WIFI_PAUSE_5G=1
rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
wifi_pause >/dev/null 2>&1
eq "只下发 down radio1" "$(tr '\n' ' ' <"$UBUS_LOG")" "down radio1 "
eq "标志只含 radio1"    "$(tr '\n' ' ' <"$WIFI_FLAG")" "radio1 "
wifi_resume >/dev/null 2>&1
eq "恢复也只 up radio1" "$(tr '\n' ' ' <"$UBUS_LOG")" "down radio1 up radio1 "
WIFI_PAUSE_2G=1

# ---------------------------------------------------------------------------
say "[6] ⭐ 关着的时候改了开关，恢复仍按当初记录"
rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
WIFI_PAUSE_2G=1; WIFI_PAUSE_5G=1
wifi_pause >/dev/null 2>&1            # 关掉 radio0 + radio1
WIFI_PAUSE_5G=0                       # 用户此时把 5G 开关关掉（想保留 5G）
wifi_resume >/dev/null 2>&1
eq "仍按记录把两个都开回来（radio1 不会漏掉）" \
   "$(tr '\n' ' ' <"$UBUS_LOG")" "down radio0 down radio1 up radio0 up radio1 "
WIFI_PAUSE_5G=1

# ---------------------------------------------------------------------------
say "[7] 逃生口 wifi_force_resume"
rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
wifi_force_resume >/dev/null 2>&1
eq "无条件 up 全部 radio（无视开关与标志）" "$(tr '\n' ' ' <"$UBUS_LOG")" "up radio0 up radio1 "

# ---------------------------------------------------------------------------
say "[8] 命令行入口"
# 加超时保护：万一子进程走到网络分支，不至于把整个测试挂住
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 30"

rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
WIFI_PAUSE=1 $TO sh "$PROG" --wifi-pause >"$TMP/cli1.out" 2>&1
eq "--wifi-pause 退出码 0" "$?" "0"
eq "--wifi-pause 关掉全部" "$(tr '\n' ' ' <"$UBUS_LOG")" "down radio0 down radio1 "

rm -f "$WIFI_FLAG"; : >"$UBUS_LOG"
$TO sh "$PROG" --wifi-resume >"$TMP/cli2.out" 2>&1
eq "--wifi-resume 退出码 0" "$?" "0"
eq "--wifi-resume 恢复全部" "$(tr '\n' ' ' <"$UBUS_LOG")" "up radio0 up radio1 "
grep -q "无线已恢复" "$TMP/cli2.out" && ok "--wifi-resume 有明确输出" \
    || bad "--wifi-resume 输出异常：$(cat "$TMP/cli2.out")"

# ---------------------------------------------------------------------------
rm -rf "$TMP"
say "=========================================="
if [ "$FAIL" -eq 0 ]; then
	printf '\033[32m 全部通过 ✔\033[0m\n'
	say "=========================================="
	exit 0
else
	printf '\033[31m 失败 %d 项 ✘\033[0m\n' "$FAIL"
	say "=========================================="
	exit 1
fi
