/**
 * 模拟网关 + ePortal 服务器（用于离线端到端测试 portal-auth.sh）
 *
 * 依据 HAR（2026-09-28）实测行为复刻：
 *   [A] GET http://<任意外网>      -> 200, body 是注入的 JS 跳转
 *   [B] GET /                       -> 200, 下发 SESSION cookie（关键！）
 *   [C] GET /eportal/index.jsp?...  -> 302 Location: /portal/portal-main?sessionId=...
 *   [D] GET /portal/portal-main?... -> 200 SPA 空壳
 *   [E] GET /cas-sso/login?...      -> 200 登录页 (含 login-page-flowkey / login-croypto / login-captcha-payload)
 *   [F] POST /cas-sso/login         -> **必须带 SESSION cookie**，否则返回 200 登录页 HTML；
 *                                      带 cookie 且密码解密正确 -> 302 Location: auth-success.html?ticket=ST-xxx
 *   [G] POST /eportal/workFlow/getCurrentNode      -> 200 {"currentNodePath":"serviceSelection"}
 *   [H] POST /eportal/network/serviceSelection     -> 200 运营商列表
 *   [I] POST /eportal/network/serviceLogin         -> 200 {"authResult":"success"}
 *
 * 与真实 HAR 的逐字段对齐（entry 86）：
 *   - POST body 里 execution / croypto / password 均为**原样 base64**，未 urlencode
 *   - 存在 captcha_payload 字段
 *   - POST URL 尾部带 &accept-language=zh-CN
 *   - 带 Referer: /portal/entry/pc/authenticate;flowParams=undefined;from=
 */
const http = require('http');
const crypto = require('crypto');

const PORT = 18080;
const SELF = `http://127.0.0.1:${PORT}`;   // 测试时用自身地址替换真实网关
const SESSION_ID = '<会话ID>';
const PAGE_ID = '<页面ID>';
const USER_IP = '<内网IP>';
const USER_MAC = '<你的MAC>';
const NAS_IP = '10.0.0.13';
const REAL_CROYPTO = '5RpNbPt4pc869u8a1b4frA==';   // 演示用假密钥，与真实账号无关
const EXPECTED_PASS = 'demo-pass-1';
const EXPECTED_CIPHER = 'RVET5N6VgbAfq82H+BmC8A=='; // 上面那个密钥加密 demo-pass-1 的结果

// 与 HAR 一致的 SESSION cookie（形如 uuid）
const CAS_SESSION = '<会话ID>';

// 每次会话动态生成 execution / croypto（模拟真实行为）
// execution 与 HAR 同构：uuid + '_' + 超长 base64（含 + / =），用于验证「不可 urlencode」
let execution = crypto.randomUUID() + '_' + crypto.randomBytes(2400).toString('base64');
let croypto = REAL_CROYPTO;
let captchaPayload = crypto.randomBytes(16).toString('base64');   // 24 字符 base64

const log = (...a) => console.log('[mock]', ...a);

function send(res, code, headers, body) {
  res.writeHead(code, Object.assign({ 'Content-Type': 'text/html; charset=utf-8' }, headers));
  res.end(body == null ? '' : body);
}

