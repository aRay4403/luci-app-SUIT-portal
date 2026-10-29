'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require poll';

/*
 * 校园网 ePortal 自动认证 —— LuCI 配置页
 *
 * 页面分三块：
 *   1) 运行状态（从 /var/run/suit-portal.state 读当前轮询间隔，1 秒轮询刷新）
 *   2) 认证设置表单（UCI: suit-portal.main.*）
 *   3) 操作按钮：立即认证 / 强制重新认证 / 查看日志 / 重启服务
 *      · 立即认证     = 先查在线，已在线就不重复认证（和守护进程同一套判断）
 *      · 强制重新认证 = 跳过在线检查，直接跑完整流程（在线判定误报时的逃生口）
 */

var LOGFILE = '/var/log/suit-portal.log';
var STATEFILE = '/var/run/suit-portal.state';

function readText(path) {
	return L.resolveDefault(fs.read(path), '').then(function(s) { return s || ''; });
}

/*
 * 当前页面是不是深色主题？
 *
 * 为什么要在运行时「量」出来，而不是写一条 CSS 媒体查询：
 *   Argon 主题的深色模式**不是靠 CSS 变量切换的**（实测：dark.css 里没有任何
 *   :root{--xxx} 重定义，--background-color 在深浅两种模式下取值完全相同）。
 *   它的做法是把整份 dark.css 内联进页面的 <style>：
 *     mode=normal → 包在 @media (prefers-color-scheme: dark) 里（跟系统走）
 *     mode=dark   → 无条件生效（跟系统无关）
 *   见 /usr/share/ucode/luci/template/themes/argon/header.ut。
 *   所以「系统是浅色、但 Argon 被设成强制深色」这种组合，光靠
 *   prefers-color-scheme 判断不出来。直接量渲染后的实际背景色最稳，三种组合都覆盖。
 */
function pageBgIsDark() {
	var nodes = [document.body, document.documentElement];

	for (var i = 0; i < nodes.length; i++) {
		var bg = getComputedStyle(nodes[i]).backgroundColor || '';
		var m = bg.match(/[\d.]+/g);
		if (!m || m.length < 3) continue;

		var alpha = m.length > 3 ? parseFloat(m[3]) : 1;
		if (alpha === 0) continue;              // 全透明 → 往下看一层

		// ITU-R BT.601 感知亮度
		return (m[0] * 299 + m[1] * 587 + m[2] * 114) / 1000 < 128;
	}
	return false;                                // 量不出来就按浅色处理
}

/*
 * 日志区配色：浅色 = 白底黑字，深色 = 深底白字（跟随主题切换）。
 * 用纯黑 / 纯白，不走主题里那些带色相的变量，保证日志可读性最高。
 */
function logPalette() {
	return pageBgIsDark()
		? { fg: '#ffffff', bg: 'rgba(255,255,255,0.06)', bd: 'rgba(255,255,255,0.18)' }
		: { fg: '#000000', bg: '#ffffff',                bd: 'rgba(0,0,0,0.12)' };
}

function showOutput(title, text) {
	var c = logPalette();

	ui.showModal(title, [
		E('pre', {
			/*
			 * 日志字号：原来是 12px，实机看着太小（用户反馈）。
			 * 15px + 1.7 行高 + monospace，长 URL 用 break-all 兜住不横向溢出。
			 * 配色走 logPalette()：浅色白底黑字 / 深色深底白字，随主题切换。
			 */
			style: 'max-height:65vh;overflow:auto;white-space:pre-wrap;' +
				'word-break:break-all;font-size:15px;line-height:1.7;' +
				'font-family:ui-monospace,Menlo,Consolas,monospace;' +
				'margin:0.5em 0;padding:0.8em;border-radius:6px;' +
				'color:' + c.fg + ';background:' + c.bg + ';' +
				'border:1px solid ' + c.bd + ';'
		}, text || _('（无输出）')),
		E('div', { 'class': 'right' },
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, _('关闭')))
	]);
}

/*
 * 跑一次认证，结果丢进弹窗。
 *
 * 抽成模块级函数（而不是 view 的方法）是为了**不依赖 this** ——
 * 按钮回调的 this 曾经踩过坑（见 render 里那段注释），能不碰就不碰。
 */
