/*
 * 探针：搞清 Argon 主题暴露了哪些 CSS 变量、深色模式是怎么切的。
 * 只观察，不断言。
 */
module.exports = async ({ page, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';

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

	console.log('  登录:', await loginIfNeeded());
	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(3000);

	const info = await page.evaluate(() => {
		const de = document.documentElement;
		const cs = getComputedStyle(de);

		// 枚举所有 CSS 自定义属性（扫样式表里的 --xxx 声明）
		const vars = {};
		for (const sheet of Array.from(document.styleSheets)) {
			let rules;
			try { rules = sheet.cssRules; } catch (e) { continue; }
			if (!rules) continue;
			for (const r of Array.from(rules)) {
				if (!r.style) continue;
				for (const name of Array.from(r.style)) {
					if (name.indexOf('--') === 0) vars[name] = 1;
				}
			}
		}

		// 每个变量在根元素上的实际取值
		const vals = {};
		for (const name of Object.keys(vars).sort()) {
			const v = cs.getPropertyValue(name).trim();
			if (v) vals[name] = v;
		}

		return {
			htmlClass: de.className,
			htmlAttrs: Array.from(de.attributes).map(a => a.name + '=' + a.value),
			bodyClass: document.body.className,
			bodyBg: getComputedStyle(document.body).backgroundColor,
			bodyColor: getComputedStyle(document.body).color,
			lsKeys: Object.keys(localStorage),
			vars: vals,
		};
	});

	console.log('  html.class      :', JSON.stringify(info.htmlClass));
	console.log('  html 属性       :', JSON.stringify(info.htmlAttrs));
	console.log('  body.class      :', JSON.stringify(info.bodyClass));
	console.log('  body 背景/文字  :', info.bodyBg, '/', info.bodyColor);
	console.log('  localStorage    :', JSON.stringify(info.lsKeys));
	console.log('  ---- CSS 变量（根元素实际取值）----');
	for (const k of Object.keys(info.vars)) console.log('    ' + k + ' = ' + info.vars[k]);

	// 深色模式开关的线索
	const darkHints = await page.evaluate(() => {
		const out = {};
		out.hasMatchMedia = typeof window.matchMedia === 'function';
		out.prefersDark = window.matchMedia
			? window.matchMedia('(prefers-color-scheme: dark)').matches : null;
		// Argon 常见做法：body 上带 class，或 html 带 data-*
		const sel = ['html.dark', 'body.dark', 'html.darkmode', 'body.darkmode',
			'html[data-theme]', 'body[data-theme]', '.dark-mode'];
		out.matches = {};
		for (const s of sel) out.matches[s] = !!document.querySelector(s);
		return out;
	});
	console.log('  ---- 深色模式线索 ----');
	console.log('  prefersDark     :', darkHints.prefersDark);
	console.log('  命中的选择器    :', JSON.stringify(darkHints.matches));
};
