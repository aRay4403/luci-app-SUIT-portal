#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
发布前隐私闸门 —— 扫**整个源码树**（不只是 dist/），发现疑似个人信息就报错退出。

为什么需要它：
    apkcheck.py 只解包 apk，查不到源码树。而实际泄露往往发生在源码里
    （注释里贴的真实报文、测试脚本里写死的入口 URL、fixture 里没洗干净的票据）。
    目录级 .gitignore 也挡不住「被手工改写后放进 tests/ 的内容」——
    规则管路径，管不住内容。

用法：
    python tools/privacy_check.py            # 扫当前目录，有问题退出码 1
    python tools/privacy_check.py --verbose  # 连允许的命中一起打印

会检查：
    1. 源码树里所有文本文件
    2. dist/ 下的 apk（自动解包，复用 apkcheck 的逻辑）
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (正则, 说明)
PATTERNS = [
    (r"croypto=[A-Za-z0-9%+/=]{20,}",        "AES 密钥（croypto）明文"),
    (r"password=[A-Za-z0-9%+/=]{20,}",       "密码密文（password）"),
    (r"wlanuserip=[0-9a-fA-F]{16,}",         "入口 URL 里的加密 IP"),
    (r"wlanacname=[0-9a-fA-F]{16,}",         "入口 URL 里的加密 AC 标识"),
    (r"nasip=[0-9a-fA-F]{16,}",              "入口 URL 里的加密 NASIP"),
    (r"(?<![A-Za-z])mac=[0-9a-fA-F]{16,}",   "入口 URL 里的加密 MAC"),
    (r"nasportid=[0-9a-fA-F]{16,}",          "入口 URL 里的加密 NASPORTID"),
    (r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}", "JWT / CAS 票据"),
    # 下面几条故意把字面量拆成两段拼接，否则本文件会被自己的规则命中
    (r"SOURCEID" r"_TGC=(?!<)",              "CAS TGC 票据未脱敏"),
    (r"ticket=ST" r"-\d",                    "CAS Service Ticket 未脱敏"),
    (r"rg_object" r"id=[0-9a-fA-F]{16,}",    "CAS 对象 ID 未脱敏"),
    (r"flowSession" r"Id=[0-9a-fA-F]{8,}",   "流程会话 ID 未脱敏"),
    (r"userIp=(?!<)[0-9]{1,3}\.[0-9]{1,3}\.", "客户端内网 IP 未脱敏"),
]

# 已知安全的值（演示数据 / 示例地址），命中后跳过
ALLOW_SUBSTRINGS = [
    "RVET5N6VgbAfq82H+BmC8A==",
    "RVET5N6VgbAfq82H%2BBmC8A%3D%3D",
    "5RpNbPt4pc869u8a1b4frA==",
    "5RpNbPt4pc869u8a1b4frA%3D%3D",
    "123.123.123.123",
    "114.114.114.114",
    "1.1.1.1",
]

SKIP_DIRS = {".git", "__pycache__", "node_modules"}
TEXT_EXT = {".md", ".sh", ".js", ".py", ".json", ".conf", ".txt", ".html", ".css", ".init"}


def iter_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            yield p, os.path.relpath(p, ROOT).replace("\\", "/")


def scan_text(path, rel, verbose):
    hits = []
    try:
        txt = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        return hits
    for pat, desc in PATTERNS:
        for m in re.finditer(pat, txt):
            val = m.group(0)
            if any(a in val for a in ALLOW_SUBSTRINGS):
                if verbose:
                    print("  [skip] %s:%d %s（允许值）" % (rel, txt.count("\n", 0, m.start()) + 1, val[:50]))
                continue
            hits.append((rel, txt.count("\n", 0, m.start()) + 1, desc, val[:80]))
    return hits


def scan_apk(path, rel):
    """复用 apkcheck 的解包逻辑，扫包内每个文件。"""
    hits = []
    try:
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import apkcheck
        body, _ = apkcheck.load_body(path)
        # extract_files 产出 (path_idx, file_idx, content)
        entries = [(str(pi), str(fi), c) for pi, fi, c in apkcheck.extract_files(body)]
    except Exception as e:
        print("  [warn] 无法解包 %s: %s" % (rel, e))
        return hits
    for pi, fi, content in entries:
        try:
            txt = content.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for pat, desc in PATTERNS:
            for m in re.finditer(pat, txt):
                val = m.group(0)
                if any(a in val for a in ALLOW_SUBSTRINGS):
                    continue
                hits.append(("%s!blk%s.%s" % (rel, pi, fi), 0, desc, val[:80]))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true", help="连允许值一起打印")
    args = ap.parse_args()

    all_hits = []
    for p, rel in iter_files():
        ext = os.path.splitext(p)[1].lower()
        if ext == ".apk":
            all_hits += scan_apk(p, rel)
        elif ext in TEXT_EXT or os.path.basename(p) in ("nc", "uclient-fetch"):
            all_hits += scan_text(p, rel, args.verbose)

    if all_hits:
        print("❌ 发现 %d 处疑似个人信息，禁止发布：\n" % len(all_hits))
        for rel, line, desc, val in all_hits:
            print("  %s%s  %s\n      %s" % (rel, (":%d" % line) if line else "", desc, val))
        return 1

    print("✅ 未发现个人信息残留（源码树 + dist/ 全部扫过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
