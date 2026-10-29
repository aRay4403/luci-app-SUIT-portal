# 深圳信息职业技术大学 校园网自动认证（OpenWrt / ImmortalWrt 版）

把锐捷 ePortal 的网页认证自动化。装到路由器上之后**不用再手输密码**，掉线自动重连、
路由器重启自动恢复。带 LuCI 配置界面（**服务 → SUIT 校园网自动认证**）。

> 📝 **仓库里的账号 / 密码 / MAC 等都是占位符**（如 `<你的账号>`、`<你的密码>`），
> 跑测试前换成你自己的值即可。`tests/fixtures/har-login.json` 是字段结构样本，
> 值同样是占位符。
>
> 提交前建议跑 `python tools/privacy_check.py` —— 它会扫源码树和 `dist/` 里的 apk，
> 避免把自己的凭据带进仓库。

---

## 一、产物

| 文件 | 说明 |
|---|---|
| `dist/suit-portal_1.0.0-r1_noarch.apk` | 认证守护进程 + UCI 配置 + procd 服务 |
| `dist/luci-app-suit-portal_1.0.0-r1_noarch.apk` | LuCI 配置界面（依赖上面那个） |

**`noarch` = 通用包，一个文件通吃所有架构**（aarch64 / mipsel / arm / x86 …）。
这个包是**纯脚本包**（shell + LuCI JS + UCI 配置，不含任何二进制），所以不需要按架构分包，
和官方源里 `luci-app-*` / `luci-i18n-*` 的做法一致。原因见 [§七](#七重新构建)。

目标环境：**OpenWrt / ImmortalWrt 25.12+（apk-tools 3.x）**。
包格式是 apk-tools 3.x 的 **v3 (ADB)** 格式，不是旧的 `.ipk`。

## 二、安装

```sh
# 上传两个 apk 到路由器 /tmp 后：
apk add --allow-untrusted /tmp/suit-portal.apk /tmp/luci-app-suit-portal.apk

# 让 rpcd 重新加载 ACL（否则 LuCI 页面读不到状态）
/etc/init.d/rpcd restart
```

装完自动完成：写入 UCI 配置、**停用旧的手工部署服务**（`/etc/init.d/portal-auth`，
文件保留可回退）、启用并启动新服务。

LuCI 入口：**服务 → SUIT 校园网自动认证**。

### 装到另一台路由器

**可以，而且不用管架构了**（包是 `noarch`）。只剩两个前提：

1. **系统必须是 OpenWrt / ImmortalWrt 25.12+**（apk-tools 3.x）。
   24.10 及更早用 opkg + `.ipk`，**格式完全不兼容**。检查：`apk --version` 能跑就是 3.x。
2. **依赖能装上** —— 包已声明 `busybox uclient-fetch openssl-util uci ubus`，
   `apk add` 会自动拉。但目标机若没联网或没配好软件源就会失败。
   特别注意 `openssl-util` 是 **CLI 工具包**，不等于 `libopenssl`（库）——
   不少精简固件只有库、没有 CLI，而脚本靠它做 AES 加解密和 base64。

**不用改 MAC** —— 每次认证都会重新探测网关劫持拿入口 URL，
里面的 `mac` / `wlanuserip` 都是当前设备自动带的。

> ⚠️ **同一个校园网账号在两台路由器上同时认证，很可能互相踢下线**
> （校园网普遍限制单账号 1 台设备）。这是账号策略问题，不是技术问题。

## 三、配置项（`/etc/config/suit-portal`）

| 项 | 默认 | 说明 |
|---|---|---|
| `enabled` | 1 | 是否启用守护进程 |
| `username` / `password` | 空 | 校园网账号密码，**必须自己填**；为空时不发起认证，只打日志提示 |
| `service` | 电信宽带 | 运营商。LuCI 里是**下拉三选一**（电信/移动/联通）；服务端未提供所选运营商时会自动回退 |
| `portal_host` | 10.10.16.56 | ePortal 地址 |
| `interval` | 30 | 在线时的检测间隔（秒） |
| `interval_offline` | 5 | 掉线时的快速重试间隔（秒） |
| `interval_offline_max` | 60 | 连续失败退避上限（秒） |
| `entry_url` | 空 | 门户入口 URL。**不用填**：脚本每次认证自动探测并回写，LuCI 里是灰掉的只读框 |
| `online_check_urls` | 见配置 | 在线探测地址，**必须用域名**（见下） |

改完执行：`uci commit suit-portal && /etc/init.d/suit-portal restart`

## 四、命令

```sh
/usr/bin/suit-portal.sh --check          # 看当前状态（在线 / 离线 / WAN IP）
/usr/bin/suit-portal.sh --auth           # 手动认证：先查在线，在线就跳过
/usr/bin/suit-portal.sh --force-auth     # 真·强制：不查在线，直接跑完整流程
/usr/bin/suit-portal.sh --probe          # 排障：打印探测地址的原始响应
/usr/bin/suit-portal.sh --trace          # 排障：逐阶段打印原始 body / 响应头
/etc/init.d/suit-portal status|restart|start|stop
tail -f /var/log/suit-portal.log
```

不带参数时就是守护进程那条路径：先 `check_online`，在线就 `已在线，无需认证。` 直接退出。

### 界面上两个认证按钮的区别

| 按钮 | 走的参数 | 行为 |
|---|---|---|
| **立即认证** | `--auth` | 先查在线。**已在线就跳过**，只回一句「已在线，无需重复认证」 |
| **强制重新认证** | `--force-verbose` | **不查在线**，直接跑完整认证流程 |

为什么「立即认证」在线时要跳过：已经在线再跑一遍完整流程是白跑 ——
要建会话、取登录页、AES 加密、走 5 步工作流（十几秒），
而且 **AC 对重复认证常常直接回 `ACK_AUTH_REFUSE`**，看着像失败。

那为什么还留「强制重新认证」：因为**在线判定本身可能误报**。
真遇到「判定说在线、但实际有毛病」，得有个跳过检查、直接重跑的逃生口 ——
否则点了按钮什么都不发生，人就卡住了。

## 五、断网暂停无线

### 做什么

检测到**离线（未认证）**时关掉无线射频，**认证成功后自动恢复**。

目的：断网期间设备还连着 WiFi 却上不了网，体验很差 —— 应用卡在重试、
系统误判「有网」、用户看不出到底断没断。把射频关掉，「没网」这件事立刻可见。

### 三个开关（LuCI：服务 → SUIT 校园网自动认证 → 断网暂停无线）

| UCI 项 | 界面 | 默认 | 说明 |
|---|---|---|---|
| `wifi_pause` | 启用断网暂停无线 | `0` | 总开关 |
| `wifi_pause_2g` | 包含 2.4G 频段 | `1` | 仅总开关打开时生效 |
| `wifi_pause_5g` | 包含 5G 频段 | `1` | 同上 |

两个频段开关**默认都开** = 关掉全部无线。想给智能家居留 2.4G，把
`wifi_pause_2g` 设成 `0` 即可。

命令行开启：

```sh
uci set suit-portal.main.wifi_pause='1'
uci commit suit-portal
/etc/init.d/suit-portal restart
```

### ⚠️ 两个前提

1. **WAN 必须是有线接入**（DHCP / PPPoE）。如果 WAN 走**无线中继（sta 模式）**，
   关射频会把 WAN 一起断掉，认证永远不可能成功 —— 那种拓扑下**不要开**这个开关。
2. 关闭期间**所有**设备都搜不到这台路由器的 WiFi，而且**一直关到认证成功**。
   请确保能用**网线**进 LuCI；万一被锁在外面，见下面的逃生口。

### 逃生口：`--wifi-resume`

LuCI 操作区最右边的「**恢复无线**」按钮，或命令行：

```sh
/usr/bin/suit-portal.sh --wifi-resume     # 无视开关与状态，把全部 radio 拉起来
```

给「认证一直不成功、无线一直关着」兜底用。

### 实现要点

* **只碰 `network.wireless`，绝不碰 `network.interface.*`** —— 有线（WAN / LAN）
  完全不受影响。
* 优先用 **ubus 逐个 radio** 精确控制，而不是 `wifi down/up` 整体操作：

  ```sh
  ubus call network.wireless down '{"device":"radio0"}'
  ```

  这样「只关 5G、保留 2.4G」才做得到（`wifi` 是整体操作，会一起关）。
  ubus 不可用且目标正好是全部 radio 时，才退回 `wifi down|up`。
* 频段识别优先读 `wireless.<radio>.band`（OpenWrt 21.02+ 的标准字段），
  老配置没有就退回用 `channel` 推（1-14 = 2.4G，36+ = 5G）。
  **两样都拿不到就返回 unknown 并且不碰** —— 宁可少关一个，也不能猜错把该留的关掉。
* ⭐ **暂停标志记的是「当初实际关掉的那批 radio」，不是「关过」这个布尔值**。
  因为频段开关随时可改：用户可能在无线已经关着的时候把 5G 开关关掉，
  恢复时必须按**当初那批**来开，否则会出现「关了 radio1、却只把 radio0 打开」，
  radio1 永远回不来。
* 标志文件放 `/tmp/.suit-portal-wifi-paused`，**不放 `$WORK_DIR`** ——
  `do_auth` 开头会 `rm -rf "$WORK_DIR"`，放里面会被自己清掉，
  导致「关了就再也开不回来」。`/tmp` 是 tmpfs，重启即清空，而重启后 netifd
  本来就会重新拉起无线，所以不会有残留。

## 六、目录结构

```
suit-portal/
├── pkg/                        # 打包用的文件树（安装后的真实路径）
│   ├── suit-portal/
│   │   ├── etc/config/suit-portal          UCI 默认配置
│   │   ├── etc/init.d/suit-portal          procd 服务（自适应间隔 + 退避）
│   │   ├── etc/uci-defaults/99-suit-portal 首次安装：迁移旧配置 + 启用
│   │   └── usr/bin/suit-portal.sh          认证主脚本（UCI + 旧 conf 双支持）
│   └── luci-app-suit-portal/
│       ├── usr/share/luci/menu.d/           菜单注册
│       ├── usr/share/rpcd/acl.d/            权限（含 exec，供「立即认证」用）
│       └── www/luci-static/resources/view/suit-portal/portal.js
├── scripts/                    # 认证流程的早期实现与参考配置（历史存档）
├── tools/
│   ├── mkadb.py                # apk v3 (ADB) 格式打包器（纯 Python）
│   ├── build.py                # 构建两个 apk
│   └── apkcheck.py             # 发布前扫包里有没有残留个人信息
├── tests/
│   ├── luci/                   # LuCI 页面的真实浏览器回归
│   └── *.sh                    # 认证 / 网络诊断脚本
└── dist/                       # 产物
```

## 七、重新构建

```sh
python tools/build.py                             # 默认产出 noarch 通用包 → dist/
python tools/build.py --arch aarch64_cortex-a53   # 需要指定架构时才加
python tools/build.py --no-compress               # 不压缩，排障用
python tools/apkcheck.py dist/xxx.apk --forbid 你的账号 你的密码   # 查某个 apk 里有没有指定串
python tools/privacy_check.py                     # 发布前必跑：扫源码树 + dist/ 里的 apk
```

### 为什么自己写打包器

OpenWrt 25.12 起用 apk-tools 3.x（v3/ADB 二进制格式），官方路线是 SDK + abuild。
这台机器上没有 Linux / Docker / WSL，所以按官方规范（`apk-tools/doc/apk-v3.5.scd`）
+ 对照官方包的 `apk adbdump` 输出，用 Python 直接生成。

### 为什么是 `noarch`，不是 `all`

本项目没有任何需要编译的东西（shell + JS + 文本配置），所以可以标 `noarch`，
一个文件通吃所有架构。**含二进制（C/Go/Rust 编译产物）的包做不到** ——
那种必须按架构分别构建，用户按自己的架构下载对应那一个。

⚠️ **必须写 `noarch`，不能写 `all`**：`all` 是 opkg（OpenWrt 24.10 及更早）时代的写法，
apk-tools 3 **不认**，会直接报 `uninstallable, arch: all` 装不上。

> 📌 什么情况下**不能**用 noarch：一旦包里加了需要编译的东西
> （自研的二进制、带 `.so` 的库），就必须按架构分包了。
> 那时 `depends` 里也不能再出现跨架构的东西。

## 八、回退

```sh
apk del luci-app-suit-portal suit-portal
/etc/init.d/portal-auth enable && /etc/init.d/portal-auth start
```

旧的手工部署文件（`/usr/bin/portal-auth.sh`、`/etc/portal-auth.conf`、
`/etc/init.d/portal-auth`）**没有被删除**，只是停用了，随时可以切回去。

> 建议：确认新方案稳定后，把 `/etc/portal-auth.conf` 删掉 —— 它含明文密码，
> 而且里面旧的 `LOG_FILE` / `PROBE_URLS` 值会在加载配置时覆盖包内新默认值
> （脚本已加「包环境强制项」把它钉回来，但留着终究是隐患）。

## 九、声明

本工具只是把**你本人已经拥有的账号**的网页认证流程自动化，用于自己的路由器，
不绕过任何计费或管理规定。请遵守学校的网络使用规定。
