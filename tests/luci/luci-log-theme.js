/*
 * 日志配色「随深浅色模式切换」验证 —— 真实浏览器，两种模式都跑一遍。
 *
 * 关键前提（已实测）：
 *   /etc/config/argon 的 global.mode 为空 = normal 模式，
 *   此时 Argon 把 dark.css 包在 @media (prefers-color-scheme: dark) 里，
 *   所以用 Playwright 的 emulateMedia({colorScheme:'dark'}) 就能真切到深色，
 *   不需要改路由器配置。
 *
 * 断言要点：不能只看 pre 的 color —— 还要先证明**页面本身确实变深了**，
 * 否则「黑字」在两种模式下都成立，测试等于没测。
 */
module.exports = async ({ page, ok, shot, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';
	const modalSel = '#modal_overlay .modal';

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

	/* 打开「查看日志」弹窗，返回 pre 的 computed 配色 */
	async function openLogAndMeasure() {
		await page.click('button:has-text("查看日志")');
		const filled = await page.waitForFunction(sel => {
			const m = document.querySelector(sel);
			return m && m.textContent.trim().length > 0;
		}, modalSel, { timeout: 20000 }).then(() => true).catch(() => false);

		if (!filled) return null;

		const v = await page.evaluate(sel => {
			const pre = document.querySelector(sel + ' pre');
			const cs = getComputedStyle(pre);
			const modalEl = document.querySelector(sel);
			const bodyCs = getComputedStyle(document.body);
			return {
				preColor: cs.color,
				preBg: cs.backgroundColor,
				preBorder: cs.borderTopColor,
				preFontSize: cs.fontSize,
				modalBg: modalEl ? getComputedStyle(modalEl).backgroundColor : 'rgb(255,255,255)',
				bodyBg: bodyCs.backgroundColor,
				bodyColor: bodyCs.color,
			};
		}, modalSel);

		// 关掉弹窗
		const closeBtn = await page.$('.modal button:has-text("关闭")');
		if (closeBtn) await closeBtn.click();
		else await page.keyboard.press('Escape');
		await wait(800);

		return v;
	}

	/* 把 rgb(a) 转成 {r,g,b,a}，方便断言 */
	function parseRgb(s) {
		const m = (s || '').match(/[\d.]+/g);
		if (!m) return null;
		return { r: +m[0], g: +m[1], b: +m[2], a: m.length > 3 ? +m[3] : 1 };
	}
	function luminance(s) {
		const c = parseRgb(s);
		if (!c) return null;
		return (c.r * 299 + c.g * 587 + c.b * 114) / 1000;
	}
	/*
	 * 半透明前景合成到背景上，得到「眼睛实际看到的」颜色。
	 * 坑：日志底色深色模式用的是 rgba(255,255,255,0.06)，
	 * 原始 RGB 是纯白（255,255,255）——直接量它会被误判成「亮色」。
	 * 必须合成到父容器（.modal）的背景上再算亮度。
	 */
	function composite(fgStr, bgStr) {
		const f = parseRgb(fgStr);
		const b = parseRgb(bgStr) || { r: 255, g: 255, b: 255, a: 1 };
		if (!f) return null;
		const a = f.a;
		return {
			r: Math.round(f.r * a + b.r * (1 - a)),
			g: Math.round(f.g * a + b.g * (1 - a)),
			b: Math.round(f.b * a + b.b * (1 - a)),
			a: 1,
		};
	}
	function lumOf(c) {
		return c ? (c.r * 299 + c.g * 587 + c.b * 114) / 1000 : null;
	}

	/* ==================== 一、浅色模式 ==================== */
	await page.emulateMedia({ colorScheme: 'light' });
	console.log('  登录:', await loginIfNeeded());
	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(3000);

	const light = await openLogAndMeasure();
	ok(!!light, '【浅色】日志弹窗渲染出内容');
	if (light) {
		console.log('  浅色 body 背景 :', light.bodyBg, ' 亮度', luminance(light.bodyBg));
		console.log('  浅色 pre 配色  :', light.preColor, '/', light.preBg);

		ok(luminance(light.bodyBg) > 128,
			'【浅色】页面确实是浅色底（body 背景 ' + light.bodyBg + '）');

		const pc = parseRgb(light.preColor);
		ok(pc && pc.r === 0 && pc.g === 0 && pc.b === 0,
			'【浅色】日志文字是纯黑（实际 ' + light.preColor + '）');

		const pb = parseRgb(light.preBg);
		ok(pb && pb.r === 255 && pb.g === 255 && pb.b === 255 && pb.a === 1,
			'【浅色】日志底色是白（实际 ' + light.preBg + '）');

		ok(parseFloat(light.preFontSize) >= 14,
			'【浅色】字号仍是 15px（实际 ' + light.preFontSize + '）');

		await page.click('button:has-text("查看日志")');
		await page.waitForFunction(sel => {
			const m = document.querySelector(sel);
			return m && m.textContent.trim().length > 0;
		}, modalSel, { timeout: 20000 }).catch(() => {});
		await wait(600);
		await shot('shot-log-light.png');
		const cb = await page.$('.modal button:has-text("关闭")');
		if (cb) await cb.click();
		await wait(800);
	}

	/* ==================== 二、深色模式 ==================== */
	// Argon 在 normal 模式下把 dark.css 包在 @media (prefers-color-scheme: dark) 里，
	// 所以这里改 emulateMedia 再重新加载页面，就能真切到深色。
	await page.emulateMedia({ colorScheme: 'dark' });
	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await page.waitForSelector('#suit-state', { timeout: 30000 }).catch(() => {});
	await wait(3000);

	const dark = await openLogAndMeasure();
	ok(!!dark, '【深色】日志弹窗渲染出内容');
	if (dark) {
		console.log('  深色 body 背景 :', dark.bodyBg, ' 亮度', luminance(dark.bodyBg));
		console.log('  深色 pre 配色  :', dark.preColor, '/', dark.preBg);

		ok(luminance(dark.bodyBg) < 128,
			'【深色】页面确实切成深色底了（body 背景 ' + dark.bodyBg + '）—— 这条是前提，'
			+ '否则下面的「白字」在两种模式下都成立，等于没测');

		const dc = parseRgb(dark.preColor);
		ok(dc && dc.r === 255 && dc.g === 255 && dc.b === 255,
			'【深色】日志文字是纯白（实际 ' + dark.preColor + '）');

		// 底色要合成到 .modal 的背景上再算亮度（rgba 的原始 RGB 不代表观感）
		const darkEff = composite(dark.preBg, dark.modalBg);
		console.log('  深色日志底色合成后 :',
			'rgb(' + darkEff.r + ',' + darkEff.g + ',' + darkEff.b + ')  亮度', lumOf(darkEff));
		ok(lumOf(darkEff) < 128,
			'【深色】日志底色观感上是深色（' + dark.preBg + ' 叠在 ' + dark.modalBg +
			' 上 = rgb(' + darkEff.r + ',' + darkEff.g + ',' + darkEff.b + ')）');

		await page.click('button:has-text("查看日志")');
		await page.waitForFunction(sel => {
			const m = document.querySelector(sel);
			return m && m.textContent.trim().length > 0;
		}, modalSel, { timeout: 20000 }).catch(() => {});
		await wait(600);
		await shot('shot-log-dark.png');
		const cb2 = await page.$('.modal button:has-text("关闭")');
		if (cb2) await cb2.click();
		await wait(800);
	}

	/* ==================== 三、两种模式确实不同 ==================== */
	if (light && dark) {
		ok(light.preColor !== dark.preColor,
			'浅色/深色下日志文字颜色确实不同（' + light.preColor + ' vs ' + dark.preColor + '）');
		// 浅色模式是黑字（亮度低）、深色模式是白字（亮度高）—— 别写反
		ok(luminance(light.preColor) < luminance(dark.preColor),
			'方向正确：浅色模式文字更黑、深色模式文字更白（' +
			luminance(light.preColor) + ' < ' + luminance(dark.preColor) + '）');

		const lEff = composite(light.preBg, light.modalBg);
		const dEff = composite(dark.preBg, dark.modalBg);
		ok(lumOf(lEff) > lumOf(dEff),
			'方向正确：浅色模式日志底色更亮、深色模式更暗（' +
			lumOf(lEff) + ' > ' + lumOf(dEff) + '）');
	}

	await page.emulateMedia({ colorScheme: 'light' });
	await page.goto(BASE, { waitUntil: 'domcontentloaded' });
	await wait(1500);
	await shot();
};
