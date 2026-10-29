#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建 suit-portal 与 luci-app-suit-portal 两个 .apk

用法：
    python tools/build.py            # 输出到 dist/
    python tools/build.py --no-compress   # 不压缩（排障用）

为什么要自己打包：OpenWrt 25.12 起用 apk-tools 3.x（ADB 格式），
官方推荐 SDK+abuild，但这台机器没有 Linux/Docker/WSL，所以用 mkadb.py 直接生成。
"""

import argparse
import hashlib
import json
import os
import stat
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mkadb import PkgBuilder  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG_DIR = os.path.join(ROOT, "pkg")
DIST_DIR = os.path.join(ROOT, "dist")

ARCH = "aarch64_cortex-a53"       # 具体架构（--arch 不指定时的历史默认值）
# 【2026-10-04 实测结论】这个包是**纯脚本包**（shell + LuCI JS + UCI 配置，不含任何二进制），
# 所以不需要按架构分包 —— 把 arch 写成 `noarch` 就能「一个包通吃所有架构」，
# 和官方源里 luci-app-* / luci-i18n-* / default-settings 的做法一致（本机实测有 33 个 noarch 包）。
#
# 在真机（ImmortalWrt 25.12.2 / apk-tools 3.0.5）上做过对照实验：
#   arch: noarch        → apk add 接受 ✅
#   arch: all           → ERROR: unable to select packages: ... uninstallable, arch: all  ❌
#   arch: mipsel_24kc   → ERROR: ... uninstallable, arch: mipsel_24kc                    ❌
# 所以：apk **确实会校验架构**（不是"本地包随便装"），而 `all` 是 opkg 时代的写法，
# apk-tools 3 不认；通用包必须写 `noarch`。
UNIVERSAL_ARCH = "noarch"
VERSION = "1.0.0-r1"
MAINTAINER = "suit-portal"   # 不写个人信息，发布用的包保持干净
URL = "https://github.com/"

# 需要可执行权限的路径前缀
EXEC_PREFIXES = (
    "usr/bin/",
    "etc/init.d/",
    "etc/uci-defaults/",
    "etc/hotplug.d/",
)

PACKAGES = [
    {
        "name": "suit-portal",
        "tree": "suit-portal",
        "description": "SUIT 校园网自动认证守护进程（深圳信息职业技术大学，锐捷 ePortal）",
        "license": "MIT",
        # 完整声明运行期依赖，别只写 libc：
        #   busybox        提供 sed/awk/nc/hexdump/cut/tr/head/tail/wc/grep/logger
        #   uclient-fetch  发 HTTP 请求
        #   openssl-util   提供 openssl CLI（AES 加解密 + base64），注意是 util 不是 lib
        #   uci            读写 UCI 配置
        #   ubus           查 WAN IP / 服务状态
        # 不声明的话，装到精简固件上会「缺命令 → 静默失败」，排查起来很费劲。
        "depends": ["libc", "busybox", "uclient-fetch", "openssl-util", "uci", "ubus"],
        "provides": [],
        "conffiles": ["/etc/config/suit-portal"],
        "extra": {
            "etc/apk/protected_paths.d/suit-portal.list":
                "/etc/config/suit-portal\n",
        },
        "scripts": {
            # 安装后立刻跑一次 uci-defaults（迁移旧配置 + 启用服务），
            # 否则要等到下次重启 /etc/init.d/boot 才会执行。
            "postinst": """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ -f /etc/uci-defaults/99-suit-portal ]; then
	( . /etc/uci-defaults/99-suit-portal ) && rm -f /etc/uci-defaults/99-suit-portal
