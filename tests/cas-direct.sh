#!/bin/sh
###############################################################################
# 绕过 AC 劫持，直接构造 CAS 登录 —— 验证能否完成认证
# 在路由器上跑：sh cas-direct.sh
###############################################################################

BASE_HOST="10.10.16.56"
BASE="http://$BASE_HOST"
USERIP="<内网IP>"
USERMAC="<你的MAC>"
NASIP="10.0.0.13"
PAGEID="<页面ID>"
USER="<你的账号>"
PASS="<你的密码>"
HOLD=2

W=/tmp/casd; rm -rf "$W"; mkdir -p "$W"

# --- 裸 HTTP GET（保活，等响应收完）---
ncget() {   # ncget <path> <outfile>
    { printf 'GET %s HTTP/1.0\r\n' "$1"
      printf 'Host: %s\r\n' "$BASE_HOST"
      printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
      printf 'Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n'
      printf 'Accept-Language: zh-CN,zh;q=0.9\r\n'
      [ -s "$W/ck" ] && printf 'Cookie: %s\r\n' "$(cat "$W/ck")"
      printf 'Connection: close\r\n\r\n'
      sleep "$HOLD"
    } | nc "$BASE_HOST" 80 > "$2" 2>/dev/null
}

echo "########## 0. 建立 CAS 会话（HAR 里先走 logout）##########"
ncget "/cas-sso/logout?service=http%3A%2F%2F$BASE_HOST%2Fportal%2Fpc%2FofflineSuccess" "$W/lo.raw"
echo "响应: $(sed -n '1p' "$W/lo.raw")  字节=$(wc -c <"$W/lo.raw")"
sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*\([^;]*\).*/\1/p' "$W/lo.raw" >> "$W/ck"
echo "cookie: [$(cat "$W/ck" 2>/dev/null | tr '\n' ';')]"

echo
echo "########## 1. GET 登录页 ##########"
FLOWSID="${FLOWSID:-<会话ID>}"
LOGIN_QS="flowSessionId=$FLOWSID&customPageId=$PAGEID&preview=false&appType=normal&language=zh-CN&timer=$(date +%s)000&nasIp=$NASIP&userIp=$USERIP&userMac=$USERMAC&accept-language=zh-CN"
LOGIN_PATH="/cas-sso/login?$LOGIN_QS"
ncget "$LOGIN_PATH" "$W/lp.raw"
echo "响应字节: $(wc -c <"$W/lp.raw")"
echo "状态: $(sed -n '1p' "$W/lp.raw")"

# 抽 cookie
sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*\([^;]*\).*/\1/p' "$W/lp.raw" > "$W/ck"
echo "cookie: [$(cat "$W/ck" | tr '\n' ';')]"

# 抽 body
sed -n '/^\r*$/,$p' "$W/lp.raw" | sed '1d' > "$W/lp.html"
echo "body 字节: $(wc -c <"$W/lp.html")"

EXEC=$(sed -n 's/.*login-page-flowkey">\([^<]*\).*/\1/p' "$W/lp.html" | head -1)
CRO=$(sed -n 's/.*login-croypto">\([^<]*\).*/\1/p' "$W/lp.html" | head -1)
echo "execution 长度: ${#EXEC}"
echo "croypto: $CRO"

[ -z "$CRO" ] && { echo "!! 未解析到 croypto，终止"; exit 1; }

echo
echo "########## 2. AES 加密 ##########"
KEYHEX=$(printf '%s' "$CRO" | openssl base64 -d -A 2>/dev/null | hexdump -v -e '/1 "%02x"')
echo "key(hex): $KEYHEX"
enc() {
    printf '%s' "$1" | openssl enc -aes-128-ecb -K "$KEYHEX" -nosalt -base64 -A 2>/dev/null
}
ENCPW=$(enc "$PASS")
ENCAP=$(enc "{}")
echo "密码密文: $ENCPW"
echo "captcha密文: $ENCAP"

echo
echo "########## 3. POST 登录 ##########"
BODY="username=$USER&type=UsernamePassword&_eventId=submit&geolocation=&execution=$EXEC&captcha_code=&croypto=$CRO&password=$ENCPW&captcha_payload=$ENCAP"
printf '%s' "$BODY" > "$W/post"
BLEN=$(wc -c <"$W/post")
echo "body 字节: $BLEN"

{
    printf 'POST %s HTTP/1.0\r\n' "$LOGIN_PATH"
    printf 'Host: %s\r\n' "$BASE_HOST"
    printf 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36\r\n'
    printf 'Content-Type: application/x-www-form-urlencoded\r\n'
    printf 'Content-Length: %s\r\n' "$BLEN"
    printf 'Accept: text/html,application/xhtml+xml,*/*;q=0.8\r\n'
    printf 'Accept-Language: zh-CN,zh;q=0.9\r\n'
    printf 'Origin: http://%s\r\n' "$BASE_HOST"
    printf 'Referer: http://%s/portal/entry/pc/authenticate;flowParams=undefined;from=\r\n' "$BASE_HOST"
    [ -s "$W/ck" ] && printf 'Cookie: %s\r\n' "$(cat "$W/ck")"
    printf 'Connection: close\r\n\r\n'
    cat "$W/post"
    sleep "$HOLD"
} | nc "$BASE_HOST" 80 > "$W/post.raw" 2>/dev/null

echo "响应字节: $(wc -c <"$W/post.raw")"
echo "--- 响应头 ---"
sed -n '1,/^\r*$/p' "$W/post.raw" | head -20
LOC=$(sed -n 's/^[Ll]ocation:[[:space:]]*\(.*\)\r*$/\1/p' "$W/post.raw" | tail -1 | sed 's/[[:space:]]*$//')
echo "Location: [$LOC]"

# 抽新 cookie
sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*\([^;]*\).*/\1/p' "$W/post.raw" | while read -r c; do
    n=$(printf '%s' "$c" | sed 's/=.*//')
    grep -v "^$n=" "$W/ck" > "$W/ck.n" 2>/dev/null; mv "$W/ck.n" "$W/ck"
    printf '%s\n' "$c" >> "$W/ck"
done

TICKET=$(printf '%s' "$LOC" | sed -n 's/.*ticket=\([^&]*\).*/\1/p')
echo "ticket: [$TICKET]"

[ -z "$TICKET" ] && { echo "!! 未拿到 ticket"; echo "body 前 400:"; sed -n '/^\r*$/,$p' "$W/post.raw" | sed '1d' | head -c 400; exit 1; }

echo
echo "########## 4. GET auth-success.html (完成绑定) ##########"
SUCC_PATH="/portal/assets/auth-success.html?ticket=$TICKET&i18n_lang=zh"
ncget "$SUCC_PATH" "$W/succ.raw"
echo "响应字节: $(wc -c <"$W/succ.raw")"
echo "状态: $(sed -n '1p' "$W/succ.raw")"
sed -n '1,/^\r*$/p' "$W/succ.raw" | head -12

echo
echo "########## 5. 测试外网 ##########"
uclient-fetch -O - --timeout=10 "http://123.123.123.123/" 2>&1 | head -8
echo
echo "########## 完毕 ##########"
