/*
 * 探针：滚到「断网暂停无线」区块并截图（给视觉证据用）。
 * 只截图，不做功能断言 —— 断言在 luci-portal.js 里。
 */
module.exports = async ({ page, ok, shot, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';

	if (await page.$('input[name="luci_password"]')) {
		await page.fill('input[name="luci_username"]', 'root');
		await page.fill('input[name="luci_password"]', '<你的路由器密码>');
		await Promise.all([
			page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {}),
			page.click('input[type="submit"], button[type="submit"]'),
		]);
		await wait(1500);
	}

	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(4000);

	const info = await page.evaluate(() => {
		const cands = Array.from(document.querySelectorAll(
			'legend, h3, h4, .cbi-section-title, .cbi-title'));
		const t = cands.find(e => /断网暂停无线/.test(e.textContent));
		if (!t) return { found: false, tags: cands.map(e => e.tagName + ':' + e.textContent.trim().slice(0, 12)) };
		t.scrollIntoView({ block: 'start' });
		return { found: true, text: t.textContent.trim(), tag: t.tagName };
	});

	ok(info.found, '找到「断网暂停无线」区块（' + JSON.stringify(info) + '）');
	await wait(900);
	await shot();
};