// 从请求头里取 cookie 值
function getCookie(req, name) {
  const raw = req.headers.cookie || '';
  const m = raw.match(new RegExp('(?:^|;\\s*)' + name + '=([^;]*)'));
  return m ? m[1] : '';
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, `http://${req.headers.host}`);
  const p = u.pathname;
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    log(req.method, p.slice(0, 70), 'ck=' + (getCookie(req, 'SESSION') ? 'Y' : 'N'));

    // [B] 根路径 -> 302 到 /self/index（复刻实机：redirect=</self/index>）
    //     真实网络里 SESSION cookie 在这条链路的某个响应上下发，这里放在 /self/index
    if (p === '/') {
      return send(res, 302, { Location: '/self/index' }, '');
    }

    // [B2] /self/index -> 下发 SESSION cookie（复刻实机链路）
    if (p === '/self/index') {
      return send(res, 200,
        { 'Set-Cookie': `SESSION=${CAS_SESSION}; Path=/; HttpOnly` },
        '<!DOCTYPE html><html><body>portal self index</body></html>');
    }

    // [E] 登录页（必须在 POST 分支之前判断 method）
    if (p === '/cas-sso/login' && req.method === 'GET') {
      // 模拟真实：GET 登录页时也会校验/下发 SESSION
      const has = getCookie(req, 'SESSION');
      const setCookie = has ? {} : { 'Set-Cookie': `SESSION=${CAS_SESSION}; Path=/cas-sso/; HttpOnly` };
      const page = `<!DOCTYPE html><html><head><title>登录</title></head><body>
<form>
<p id="login-page-flowkey">${execution}</p>
<p id="login-croypto">${croypto}</p>
<p id="login-captcha-payload">${captchaPayload}</p>
</form></body></html>`;
      return send(res, 200, setCookie, page);
    }

    // [F] 提交登录 -> 必须带 SESSION cookie；校验 AES 密文 -> 302 ticket
    if (p === '/cas-sso/login' && req.method === 'POST') {
      // ★ 关键校验：无 SESSION cookie => 视为「新的 GET」，返回登录页 HTML（复刻实机失败现象）
      if (getCookie(req, 'SESSION') !== CAS_SESSION) {
        log('   !! 缺少/错误 SESSION cookie -> 返回登录页（模拟实机失败）');
        const page = `<!DOCTYPE html><html><head><title>登录</title></head><body>
<form><p id="login-page-flowkey">${execution}</p>
<p id="login-croypto">${croypto}</p></form></body></html>`;
        // 用填充逼近实机 33870+ 字节
        const pad = '<!--' + 'x'.repeat(33000) + '-->';
        return send(res, 200, {}, page + pad);
      }

      const params = new URLSearchParams(body);
      const user = params.get('username');
      const enc = params.get('password');
      const ck = params.get('croypto');
      const ex = params.get('execution');
      const cp = params.get('captcha_payload');
      log('   -> 用户:', user, '密文:', enc);
      log('   -> execution len:', (ex || '').length, 'captcha_payload:', cp);

      // ★ 关键校验：execution 若被 urlencode 过（含 %2B/%2F/%3D），服务端解不出
      if (ex && /%2[BbFf]|%3[Dd]/.test(ex)) {
        log('   !! execution 被 urlencode -> 拒绝（模拟实机解析失败）');
        return send(res, 200, {}, '登录失败: execution 编码错误');
      }

      // 【重要】URLSearchParams 会把 '+' 解成空格，但真实服务端（Java Spring）
      // 对 base64 字段是**原样取用**的（HAR 里浏览器发的就是未编码的 '+'）。
      // 因此这里按「原样」语义还原：把空格再转回 '+'（仅限 base64 字段）。
      const b64fix = (s) => (s || '').replace(/ /g, '+');
      const ckFixed = b64fix(ck);
      const encFixed = b64fix(enc);

      // 用服务器侧密钥独立验证（模拟真实服务端解密）
      let ok = false;
      try {
        const key = Buffer.from(ckFixed, 'base64');
        const dec = crypto.createDecipheriv('aes-128-ecb', key, null);
        dec.setAutoPadding(true);
        const plain = Buffer.concat([dec.update(Buffer.from(encFixed, 'base64')), dec.final()]).toString('utf8');
        log('   -> 服务端解密得到:', plain);
        ok = (plain === EXPECTED_PASS);
      } catch (e) {
        log('   -> 解密失败:', e.message);
      }

      if (ok) {
        const ticket = 'ST-MOCK-' + crypto.randomBytes(6).toString('hex');
        return send(res, 302, {
          Location: `${SELF}/portal/assets/auth-success.html?ticket=${ticket}&i18n_lang=zh`
        }, '');
      }
      return send(res, 200, {}, '登录失败: 密码错误');
    }

    // [A] 任何其他非 portal 请求 -> 注入 JS 跳转
    if (!/eportal|portal|cas-sso|sam|sso-public/.test(p)) {
      const inj = `<script>top.self.location.href='${SELF}/eportal/index.jsp?wlanuserip=<加密IP>&wlanacname=<加密AC标识>&ssid=&nasip=<加密NASIP>&snmpagentip=&mac=<加密MAC>&t=wireless-v2&url=<加密URL>&apmac=&nasid=<加密AC标识>&vid=<加密VID>&port=<加密PORT>&nasportid=<加密NASPORTID>a54772bab2d504ef'</script>`;
      return send(res, 200, { 'Content-Length': Buffer.byteLength(inj) }, inj);
    }

    // [C] eportal 入口 -> 302 portal-main
    if (p === '/eportal/index.jsp') {
      // 与实机一致：返回相对路径的 Location（含未编码空格）
      const loc = `/portal/portal-main?sessionId=${SESSION_ID}` +
        `&userIp=${USER_IP}&userMac=${USER_MAC}&nasIp=${NAS_IP}` +
        `&customPageId=${PAGE_ID}&redirectUrl=http://123.123.123.123/` +
        `&clearIdentitySelect=true&waitMac=false&getIdentityEnable=false` +
        `&terminalType=pc&accessTime=2026-09-28 10:39:51.086&guestFlow=false&terminalStatus=false`;
      return send(res, 302, { Location: loc }, '');
    }

    // [D] portal-main SPA 空壳
    if (p === '/portal/portal-main') {
      return send(res, 200, {}, '<!DOCTYPE html><html><head><base href="/portal/"></head><body>SPA</body></html>');
    }

    // [G] 工作流
    if (p === '/eportal/workFlow/getCurrentNode') {
      return send(res, 200, { 'Content-Type': 'application/json' },
        JSON.stringify({ code: 0, currentNodePath: 'serviceSelection', sessionId: SESSION_ID }));
    }

    // [H] 运营商列表
    if (p === '/eportal/network/serviceSelection') {
      return send(res, 200, { 'Content-Type': 'application/json' },
        JSON.stringify({ code: 0, data: [
          { key: 'default', name: '默认' },
          { key: '电信宽带', name: '电信宽带' },
          { key: '移动宽带', name: '移动宽带' }
        ] }));
    }

    // [I] 完成认证
    if (p === '/eportal/network/serviceLogin') {
      const params = JSON.parse(body || '{}');
      log('   -> 选定运营商:', params.service);
      return send(res, 200, { 'Content-Type': 'application/json' },
        JSON.stringify({ code: 0, authResult: 'success', authMessage: '认证成功' }));
    }

    send(res, 404, {}, 'not found');
  });
});

server.listen(PORT, '127.0.0.1', () => {
  log(`模拟网关已启动: http://127.0.0.1:${PORT}/`);
  log(`execution len=${execution.length}`);
  log(`croypto=${croypto}`);
  log(`SESSION=${CAS_SESSION}`);
});
