/*
 * 探针：查 portal.js 是怎么被加载的、带不带版本参数、浏览器缓存怎么处理。
 * 只观察，不断言。
 */
module.exports = async ({ page, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';

	// 记录所有对 portal.js 的请求（含是否命中缓存）
	const reqs = [];
	page.on('response', async r => {
		const u = r.url();
		if (u.indexOf('suit-portal') < 0) return;
		let cc = '', etag = '', lm = '';
		try {
			const h = r.headers();
			cc = h['cache-control'] || '(无)';
			etag = h['etag'] || '(无)';
			lm = h['last-modified'] || '(无)';
		} catch (e) {}
		reqs.push({ url: u.replace('http://192.168.1.1', ''), status: r.status(),
			fromCache: r.fromServiceWorker(), cc, etag, lm });
	});

	// 登录
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

	console.log('  ---- 页面里所有 script/link 引用 ----');
	const refs = await page.evaluate(() =>
		Array.from(document.querySelectorAll('script[src], link[href]'))
			.map(e => (e.getAttribute('src') || e.getAttribute('href')))
			.filter(u => u.indexOf('suit-portal') >= 0));
	console.log('  含 suit-portal 的引用:', JSON.stringify(refs, null, 2));

	console.log('  ---- 实际发出的请求 ----');
	for (const r of reqs) {
		console.log('  ', r.status, r.url);
		console.log('      Cache-Control:', r.cc, '| ETag:', r.etag, '| Last-Modified:', r.lm);
	}

	console.log('  ---- 页面当前内容（证明拿到的是新版）----');
	const v = await page.evaluate(() => ({
		title: (document.querySelector('.cbi-map h2') || {}).textContent,
		btns: Array.from(document.querySelectorAll('button')).map(b => b.textContent.trim()),
		menu: Array.from(document.querySelectorAll('.main-menu .nav a, nav a'))
			.map(a => a.textContent.trim()).filter(t => /suit|校园网/i.test(t)),
	}));
	console.log('  标题:', JSON.stringify(v.title));
	console.log('  按钮:', JSON.stringify(v.btns));
	console.log('  菜单项:', JSON.stringify(v.menu));

	console.log('  ---- 第二次加载（看会不会走缓存）----');
	const before = reqs.length;
	await page.reload({ waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(3000);
	for (const r of reqs.slice(before)) {
		console.log('  ', r.status, r.url, '| Cache-Control:', r.cc);
	}
};
