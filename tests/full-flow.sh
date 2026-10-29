#!/bin/sh
###############################################################################
# 完整认证流程（不依赖 AC 劫持，复用固定 eportal 入口）
# 在路由器上跑：sh full-flow.sh
###############################################################################

BASE_HOST="10.10.16.56"
BASE="http://$BASE_HOST"
USERIP="<内网IP>"
USERMAC="<你的MAC>"
NASIP="10.0.0.13"
PAGEID="<页面ID>"
USER="<你的账号>"
PASS="<你的密码>"
SERVICE="电信宽带"
HOLD=2

ENTRY='http://10.10.16.56/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>'

W=/tmp/full; rm -rf "$W"; mkdir -p "$W"
CK="$W/ck"; : > "$CK"

ckhdr() {
    [ -s "$CK" ] || return 0
    printf 'Cookie: %s\r\n' "$(tr '\n' ';' < "$CK" | sed 's/;$//; s/;/; /g')"
}
ckabsorb() {
    sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*\([^;]*\).*/\1/p' "$1" 2>/dev/null | while IFS= read -r c; do
        [ -z "$c" ] && continue
        n=$(printf '%s' "$c" | sed 's/=.*//')
        v=$(printf '%s' "$c" | sed 's/^[^=]*=//')
        grep -v "^$n=" "$CK" > "$CK.n" 2>/dev/null; mv "$CK.n" "$CK" 2>/dev/null
        [ -n "$v" ] && printf '%s\n' "$c" >> "$CK"
    done
}
ncget() {
    { printf 'GET %s HTTP/1.0\r\n' "$1"
      printf 'Host: %s\r\n' "$BASE_HOST"
      printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
      printf 'Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n'
      printf 'Accept-Language: zh-CN,zh;q=0.9\r\n'
      ckhdr
      printf 'Connection: close\r\n\r\n'
      sleep "$HOLD"
    } | nc "$BASE_HOST" 80 > "$2" 2>/dev/null
}
ncpost() {   # ncpost <bodyfile> <out> <path> <referer>
    _b="$1"; _out="$2"; _path="$3"; _ref="$4"
    _len=$(wc -c < "$_b")
    { printf 'POST %s HTTP/1.0\r\n' "$_path"
      printf 'Host: %s\r\n' "$BASE_HOST"
      printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
      printf 'Content-Type: application/json\r\n'
      printf 'Content-Length: %s\r\n' "$_len"
      [ -n "$_ref" ] && printf 'Referer: %s\r\n' "$_ref"
      ckhdr
      printf 'Connection: close\r\n\r\n'
      cat "$_b"
      sleep "$HOLD"
    } | nc "$BASE_HOST" 80 > "$_out" 2>/dev/null
}
ncbody() { sed -n '/^\r*$/,$p' "$1" 2>/dev/null | sed '1d'; }
ncloc()  { sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' "$1" 2>/dev/null | tail -1 | sed 's/[[:space:]]*$//'; }

echo "===== 1. eportal 入口 ====="
ENTRY_PATH=$(printf '%s' "$ENTRY" | sed 's|^[a-z]*://[^/]*||')
ncget "$ENTRY_PATH" "$W/entry.raw"
LOC=$(ncloc "$W/entry.raw")
SID=$(printf '%s' "$LOC" | sed -n 's/.*sessionId=\([^&]*\).*/\1/p')
echo "sessionId=$SID"
[ -z "$SID" ] && { echo "!! 未拿到 sessionId"; exit 1; }

echo "===== 2. CAS logout（建立会话）====="
ncget "/cas-sso/logout?service=http%3A%2F%2F$BASE_HOST%2Fportal%2Fpc%2FofflineSuccess" "$W/lo.raw"
ckabsorb "$W/lo.raw"
echo "cookie: $(tr '\n' ';' < "$CK")"

echo "===== 3. CAS 登录页 ====="
LOGIN_PATH="/cas-sso/login?flowSessionId=$SID&customPageId=$PAGEID&preview=false&appType=normal&language=zh-CN&timer=$(date +%s)000&nasIp=$NASIP&userIp=$USERIP&userMac=$USERMAC&accept-language=zh-CN"
ncget "$LOGIN_PATH" "$W/lp.raw"
ckabsorb "$W/lp.raw"
ncbody "$W/lp.raw" > "$W/lp.html"
EXEC=$(sed -n 's/.*login-page-flowkey">\([^<]*\).*/\1/p' "$W/lp.html" | head -1)
CRO=$(sed -n 's/.*login-croypto">\([^<]*\).*/\1/p' "$W/lp.html" | head -1)
echo "execution len=${#EXEC}  croypto=$CRO"
[ -z "$CRO" ] && { echo "!! 未解析到 croypto"; exit 1; }

echo "===== 4. POST 登录 ====="
KEYHEX=$(printf '%s' "$CRO" | openssl base64 -d -A 2>/dev/null | hexdump -v -e '/1 "%02x"')
enc() { printf '%s' "$1" | openssl enc -aes-128-ecb -K "$KEYHEX" -nosalt -base64 -A 2>/dev/null; }
ENCPW=$(enc "$PASS"); ENCAP=$(enc "{}")
BODY="username=$USER&type=UsernamePassword&_eventId=submit&geolocation=&execution=$EXEC&captcha_code=&croypto=$CRO&password=$ENCPW&captcha_payload=$ENCAP"
printf '%s' "$BODY" > "$W/post"
BLEN=$(wc -c < "$W/post")
{
  printf 'POST %s HTTP/1.0\r\n' "$LOGIN_PATH"
  printf 'Host: %s\r\n' "$BASE_HOST"
  printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
  printf 'Content-Type: application/x-www-form-urlencoded\r\n'
  printf 'Content-Length: %s\r\n' "$BLEN"
  printf 'Origin: http://%s\r\n' "$BASE_HOST"
  printf 'Referer: http://%s/portal/entry/pc/authenticate;flowParams=undefined;from=\r\n' "$BASE_HOST"
  ckhdr
  printf 'Connection: close\r\n\r\n'
  cat "$W/post"
  sleep "$HOLD"
} | nc "$BASE_HOST" 80 > "$W/post.raw" 2>/dev/null
echo "状态: $(sed -n '1p' "$W/post.raw")"
LOC2=$(ncloc "$W/post.raw")
TICKET=$(printf '%s' "$LOC2" | sed -n 's/.*ticket=\([^&]*\).*/\1/p')
echo "ticket=$TICKET"
[ -z "$TICKET" ] && { echo "!! 登录失败，body 前 300:"; ncbody "$W/post.raw" | head -c 300; echo; exit 1; }

echo "===== 5. getCurrentNode ====="
printf '{"sessionId":"%s","flowKey":"portal_auth"}' "$SID" > "$W/j1"
ncpost "$W/j1" "$W/r1" "/eportal/workFlow/getCurrentNode" "$BASE/portal/portal-main"
echo "节点: $(ncbody "$W/r1" | tr -d ' \n' | sed -n 's/.*"currentNodePath":"\([^"]*\)".*/\1/p')"

echo "===== 6. serviceSelection ====="
printf '{"sessionId":"%s"}' "$SID" > "$W/j2"
ncpost "$W/j2" "$W/r2" "/eportal/network/serviceSelection" "$BASE/portal/portal-main"
ncbody "$W/r2"

echo "===== 7. serviceLogin ====="
printf '{"sessionId":"%s","service":"%s"}' "$SID" "$SERVICE" > "$W/j3"
ncpost "$W/j3" "$W/r3" "/eportal/network/serviceLogin" "$BASE/portal/portal-main"
ncbody "$W/r3"

echo "===== 8. userOnline ====="
printf '{"sessionId":"%s"}' "$SID" > "$W/j4"
ncpost "$W/j4" "$W/r4" "/eportal/network/userOnline" "$BASE/portal/portal-main"
ncbody "$W/r4"

echo "===== 9. 探测外网 ====="
uclient-fetch -O - --timeout=10 "http://123.123.123.123/" 2>&1 | head -8
echo
echo "===== 完毕 ====="
