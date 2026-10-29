/*
 * 「系统浅色 + Argon 强制深色」场景验证。
 *
 * 这是纯 CSS @media (prefers-color-scheme: dark) 会判断错的组合 ——
 * 也是日志配色必须在运行时量 body 背景（而不是写媒体查询）的原因。
 *
 * 运行前提：路由器上 argon.global.mode 已被临时设为 'dark'，
 * 而本测试用 emulateMedia({colorScheme:'light'}) 模拟「系统是浅色」。
 */
module.exports = async ({ page, ok, shot, wait }) => {
	const BASE = 'http://192.168.1.1/cgi-bin/luci/admin/services/suit-portal';
	const modalSel = '#modal_overlay .modal';

	// 系统侧声明浅色 —— 但 Argon 被强制深色，页面应该仍然是深色
	await page.emulateMedia({ colorScheme: 'light' });

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
	await wait(3000);

	const prefersDark = await page.evaluate(
		() => window.matchMedia('(prefers-color-scheme: dark)').matches);
	ok(prefersDark === false, '前置条件成立：浏览器上报「系统偏好 = 浅色」');

	await page.click('button:has-text("查看日志")');
	const filled = await page.waitForFunction(sel => {
		const m = document.querySelector(sel);
		return m && m.textContent.trim().length > 0;
	}, modalSel, { timeout: 20000 }).then(() => true).catch(() => false);
	ok(filled, '日志弹窗渲染出内容');

	const v = await page.evaluate(sel => {
		const pre = document.querySelector(sel + ' pre');
		const cs = getComputedStyle(pre);
		const modalEl = document.querySelector(sel);
		return {
			preColor: cs.color,
			preBg: cs.backgroundColor,
			modalBg: getComputedStyle(modalEl).backgroundColor,
			bodyBg: getComputedStyle(document.body).backgroundColor,
		};
	}, modalSel);

	console.log('  body 背景       :', v.bodyBg);
	console.log('  modal 背景      :', v.modalBg);
	console.log('  pre 配色        :', v.preColor, '/', v.preBg);

	function parseRgb(s) {
		const m = (s || '').match(/[\d.]+/g);
		return m ? { r: +m[0], g: +m[1], b: +m[2], a: m.length > 3 ? +m[3] : 1 } : null;
	}
	function lum(c) { return c ? (c.r * 299 + c.g * 587 + c.b * 114) / 1000 : null; }

	const body = parseRgb(v.bodyBg);
	ok(lum(body) < 128,
		'页面实际是深色底（' + v.bodyBg + '）—— 尽管系统偏好是浅色，Argon 强制深色生效了');

	const pc = parseRgb(v.preColor);
	ok(pc && pc.r === 255 && pc.g === 255 && pc.b === 255,
		'日志文字是纯白（实际 ' + v.preColor + '）—— 说明运行时探测正确地认出了深色');

	ok(parseRgb(v.preBg).a < 1,
		'日志底色用的是深色模式那一套（' + v.preBg + '）');

	await shot('shot-log-forced-dark.png');
};
