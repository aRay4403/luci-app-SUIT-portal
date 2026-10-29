#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apk v3 (ADB) 包内容检查器 —— 把 body 解压后，抽出每个 DATA 块的文件内容。

用途：验收「发布的包不含任何个人信息」。
     python tools/apkcheck.py dist/suit-portal_1.0.0-r1_aarch64_cortex-a53.apk
     python tools/apkcheck.py <apk> --grep 尚未配置
     python tools/apkcheck.py <apk> --forbid <你的账号> <你的密码> <你的用户名>

为什么需要它：ADB 包整体是 deflate 压缩的，直接 grep 二进制文件搜不到明文，
所以必须先解压 body 再搜。
"""

import argparse
import re
import struct
import sys
import zlib


def load_body(path):
    raw = open(path, "rb").read()
    if not raw.startswith(b"ADB"):
        raise SystemExit("不是 ADB 包（magic 不对）: %r" % raw[:4])
    flag = raw[3:4]
    if flag == b".":
        return raw[4:], "不压缩"
    if flag == b"d":
        d = zlib.decompressobj(-zlib.MAX_WBITS)
        return d.decompress(raw[4:]) + d.flush(), "deflate"
    raise SystemExit("未知压缩标记: %r" % flag)


def walk_blocks(body):
    """返回 [(block_type, payload)]。block_type: 0=ADB 1=SIG 2=DATA"""
    if body[:4] != b"ADB.":
        raise SystemExit("body magic 不对: %r" % body[:4])
    off = 8  # "ADB." + "pckg"
    while off + 4 <= len(body):
        hdr = struct.unpack_from("<I", body, off)[0]
        typ = hdr >> 30
        raw_size = hdr & 0x3FFFFFFF
        payload = body[off + 4: off + raw_size]
        yield typ, payload
        off += raw_size
        off += (-raw_size) % 8  # 块补齐到 8 字节


def extract_files(body):
    """DATA 块的 payload = u32 path_idx + u32 file_idx + 文件内容"""
    for typ, payload in walk_blocks(body):
        if typ == 2 and len(payload) >= 8:
            pi, fi = struct.unpack_from("<II", payload, 0)
            yield pi, fi, payload[8:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("apk")
    ap.add_argument("--grep", nargs="*", default=[], help="必须命中的关键字")
    ap.add_argument("--forbid", nargs="*", default=[], help="禁止出现的字符串")
    ap.add_argument("--except", dest="except_", action="append", default=[],
                    help="正则；命中该正则的**行**会被 --forbid 忽略。可重复给多次。")
    ap.add_argument("--except-file-marker", action="append", default=[],
                    help="若某个文件的内容里含该标记字符串，则**该文件整体**豁免 "
                         "--forbid 检查。用于「改名迁移脚本必须引用旧名字」这类场景 —— "
                         "在脚本里写一行 `# apkcheck-allow-old-name: 原因` 即可。可重复给多次。")
    ap.add_argument("--dump", action="store_true", help="打印每个文件的前几行")
    args = ap.parse_args()

    body, mode = load_body(args.apk)
    files = list(extract_files(body))
    print("压缩方式: %s   文件数: %d" % (mode, len(files)))
    print()

    blob_all = b""
    for pi, fi, data in files:
        blob_all += data + b"\x00"

    if args.dump:
        for pi, fi, data in files:
            head = data[:200].decode("utf-8", "replace").replace("\n", "\\n")
            print("  [%d,%d] %6d 字节  %s" % (pi, fi, len(data), head[:120]))
        print()

    rc = 0
    for kw in args.grep:
        hit = kw.encode("utf-8") in blob_all
        print("%s 必须命中: %s" % ("[OK]" if hit else "[!!]", kw))
        if not hit:
            rc = 1

    # 禁词检查：**逐文件、逐行**做。
    #   --except-file-marker 命中的文件整体跳过（迁移脚本要引用旧名字）
    #   --except 命中的行跳过
    # 逐行而不是整块搜，是为了能把「合理引用」精确摘出去，而不是一刀切放过整个文件。
    exc = re.compile("|".join(args.except_)) if args.except_ else None
    markers = args.except_file_marker
    exempt_files = set()
    for idx, (pi, fi, data) in enumerate(files):
        txt = data.decode("utf-8", "replace")
        for mk in markers:
            if mk in txt:
                exempt_files.add(idx)
                print("[豁免] 文件块[%d,%d] 含标记 %r，跳过禁词检查" % (pi, fi, mk))
    if exempt_files:
        print()

    for kw in args.forbid:
        hits = []
        for idx, (pi, fi, data) in enumerate(files):
            if idx in exempt_files:
                continue
            for ln in data.decode("utf-8", "replace").splitlines():
                if kw in ln and not (exc and exc.search(ln)):
                    hits.append("[%d,%d] %s" % (pi, fi, ln.strip()[:150]))
        print("%s 禁止出现: %s%s" % ("[!!]" if hits else "[OK]", kw,
                                     "  （%d 处）" % len(hits) if hits else ""))
        for h in hits[:6]:
            print("       " + h)
        if len(hits) > 6:
            print("       …还有 %d 处" % (len(hits) - 6))
        if hits:
            rc = 1

    # 顺手扫一遍像账号/密码的痕迹
    print()
    for pat in [rb"1[0-9]{9}", rb"\b[0-9]{10}\b"]:
        for m in set(re.findall(pat, blob_all)):
            print("  [注意] 疑似账号数字: %s" % m.decode())

    return rc


if __name__ == "__main__":
    sys.exit(main())
