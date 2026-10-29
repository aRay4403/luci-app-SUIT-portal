/*
 * LuCI 页面验证 —— 校园网自动认证（Argon 主题 + ImmortalWrt 25.12 / LuCI 26.236）
 *
 * 实测要点（2026-10-04）：
 *   - Argon 主题登录页的输入框 id 是 cbi-input-user / cbi-input-password，
 *     不是 luci_username / luci_password —— 用 input[name="luci_password"] 才通用。
 *   - LuCI 26.236 的 CBI 表单控件只写 id（widget.cbid.<pkg>.<sec>.<opt>），
 *     没有 name 属性；按 name 取值会全部拿不到。
 *   - 表单是异步渲染的，waitForSelector('#suit-state') 之后仍需留时间，
 *     状态栏靠 poll 每秒刷新，过早读取会读到「（服务未运行）」。
 */
module.exports = async ({ page, ok, shot, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';
	const ID = 'widget.cbid.suit-portal.main.';

	/* ---------------- 1. 登录 ---------------- */
	async function loginIfNeeded() {
		if (!await page.$('input[name="luci_password"]')) return false;
		await page.fill('input[name="luci_username"]', 'root');
		await page.fill('input[name="luci_password"]', '<你的路由器密码>');
		await Promise.all([
			page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {}),
			page.click('input[type="submit"], button[type="submit"]'),
		]);
		await wait(1500);
		return true;
	}

	const sawLogin = await loginIfNeeded();
	ok(sawLogin, '登录流程可用（首次进入为 LuCI 登录页并成功登录）');

	/* ---------------- 2. 重新加载目标页（只收集本页的错误） ---------------- */
	const errors = [];
	page.on('pageerror', e => errors.push('pageerror: ' + e.message));
	page.on('console', m => {
		if (m.type() === 'error') errors.push('console: ' + m.text());
	});

	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(4000);

	ok(page.url().indexOf('/admin/services/suit-portal') >= 0,
		'已登录并停留在目标页（未被弹回登录页）');

	/* ---------------- 3. 标题与说明 ---------------- */
	const h2 = await page.evaluate(() => {
		const e = document.querySelector('.cbi-map h2') || document.querySelector('h2');
		return e ? e.textContent.trim() : null;
	});
	ok(h2 === 'SUIT 校园网自动认证', '页面标题为「SUIT 校园网自动认证」（实际: ' + h2 + '）');

	const descr = await page.evaluate(() => {
		const e = document.querySelector('.cbi-map-descr');
		return e ? e.textContent.trim() : '';
	});
	console.log('  页面说明:', JSON.stringify(descr));
	ok(descr.indexOf('ePortal') >= 0, '页面说明文字已渲染（含 ePortal 字样）');
	ok(descr.indexOf('基于 SUIT 环境制作') >= 0, '页面说明里写明「基于 SUIT 环境制作」');
	// 说明保持短；学校归属靠标题的 SUIT 前缀 + 说明里这一句，不堆一长串英文校名
	ok(descr.indexOf('SHENZHEN') < 0 && descr.length < 110,
		'页面说明保持简短（不再堆一长串英文校名）');

	/* ---------------- 4. 状态栏（poll 每秒刷新） ---------------- */
	const stateText = ((await page.textContent('#suit-state').catch(() => '')) || '').trim();
	ok(/\d+\s*秒/.test(stateText),
		'状态栏显示轮询间隔，而非「服务未运行」（实际: ' + stateText + '）');

	/* ---------------- 5. 表单字段回显 ---------------- */
	const get = sel => page.$eval(sel, e => e.type === 'password' ? '__PWD__' : e.value)
		.catch(() => null);
	const sel = id => '[id="' + ID + id + '"]';

	const username = await get(sel('username'));
	const password = await get(sel('password'));
	const service = await get(sel('service'));
	const serviceTag = await page.$eval(sel('service'), e => e.tagName).catch(() => null);
	const serviceOpts = await page.$eval(sel('service'),
		e => e.tagName === 'SELECT'
			? Array.prototype.slice.call(e.options).map(x => x.value)
			: []).catch(() => []);
	const host = await get(sel('portal_host'));
	const ivOn = await get(sel('interval'));
	const ivOff = await get(sel('interval_offline'));
	const ivMax = await get(sel('interval_offline_max'));
	const checkUrls = await get(sel('online_check_urls'));
	const enabledOn = await page.$eval('[data-widget-id="' + ID + 'enabled"]', e => e.checked)
		.catch(() => null);

	// 不断言具体账号（仓库里是占位符，填了自己的值就会失败）——
	// 只要求「有值」，说明表单回显链路通。
	ok(!!username && username.length > 0,
		'校园网账号已回显（长度 ' + (username ? username.length : 0) + '）');
	ok(password === '__PWD__', '密码字段为 password 类型（不回显明文）');
	ok(serviceTag === 'SELECT', '运营商已改成下拉选择框（实际标签: ' + serviceTag + '）');
	ok(serviceOpts.length === 4,
		'运营商下拉有 4 个选项（实际: ' + JSON.stringify(serviceOpts) + '）');
	ok(serviceOpts.indexOf('default') >= 0
		&& serviceOpts.indexOf('电信宽带') >= 0 && serviceOpts.indexOf('移动宽带') >= 0
		&& serviceOpts.indexOf('联通宽带') >= 0,
		'下拉包含校园网(default) / 电信 / 移动 / 联通四项');
	// 不断言具体选中的是哪一项（各人配置不同）——只要求它在选项里
	ok(serviceOpts.indexOf(service) >= 0,
		'运营商当前值在下拉选项内（实际: ' + service + '）');
	ok(host === '10.10.16.56', '认证服务器回显正确（实际: ' + host + '）');
	ok(ivOn === '30', '在线检测间隔 = 30（实际: ' + ivOn + '）');
	ok(ivOff === '5', '掉线重试间隔 = 5（实际: ' + ivOff + '）');
	ok(ivMax === '60', '连续失败退避上限 = 60（实际: ' + ivMax + '）');
	ok(enabledOn === true, '「启用自动认证」开关为开');

	/*
	 * 「门户入口 URL」是**灰掉的只读框**：保留输入框，但 disabled ——
	 * 一眼能看出「不可修改」，也和 LuCI 其它只读字段保持一致。
	 *
	 * ⚠️ 只查 disabled 属性不够：Argon 自带的 disabled 底色实测只有
	 *    rgba(239,239,239,0.3)，叠在白底上跟普通输入框几乎没区别 ——
	 *    所以 portal.js 里另压了一层样式。这里拿旁边**可编辑**的
	 *    「在线探测地址」当对照，证明两者看上去确实不同。
	 *
	 * 按行 id 定位（LuCI 生成 cbi-<config>-<section>-<option>），免得以后改文案把断言带崩。
	 */
	const entryRow = await page.evaluate(() => {
		function snap(rowId) {
			const row = document.getElementById(rowId);
			const i = row ? row.querySelector('input') : null;
			if (!i) return null;
			const cs = getComputedStyle(i);
			return {
				tag: i.tagName, type: i.type, disabled: i.disabled,
				value: String(i.value), bg: cs.backgroundColor,
				cursor: cs.cursor, color: cs.color,
			};
		}
		const row = document.getElementById('cbi-suit-portal-main-entry_url');
		const descr = row ? row.querySelector('.cbi-value-description') : null;
		return {
			entry: snap('cbi-suit-portal-main-entry_url'),
			normal: snap('cbi-suit-portal-main-online_check_urls'),
			descr: descr ? descr.textContent.trim() : '',
		};
	});
	ok(entryRow && entryRow.entry, '「门户入口 URL」那一行存在');
	ok(entryRow && entryRow.entry.tag === 'INPUT' && entryRow.entry.type === 'text',
		'门户入口 URL 仍是输入框（不是裸文本）');
	ok(entryRow && entryRow.entry.disabled === true, '输入框是 disabled（不可修改）');
	ok(entryRow && entryRow.normal && entryRow.entry.bg !== entryRow.normal.bg,
		'灰框和旁边可编辑输入框底色不同 → 确实变灰了（' +
		(entryRow && entryRow.entry.bg) + ' vs ' + (entryRow && entryRow.normal.bg) + '）');
	ok(entryRow && entryRow.entry.cursor === 'not-allowed',
		'光标是 not-allowed（实际 ' + (entryRow && entryRow.entry.cursor) + '）');
	ok(entryRow && entryRow.entry.value.indexOf('eportal/index.jsp') >= 0,
		'门户入口 URL 已自动回写（含 eportal/index.jsp）');
	ok(entryRow && entryRow.descr.indexOf('无需配置') >= 0,
		'说明已标明「无需配置」（实际: ' + (entryRow && entryRow.descr) + '）');

	/* 真的打不进字 —— 不碰 JS，走真实键盘 */
	const entrySel = '#cbi-suit-portal-main-entry_url input';
	const entryBefore = await page.$eval(entrySel, e => e.value);
	await page.click(entrySel, { force: true }).catch(() => {});
	await page.keyboard.press('End');
	await page.keyboard.type('ZZZ');
	await wait(300);
	const entryAfter = await page.$eval(entrySel, e => e.value);
	ok(entryAfter === entryBefore, '真实键盘输入打不进去（值一字未变）');

	ok(!!checkUrls && checkUrls.indexOf('http') === 0, '在线探测地址已配置');

	/* ---------------- 6. 操作按钮 ---------------- */
	const btns = await page.$$eval('button', els => els.map(b => b.textContent.trim()));
	ok(btns.indexOf('立即认证') >= 0, '存在「立即认证」按钮');
	ok(btns.indexOf('强制重新认证') >= 0, '存在「强制重新认证」按钮（跳过在线检查的逃生口）');
	ok(btns.indexOf('查看日志') >= 0, '存在「查看日志」按钮');
	ok(btns.indexOf('重启服务') >= 0, '存在「重启服务」按钮');
	ok(btns.indexOf('恢复无线') >= 0, '存在「恢复无线」按钮（断网暂停无线的逃生口）');

	/* ---------------- 6b. 断网暂停无线：三个开关 ---------------- */
	const wifiPause = await page.$eval('[data-widget-id="' + ID + 'wifi_pause"]', e => e.checked)
		.catch(() => null);
	const wifi2g = await page.$eval('[data-widget-id="' + ID + 'wifi_pause_2g"]', e => e.checked)
		.catch(() => null);
	const wifi5g = await page.$eval('[data-widget-id="' + ID + 'wifi_pause_5g"]', e => e.checked)
		.catch(() => null);
	console.log('  无线开关: 总=' + wifiPause + ' 2.4G=' + wifi2g + ' 5G=' + wifi5g);
	// 只断言「控件存在」，不断言具体开/关 ——
	// 这三个值随用户的实际 UCI 配置变化，写死会让回归测试在正常改配置后误报。
	ok(wifiPause !== null, '「启用断网暂停无线」总开关存在（当前值: ' + wifiPause + '）');
	ok(wifi2g !== null, '「包含 2.4G 频段」开关存在（当前值: ' + wifi2g + '）');
	ok(wifi5g !== null, '「包含 5G 频段」开关存在（当前值: ' + wifi5g + '）');

	/* ---------------- 7. 「查看日志」——验证 rpcd file 读权限链路 ----------------
	 * 注意：#modal_overlay / .modal 是 UI 初始化时就常驻 DOM 的空容器，
	 * 所以「等 .modal 出现」是假阳性，必须断言它「内容非空」。
	 */
	const modalSel = '#modal_overlay .modal';
	const beforeLen = await page.$eval(modalSel, e => e.textContent.trim().length)
		.catch(() => -1);
	ok(beforeLen === 0, '点击前模态框为空（排除常驻容器造成的假阳性）');

	await page.click('button:has-text("查看日志")');
	const filled = await page.waitForFunction(sel => {
		const m = document.querySelector(sel);
		return m && m.textContent.trim().length > 0;
	}, modalSel, { timeout: 20000 }).then(() => true).catch(() => false);
	ok(filled, '「查看日志」真正渲染出内容（点击回调生效）');

	if (filled) {
		const modalText = ((await page.textContent(modalSel).catch(() => '')) || '').trim();
		console.log('  弹窗文本长度:', modalText.length);
		console.log('  弹窗片段:', JSON.stringify(modalText.slice(0, 200)));
		ok(/运行日志/.test(modalText), '弹窗标题为「运行日志（末尾 200 行）」');
		ok(/\[\d{4}-\d{2}-\d{2}/.test(modalText), '日志含 [YYYY-MM-DD] 时间戳');
		ok(modalText.indexOf('无输出') < 0, '日志非空（rpcd 文件读取权限正常）');

		/* 日志字号：用户反馈原来 12px 太小，现改为 15px */
		const preStyle = await page.$eval(modalSel + ' pre', e => {
			const cs = getComputedStyle(e);
			return {
				fontSize: cs.fontSize,
				lineHeight: cs.lineHeight,
				fontFamily: cs.fontFamily,
				color: cs.color,
				background: cs.backgroundColor,
			};
		}).catch(() => null);
		console.log('  日志样式:', JSON.stringify(preStyle));
		ok(preStyle && parseFloat(preStyle.fontSize) >= 14,
			'日志字号已调大（实际 ' + (preStyle && preStyle.fontSize) + '）');

		/* 日志配色跟随主题（浅色白底黑字 / 深色深底白字）——
		 * 这里跑的是默认浅色，只断言浅色那一半；深浅切换的完整验证
		 * 在 tests/luci/luci-log-theme.js（用 emulateMedia 切两种模式）。 */
		ok(preStyle && preStyle.color === 'rgb(0, 0, 0)',
			'【浅色】日志文字是纯黑（实际 ' + (preStyle && preStyle.color) + '）');
		ok(preStyle && preStyle.background === 'rgb(255, 255, 255)',
			'【浅色】日志底色是白（实际 ' + (preStyle && preStyle.background) + '）');

		await shot('shot-log-modal.png');

		const closeBtn = await page.$('.modal button:has-text("关闭")');
		if (closeBtn) await closeBtn.click();
		else await page.keyboard.press('Escape');
		await wait(1000);
	}

	/* ---------------- 8. JS 报错 ---------------- */
	if (errors.length) console.log('  捕获到的错误:', JSON.stringify(errors));
	ok(errors.length === 0, '目标页无 JS 报错（捕获 ' + errors.length + ' 条）');

	await shot();
};
