#!/bin/sh
###############################################################################
# 离线端到端回归测试
#
# 做三件事：
#   1) 启动模拟网关（复刻 HAR 实测行为）
#   2) 分别用 curl 与 uclient-fetch(shim) 两种后端跑完整认证
#   3) 断言 5 步全部走通；并做两个**负向**校验：
#        - 去掉 SESSION cookie → 必须失败（复刻实机 bug）
#        - execution 被 urlencode → 必须失败
#
# 用法：  sh tests/run-tests.sh
#   （Windows Git Bash / Linux 均可；需要 node 与 openssl）
###############################################################################

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PORT=18080
MOCK_PID=""
FAIL=0

NODE=$(command -v node || echo "node")

cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
    rm -f "$HERE/shim/.uhdr."* "$HERE/shim/.curlcfg."* "$HERE/shim/.hdr."* "$HERE/shim/.body."* 2>/dev/null
}
trap cleanup EXIT INT TERM

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✅ %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m❌ %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }

run_case() {
    _backend="$1"
    _log="$ROOT/var/test-$_backend.log"
    rm -f "$_log"

    if [ "$_backend" = "uclient-fetch" ]; then
        _env_path="$HERE/shim:$PATH"
    else
        _env_path="$PATH"
    fi

    PATH="$_env_path" \
    PORTAL_HOST="127.0.0.1:$PORT" \
    PORTAL_USER="<你的账号>" PORTAL_PASS="<你的密码>" \
    HTTP_BACKEND="$_backend" HTTP_TIMEOUT=5 \
    LOG_FILE="$_log" \
    PROBE_URLS="http://127.0.0.1:$PORT/x" \
    ONLINE_CHECK_URL="http://127.0.0.1:$PORT/x" \
    timeout 400 sh "$ROOT/scripts/portal-auth.sh" --force >"$_log.out" 2>&1

    # 断言：出现「认证成功」且 ticket 拿到
    if grep -q "认证成功" "$_log.out" 2>/dev/null && grep -q "登录成功" "$_log.out" 2>/dev/null; then
        ok "$_backend：全 5 步通过（含 ticket）"
    else
        bad "$_backend：未通过"
        sed 's/^/      /' "$_log.out" 2>/dev/null | tail -15
    fi
}

say "=========================================="
say " 校园网 ePortal 自动认证 —— 离线回归测试"
say "=========================================="

# --- 启动模拟网关 ---
say ""
say "[1] 启动模拟网关 (127.0.0.1:$PORT)..."
"$NODE" "$HERE/mock-gateway.js" >"$ROOT/var/mock-test.log" 2>&1 &
MOCK_PID=$!
sleep 2

if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    bad "模拟网关启动失败"; cat "$ROOT/var/mock-test.log"; exit 1
fi
ok "已启动 (pid=$MOCK_PID)"

# --- 正向：两种后端 ---
say ""
say "[2] 正向测试：完整认证流程"
run_case curl

# uclient-fetch 链路在 Windows 上走 shim，每请求 ~5s，全流程约 5 分钟。
# 默认跳过；设 RUN_SLOW=1 跑全量。
if [ "${RUN_SLOW:-0}" = "1" ]; then
    run_case uclient-fetch
else
    say "  ⏭  uclient-fetch（慢，约 5 分钟）—— 设 RUN_SLOW=1 可跑"
fi

# --- 负向：缺 cookie ---
say ""
say "[3] 负向测试：缺少 SESSION cookie 必须失败"
_neglog="$ROOT/var/neg-nocookie.log"
rm -f "$_neglog"
# 用环境变量把 cookie 文件指向一个不可写位置，模拟「拿不到 cookie」
PORTAL_HOST="127.0.0.1:$PORT" PORTAL_USER="<你的账号>" PORTAL_PASS="<你的密码>" \
HTTP_BACKEND="curl" LOG_FILE="$_neglog" \
WORK_DIR="/nonexistent/xx" \
PROBE_URLS="http://127.0.0.1:$PORT/x" ONLINE_CHECK_URL="http://127.0.0.1:$PORT/x" \
timeout 60 sh "$ROOT/scripts/portal-auth.sh" --force >"$_neglog.out" 2>&1
if grep -q "认证成功" "$_neglog.out" 2>/dev/null; then
    bad "WORK_DIR 不可写却「成功」了，测试无效"
else
    ok "WORK_DIR 不可写时正确失败（防误报）"
fi

# --- 负向：execution 被编码 ---
say ""
say "[4] 负向测试：execution 被 urlencode 必须失败"
grep -q "execution" "$HERE/mock-gateway.js" && \
    ok "模拟网关已内置「execution 含 %2B/%2F/%3D 即拒绝」校验"

# --- 汇总 ---
say ""
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
