/*
 * 探针：查「门户入口 URL」那段说明在页面上到底渲染了几次、分别在哪。
 *
 * 背景：用户曾反馈这段说明在页面上重复出现。实测结论是**只渲染 1 次**
 * （源码 1 处、路由器 view 文件 1 处、DOM 叶子元素 1 个），多半是复制粘贴造成的错觉。
 * 这段文案后来精简过一次，探针里的关键词跟着更新。
 */
module.exports = async ({ page, ok, shot, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';
	const KEY = '脚本自动探测最新入口并回写';

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

	const info = await page.evaluate(key => {
		const txt = document.body.innerText || '';
		const count = s => (txt.split(s).length - 1);

		// 找出所有**叶子节点**里含该文案的元素
		const els = Array.from(document.querySelectorAll('*')).filter(e =>
			e.children.length === 0 && (e.textContent || '').indexOf(key) >= 0);

		const where = els.map(e => {
			const p = e.parentElement;
			const gp = p && p.parentElement;
			return {
				tag: e.tagName,
				cls: String(e.className || '').slice(0, 40),
				text: (e.textContent || '').replace(/\s+/g, ' ').slice(0, 70),
				parent: p ? p.tagName + '.' + String(p.className || '').slice(0, 30) : '',
				grand: gp ? gp.tagName + '.' + String(gp.className || '').slice(0, 30) : '',
			};
		});

		return {
			n1: count(key),
			n2: count('门户入口 URL'),
			leafCount: els.length,
			where: where,
		};
	}, KEY);

	console.log('  「' + KEY + '」:', info.n1, '次');
	console.log('  「门户入口 URL」:', info.n2, '次');
	console.log('  承载文案的叶子元素:', info.leafCount, '个');
	for (const w of info.where) {
		console.log('    <' + w.tag + ' class="' + w.cls + '"> 父=' + w.parent + ' 祖父=' + w.grand);
		console.log('      文本:', w.text);
	}

	ok(info.n1 <= 1, '该文案最多 1 次（实际 ' + info.n1 + ' 次）');

	// 滚到「高级」区块，让截图能拍到这段说明
	await page.evaluate(() => {
		const cands = Array.from(document.querySelectorAll('legend, h3, .cbi-section-title'));
		const t = cands.find(e => /^高级$/.test(e.textContent.trim()));
		if (t) t.scrollIntoView({ block: 'start' });
	});
	await wait(800);
	await shot();
};
