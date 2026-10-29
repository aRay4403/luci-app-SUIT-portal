/*
 * LuCI 页面写操作验证 —— 「立即认证」/「重启服务」/「保存配置」
 *
 * 验证的是 ACL write 段的两条链路：
 *   file.exec  → /usr/bin/suit-portal.sh   （立即认证）
 *   file.exec  → /etc/init.d/suit-portal   （重启服务）
 *   uci        → suit-portal               （保存配置）
 *
 * 注意：#modal_overlay .modal 是常驻空容器，必须断言「内容非空」。
 */
module.exports = async ({ page, ok, shot, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';
	const MODAL = '#modal_overlay .modal';

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
	await loginIfNeeded();

	const errors = [];
	page.on('pageerror', e => errors.push('pageerror: ' + e.message));
	page.on('console', m => {
		if (m.type() === 'error') errors.push('console: ' + m.text());
	});

	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(3000);

	/* ============ 1. 立即认证（fs.exec_direct 链路） ============
	 * 「立即认证」走脚本的 --auth 分支：**先查在线，在线就跳过**，
	 * 所以在线状态下这里应该看到「已在线，无需重复认证」而不是跑完整流程。
	 */
	await page.click('button:has-text("立即认证")');

	const busy = await page.waitForFunction(sel => {
		const m = document.querySelector(sel);
		return m && /正在认证|认证结果/.test(m.textContent);
	}, MODAL, { timeout: 15000 }).then(() => true).catch(() => false);
	ok(busy, '点击「立即认证」后弹出认证模态框');

	const done = await page.waitForFunction(sel => {
		const m = document.querySelector(sel);
		return m && /认证结果/.test(m.textContent);
	}, MODAL, { timeout: 120000 }).then(() => true).catch(() => false);
	ok(done, '认证流程执行完毕并展示结果（fs.exec_direct 权限正常）');

	let authText = '';
	if (done) {
		authText = ((await page.textContent(MODAL).catch(() => '')) || '').trim();
		console.log('  立即认证结果:', JSON.stringify(authText.slice(0, 300)));
		ok(authText.indexOf('认证结果') >= 0, '结果弹窗标题为「认证结果」');
		ok(authText.indexOf('执行失败') < 0, '未出现执行失败提示');
		// 在线时应该跳过重复认证（这条同时验证「不再无脑跑完整流程」）
		ok(authText.indexOf('已在线，无需重复认证') >= 0,
			'在线状态下「立即认证」跳过重复认证（不再白跑一遍完整流程）');
		const cb = await page.$('.modal button:has-text("关闭")');
		if (cb) await cb.click(); else await page.keyboard.press('Escape');
		await wait(1000);
	}

	/* ============ 1b. 强制重新认证（跳过在线检查） ============ */
	await page.click('button:has-text("强制重新认证")');
	const forceDone = await page.waitForFunction(sel => {
		const m = document.querySelector(sel);
		return m && /认证结果/.test(m.textContent);
	}, MODAL, { timeout: 180000 }).then(() => true).catch(() => false);
	ok(forceDone, '「强制重新认证」执行完毕并展示结果');

	if (forceDone) {
		const ft = ((await page.textContent(MODAL).catch(() => '')) || '').trim();
		console.log('  强制认证结果片段:', JSON.stringify(ft.slice(0, 400)));
		ok(ft.indexOf('执行失败') < 0, '强制认证未出现执行失败提示');
		// 强制路径**不**跳过，应该看到真实的认证步骤
		ok(/\[\d\/5\]/.test(ft), '强制路径确实跑了完整认证流程（日志里能看到 [N/5] 步骤）');
		const cb2 = await page.$('.modal button:has-text("关闭")');
		if (cb2) await cb2.click(); else await page.keyboard.press('Escape');
		await wait(1000);
	}

	/* ============ 1c. 恢复无线（--wifi-resume 逃生口） ============ */
	await page.click('button:has-text("恢复无线")');
	const wifiResumed = await page.waitForFunction(
		() => /无线已恢复|恢复失败/.test(document.body.textContent),
		null, { timeout: 30000 }
	).then(() => true).catch(() => false);
	ok(wifiResumed, '点击「恢复无线」后给出结果通知（fs.exec_direct 权限正常）');
	await wait(1500);

	/* ============ 2. 重启服务（fs.exec 链路） ============ */
	await page.click('button:has-text("重启服务")');
	const restarted = await page.waitForFunction(
		() => /服务已重启/.test(document.body.textContent),
		null, { timeout: 25000 }
	).then(() => true).catch(() => false);
	ok(restarted, '点击「重启服务」后提示「服务已重启」（fs.exec 权限正常）');

	await wait(4000);
	// 重启后守护进程应恢复，状态栏重新显示间隔
	const stateAfter = await page.waitForFunction(() => {
		const e = document.querySelector('#suit-state');
		return e && /\d+\s*秒/.test(e.textContent);
	}, null, { timeout: 40000 }).then(() => true).catch(() => false);
	ok(stateAfter, '重启后状态栏恢复显示轮询间隔（服务已自动拉起）');

	/* ============ 3. 保存配置（uci 写链路） ============ */
	// 先记下只读字段「门户入口 URL」当前的值，保存后要逐字比对
	const entrySel = '#cbi-suit-portal-main-entry_url input';
	const entryBefore = await page.$eval(entrySel, e => String(e.value)).catch(() => '');

	const saveBtn = await page.$('button.cbi-button-save, button:has-text("保存")');
	ok(!!saveBtn, '页面存在「保存」按钮');
	if (saveBtn) {
		await saveBtn.click();
		await wait(3500);
		const errAlerts = await page.evaluate(() =>
			Array.from(document.querySelectorAll('.alert-message.error, .alert-message.danger'))
				.map(e => e.textContent.trim()));
		if (errAlerts.length) console.log('  错误通知:', JSON.stringify(errAlerts));
		ok(errAlerts.length === 0, '保存配置未报权限/校验错误（uci 写权限正常）');

		/*
		 * 保存后确认只读的「门户入口 URL」没被表单写坏。
		 * 它是脚本回写的值，页面这边只读 —— 断言保存前后一字不差。
		 */
		await page.goto(BASE, { waitUntil: 'domcontentloaded' });
		await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
		await wait(2500);
		const entryAfter = await page.$eval(entrySel, e => String(e.value)).catch(() => '');
		console.log('  保存前/后入口 URL 长度:', entryBefore.length, '/', entryAfter.length);
		ok(entryAfter.indexOf('eportal/index.jsp') >= 0,
			'保存后门户入口 URL 仍是那条回写的入口（没被表单覆盖）');
		ok(entryAfter === entryBefore, '保存前后值完全一致（只读字段没被改写）');
	}

	/* ============ 4. JS 报错 ============ */
	if (errors.length) console.log('  捕获到的错误:', JSON.stringify(errors));
	ok(errors.length === 0, '写操作过程无 JS 报错（捕获 ' + errors.length + ' 条）');

	await shot();
};