fi
exit 0
""",
        },
    },
    {
        "name": "luci-app-suit-portal",
        "tree": "luci-app-suit-portal",
        "description": "SUIT 校园网自动认证 LuCI 配置界面",
        "license": "MIT",
        "depends": ["suit-portal", "luci-base"],
        "provides": [],
        "conffiles": [],
        "extra": {},
        "scripts": {},
    },
]


def walk_tree(base):
    """返回 [(relpath, mode, bytes|None, link|None)]"""
    out = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, base).replace("\\", "/")
            if rel.startswith("."):
                continue
            if any(rel.startswith(p) for p in EXEC_PREFIXES):
                mode = 0o755
            else:
                mode = 0o644
            with open(full, "rb") as f:
                out.append((rel, mode, f.read(), None))
    return out


VIEW_PREFIX = "www/luci-static/resources/view/"


def apply_view_cache_buster(entries):
    """给 view 下的 JS 文件名塞进内容哈希，并同步改 menu.d 里的 action.path。

    ⭐ 为什么必须做这件事（实机踩过，用户报「装完了但页面没变化」）：

    LuCI 的客户端加载器（/www/luci-static/resources/luci.js）拼 URL 是这么拼的：

        url = '<base>/<path>.js?v=<env.resource_version>'

    而 `env.resource_version` 是从**页面里 luci.js 那个 <script> 标签**解析出来的
    —— 也就是 **LuCI 自己的版本号**（如 26.236.50544~cb5d434），
    **跟我们这个包的版本毫无关系**。

    后果：升级我们的包时，`portal.js?v=26.236.…` 这个 URL **一个字都不变**；
    而 uhttpd 对 /luci-static/ 下的静态文件**不发 Cache-Control**（只有 ETag /
    Last-Modified），浏览器就按启发式缓存继续用旧 JS —— 用户看到的是上一版界面。

    把**内容哈希写进文件名**就绕开了：内容一变 URL 就变，浏览器没有旧缓存可用，
    只能重新拉。源码树里文件仍叫 `portal.js`（好写好读），只在打包时改名 +
    同步改 menu.d 的 path，两边永远一致。

    返回新的 entries；不改动源码树。

    ⚠️ 哈希用**连字符**分隔，绝不能用点：LuCI 的 require() 里是
        name.replace(/\\./g, '/')
    —— **文件名里任何一个点都会被当成路径分隔符**，`portal.<hash>.js` 会被解析成
    `view/suit-portal/portal/<hash>.js` → 404，整个页面变成空白。
    （实机踩过：改完页面只剩一个「关闭」按钮，因为 view 没加载出来。）
    """
    renamed = {}
    for rel, mode, data, link in entries:
        if rel.startswith(VIEW_PREFIX) and rel.endswith(".js") and data is not None:
            h = hashlib.sha256(data).hexdigest()[:8]
            base = rel[:-len(".js")]
            renamed[rel] = base + "-" + h + ".js"

    if not renamed:
        return entries

    out = []
    for rel, mode, data, link in entries:
        if rel in renamed:
            out.append((renamed[rel], mode, data, link))
            continue

        # menu.d 里的 "path": "suit-portal/portal" 要跟着改成带哈希的名字
        if "/luci/menu.d/" in rel:
            txt = data.decode("utf-8")
            for old_rel, new_rel in renamed.items():
                old_path = old_rel[len(VIEW_PREFIX):-len(".js")]
                new_path = new_rel[len(VIEW_PREFIX):-len(".js")]
                txt = txt.replace('"%s"' % old_path, '"%s"' % new_path)
            data = txt.encode("utf-8")

        out.append((rel, mode, data, link))
    return out


def build_one(spec, compress, arch=UNIVERSAL_ARCH, out_dir=DIST_DIR):
    tree = os.path.join(PKG_DIR, spec["tree"])
    if not os.path.isdir(tree):
        raise SystemExit("目录不存在: %s" % tree)

    b = PkgBuilder({
        "name": spec["name"],
        "version": VERSION,
        "arch": arch,
        "description": spec["description"],
        "license": spec["license"],
        "origin": spec["name"],
        "maintainer": MAINTAINER,
        "url": URL,
        "depends": spec["depends"],
        "provides": spec["provides"],
        "scripts": spec.get("scripts") or None,
    }, compression=None if not compress else 9)

    # view 下的 JS 文件名带内容哈希，绕开 LuCI 那个「用自己版本号当 cache key」的坑
    for rel, mode, data, link in apply_view_cache_buster(walk_tree(tree)):
        b.add_file(rel, mode, data)
    # 额外生成的小文件（如 protected_paths.list）
    for rel, content in spec["extra"].items():
        b.add_file(rel, 0o644, content.encode("utf-8"))

    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "%s_%s_%s.apk" % (spec["name"], VERSION, arch))
    with open(out_path, "wb") as f:
        f.write(b.build())
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-compress", action="store_true")
    ap.add_argument("--arch", default=UNIVERSAL_ARCH,
                    help="覆盖包内 arch 字段。默认 " + UNIVERSAL_ARCH +
                         "（通用，所有架构都能装）；要指定架构就用 " + ARCH +
                         " 之类。注意 apk-tools 3 不认 `all`，通用必须写 noarch。")
    ap.add_argument("--out-dir", default=DIST_DIR)
    args = ap.parse_args()

    total = []
    for spec in PACKAGES:
        p = build_one(spec, compress=not args.no_compress,
                      arch=args.arch, out_dir=args.out_dir)
        sz = os.path.getsize(p)
        sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
        total.append((p, sz, sha))
        print("生成 %s  (%d 字节)" % (os.path.relpath(p, ROOT), sz))
    print()
    for p, sz, sha in total:
        print("%-58s %7d  sha256=%s" % (os.path.basename(p), sz, sha[:16]))


if __name__ == "__main__":
    main()