function runAuth(args, title, hint) {
	ui.showModal(title, [
		E('p', { 'class': 'spinning' }, hint)
	]);

	return fs.exec_direct('/usr/bin/suit-portal.sh', args)
		.then(function(out) {
			ui.hideModal();
			showOutput(_('认证结果'), out);
		})
		.catch(function(e) {
			ui.hideModal();
			ui.addNotification(null,
				E('p', _('执行失败：%s').format(e && e.message || e)), 'error');
		});
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('suit-portal'),
			readText(STATEFILE)
		]);
	},

	/*
	 * 「立即认证」—— 走脚本的 --auth 分支，和守护进程同一套判断：
	 * **已在线就不重复认证**，只回一句说明。
	 * 理由：已经在线时再跑一遍完整流程是白跑 —— 要建会话、取登录页、
	 * AES 加密、走 5 步工作流（十几秒），而且 AC 对重复认证常常直接回
	 * ACK_AUTH_REFUSE，看着像失败。
	 */
	handleAuthNow: function() {
		return runAuth([ '--auth' ],
			_('正在认证…'),
			_('正在检查在线状态，必要时才走完整认证流程…'));
	},

	/*
	 * 「强制重新认证」—— 走 --force-verbose，不查在线，直接跑完整流程。
	 * 留给「在线判定说没问题、但实际有毛病」的情况（在线判定本身可能误报）。
	 */
	handleAuthForce: function() {
		return runAuth([ '--force-verbose' ],
			_('正在强制重新认证…'),
			_('跳过在线检查，强制执行完整认证流程（约 10 秒）'));
	},

	handleLog: function() {
		return readText(LOGFILE).then(function(s) {
			var lines = s.split('\n');
			showOutput(_('运行日志（末尾 200 行）'), lines.slice(-200).join('\n'));
		});
	},

	handleRestart: function() {
		return fs.exec('/etc/init.d/suit-portal', [ 'restart' ]).then(function() {
			ui.addNotification(null, E('p', _('服务已重启')), 'info');
		});
	},

	/*
	 * 「恢复无线」—— 逃生口。
	 *
	 * 断网暂停无线是「一直关到认证成功」的，万一认证持续失败（账号填错、
	 * 校园网服务器故障），无线就一直关着。这个按钮走脚本的 --wifi-resume：
	 * 无视开关与状态，把全部 radio 无条件拉起来。
	 */
	handleWifiResume: function() {
		return fs.exec_direct('/usr/bin/suit-portal.sh', [ '--wifi-resume' ])
			.then(function(out) {
				ui.addNotification(null,
					E('p', (out || '').trim() || _('无线已恢复')), 'info');
			})
			.catch(function(e) {
				ui.addNotification(null,
					E('p', _('恢复失败：%s').format(e && e.message || e)), 'error');
			});
	},

	render: function(data) {
		/*
		 * 必须在这里抓住 view 实例。
		 * cfgvalue 回调里的 this 是 form.DummyValue 的 option 实例，
		 * 而 handleAuthNow / handleLog / handleRestart 定义在 view 上；
		 * 若在 cfgvalue 里用 this，ui.createHandlerFn 会取到 undefined，
		 * 按钮点下去毫无反应（且不报错）—— 实机踩过。
		 */
		var self = this;
		var stateText = (data[1] || '').trim();
		var m, s, o;

		/*
		 * 页面标题带 SUIT 前缀 —— 一眼能看出这是为哪所学校做的，又不用写一长串校名。
		 * 学校英文名全大写（SUIT）是学校自己的写法，见 README §十四。
		 * 说明里点明「基于 SUIT 环境制作」：这套认证流程是照深信大校网
		 * （锐捷 ePortal + CAS-SSO）适配的，换到别的校网不一定能直接用。
		 */
		m = new form.Map('suit-portal',
			_('SUIT 校园网自动认证'),
			_('基于 SUIT 环境制作。锐捷 ePortal 网页认证自动完成：填好账号密码保存即可，' +
			  '断线后会自动重连，路由器重启也会自动恢复。'));

		/* ---------------- 运行状态 ---------------- */
		s = m.section(form.NamedSection, 'main', 'service', _('运行状态'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_status', _('当前轮询间隔'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('span', { 'id': 'suit-state' },
				stateText ? _('%s 秒').format(stateText) : _('（服务未运行）'));
		};

		o = s.option(form.DummyValue, '_actions', _('操作'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('div', { 'class': 'cbi-value-field' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(self, 'handleAuthNow')
				}, _('立即认证')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleAuthForce')
				}, _('强制重新认证')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleLog')
				}, _('查看日志')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleRestart')
				}, _('重启服务')),
				' ',
				/*
				 * 「恢复无线」放在最右边：它不是日常操作，是「断网暂停无线」
				 * 一直没认证成功时的逃生口（详见 handleWifiResume 的注释）。
				 */
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleWifiResume')
				}, _('恢复无线'))
			]);
		};

		/* ---------------- 认证设置 ---------------- */
		s = m.section(form.NamedSection, 'main', 'service', _('认证设置'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用自动认证'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('关闭后守护进程不再运行，但仍保留配置。');

		o = s.option(form.Value, 'username', _('校园网账号'));
		o.rmempty = false;
		o.placeholder = _('请输入你的校园网账号');

		o = s.option(form.Value, 'password', _('密码'));
		o.password = true;
		o.rmempty = false;

		/*
		 * 运营商做成下拉选择（原来是个文本输入框，容易填错）。
		 * 注意：认证服务器 /eportal/network/serviceSelection 是**动态返回**运营商列表的，
		 * 实机（2026-10-04）只返回 {"key":"default"} 和 {"key":"电信宽带"} 两项，
		 * 其中 default 就是**校园网**（校内出口）。
		 * 脚本有 fallback：配置值不在服务端列表里时会自动回退（优先 default），
		 * 所以这里把校园网和三大运营商都列出来是安全的 —— 选了服务端没提供的会自动回退，不会认证失败。
		 */
		o = s.option(form.ListValue, 'service', _('运营商'));
		o.value('default', _('校园网（Default）'));
		o.value('电信宽带', _('电信宽带'));
		o.value('移动宽带', _('移动宽带'));
		o.value('联通宽带', _('联通宽带'));
		o.default = 'default';
		o.rmempty = false;
		o.description = _('默认走校园网（Default）。若所选运营商服务端未提供，脚本会自动回退。');

		o = s.option(form.Value, 'portal_host', _('认证服务器'));
		o.default = '10.10.16.56';
		o.datatype = 'host';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('在线检测间隔'));
		o.datatype = 'uinteger';
		o.default = '30';
		o.description = _('已在线时每隔多少秒检查一次，单位秒。');

		o = s.option(form.Value, 'interval_offline', _('掉线重试间隔'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.description = _('掉线或认证失败时的重试间隔，单位秒。越小恢复越快。');

		o = s.option(form.Value, 'interval_offline_max', _('连续失败退避上限'));
		o.datatype = 'uinteger';
		o.default = '60';
		o.description = _('连续失败后退避的最长间隔，单位秒。避免高频请求被风控。');

		/* ---------------- 高级 ---------------- */
		s = m.section(form.NamedSection, 'main', 'service', _('高级'));
		s.anonymous = true;
		s.addremove = false;

		/*
		 * 「门户入口 URL」保留输入框，但做成**灰掉的只读框**，一眼能看出「不可修改」。
		 *
		 * 这个值完全由脚本自己管：每次认证探测到网关劫持入口就回写进 UCI
		 * （suit-portal.sh 的 save_entry_url），WAN IP 变了也会自动更新。
		 * 手填没有意义 —— 下次探测成功就会被覆盖，所以不给编辑。
		 *
		 * 它仍然有用，只是不需要人管：
		 *   · AC 认为设备已认证后不再劫持，探测拿不到入口 → 拿它当兜底入口；
		 *   · --check 查服务端在线状态（/eportal/network/userOnline）要先有入口换 sessionId。
		 *
		 * ⚠️ 用 LuCI 的 o.readonly，不要自己接 ui.Textfield 的 readonly：
		 *    form.js 的 CBIValue.renderWidget 是
		 *        disabled: (this.readonly != null) ? this.readonly : this.map.readonly
		 *    也就是说 o.readonly 落到的是 **disabled** —— 框变灰、光标变默认，
		 *    「不可修改」的视觉提示最强，也和 LuCI 其它只读字段保持一致。
		 *    自己传 ui.Textfield 的 readonly 只会加个 HTML 属性，外观跟普通输入框一模一样，
		 *    用户看不出这个框不能改（试过，被否了）。
		 *    代价是不能选中/复制 —— 这个值只是排障时看一眼，不值当为它换掉视觉提示。
		 */
		o = s.option(form.Value, 'entry_url', _('门户入口 URL'));
		o.optional = true;
		o.readonly = true;
		o.description = _('无需配置。脚本自动探测最新入口并回写，WAN IP 变化也不失效。');

		o = s.option(form.Value, 'online_check_urls', _('在线探测地址'));
		o.optional = true;
		o.description = _('用空格分隔多个地址。建议用域名而非纯 IP —— 本网络下纯 IP 探测会失败。');

		/* ---------------- 断网暂停无线 ----------------
		 * 三个开关：总开关 + 2.4G / 5G 分频段开关。
		 * 分频段开关只在总开关打开时才显示（o.depends）。
		 */
		s = m.section(form.NamedSection, 'main', 'service', _('断网暂停无线'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'wifi_pause', _('启用断网暂停无线'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('断网时关闭无线射频，认证成功后自动恢复。关闭期间搜不到 WiFi，需用网线管理；' +
			'WAN 必须是有线接入。');

		o = s.option(form.Flag, 'wifi_pause_2g', _('包含 2.4G 频段'));
		o.default = '1';
		o.rmempty = false;
		o.depends('wifi_pause', '1');
		o.description = _('关掉后，断网期间 2.4G 保持广播（适合给智能家居设备留一条路）。');

		o = s.option(form.Flag, 'wifi_pause_5g', _('包含 5G 频段'));
		o.default = '1';
		o.rmempty = false;
		o.depends('wifi_pause', '1');

		return m.render().then(function(node) {
			/*
			 * 「门户入口 URL」是只读的（o.readonly → <input disabled>），
			 * 但 Argon 自带的 disabled 样式**实测只有 rgba(239,239,239,0.3)**，
			 * 叠在白底上算出来是「白得几乎一样」—— 用户的原话是「要变灰啊，
			 * 突出不能修改的属性」，所以这里按当前主题再压一层。
			 *
			 * 深浅两套为什么机制不同：
			 *   浅色主题：直接填灰底 + 灰字，最直观。
			 *   深色主题：**不能填灰底** —— Argon 的 dark.css 里有
			 *       input{background-color:transparent !important; ...}
			 *     填底色会被 !important 打掉（实测 computed 仍是 rgba(0,0,0,0)）。
			 *     而且深色主题的输入框本来就是「透明底 + 下划线边框」的样式，
			 *     硬塞一块浅灰反而像高亮。所以深色改成整体降透明度 + 暗字，
			 *     边框和文字一起变暗，观感就是「禁用」。
			 *
			 * 主题判断沿用本文件 logPalette() 那套（量渲染后的实际背景色，
			 * 而不是看媒体查询 —— Argon 强制深色时媒体查询是假的）。
			 */
			var roCss = pageBgIsDark()
				? '#cbi-suit-portal-main-entry_url input:disabled' +
				  '{opacity:0.55;color:rgba(255,255,255,0.4);}'
				: '#cbi-suit-portal-main-entry_url input:disabled' +
				  '{background-color:#e9ecef;color:#868e96;}';
			node.appendChild(E('style', {}, roCss +
				'#cbi-suit-portal-main-entry_url input:disabled{cursor:not-allowed;}'));

			/* 每秒刷新状态栏 */
			poll.add(L.bind(function() {
				return readText(STATEFILE).then(function(t) {
					var el = document.getElementById('suit-state');
					if (el) {
						t = t.trim();
						el.textContent = t ? _('%s 秒').format(t) : _('（服务未运行）');
					}
				});
			}, this), 1);

			return node;
		});
	}
});
