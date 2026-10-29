#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apk v3 (ADB) 打包器 —— 纯 Python 实现，无需 OpenWrt SDK / Docker / Linux。

背景
----
OpenWrt 25.12 起包管理器从 opkg 换成 apk-tools 3.x，包格式是全新的 "ADB"
(apk database) 二进制格式，与旧的 .ipk 完全不同。官方推荐用 SDK + abuild 构建，
但这台机器上没有 Linux/Docker/WSL，所以这里按官方规范直接生成 v3 包。

格式依据
--------
* apk-tools/doc/apk-v3.5.scd（官方规范）
* 7Ji《Into Alpine APK v3 format: the binary perspective》（字节级拆解）
* 实测对照：mirrors 上的 zlib-1.3.1-r1.apk，用 `apk adbdump` 逐字段比对

文件结构
--------
    "ADB" + 压缩标记            # 文件头；'d'=deflate, '.'=不压缩, 'c'+alg+level
    ---- 以下为 body（压缩体）----
    "ADB." + "pckg"             # body magic + schema
    [ADB_BLOCK_ADB]             # 元数据（必须第一个）
    [ADB_BLOCK_SIG]             # 签名（可选）
    [ADB_BLOCK_DATA] ...        # 每个文件内容一个块

tag 编码（32 位小端）
---------------------
    高 4 位 = 类型；低 28 位 = 立即值 或 相对 payload 起点的偏移
    ADB_TYPE_INT=0x1, INT_32=0x2, INT_64=0x3
    BLOB_8=0x8, BLOB_16=0x9, BLOB_32=0xa, ARRAY=0xd, OBJECT=0xe

对象/数组
---------
    偏移处：u32 元素个数（**含自身计数**），随后是若干 adb_val_t。
    即 count = 1 + 值槽个数；空槽写 0，末尾空槽可省略。

用法
----
    python mkadb.py --spec pkg.json --out out.apk
"""

import argparse
import hashlib
import json
import os
import stat as statmod
import struct
import sys
import time
import zlib

# --------------------------------------------------------------------------
# 类型常量
# --------------------------------------------------------------------------
ADB_TYPE_INT = 0x10000000
ADB_TYPE_INT_32 = 0x20000000
ADB_TYPE_INT_64 = 0x30000000
ADB_TYPE_BLOB_8 = 0x80000000
ADB_TYPE_BLOB_16 = 0x90000000
ADB_TYPE_BLOB_32 = 0xA0000000
ADB_TYPE_ARRAY = 0xD0000000
ADB_TYPE_OBJECT = 0xE0000000
ADB_VALUE_MASK = 0x0FFFFFFF

ADB_BLOCK_ADB = 0
ADB_BLOCK_SIG = 1
ADB_BLOCK_DATA = 2

ADB_BLOCK_ALIGNMENT = 8

# 依赖匹配位（vercmp 操作）
MATCH_EQUAL = 0b00001
MATCH_LESS = 0b00010
MATCH_GREATER = 0b00100
MATCH_FUZZY = 0b01000
MATCH_CONFLICT = 0b10000


class Payload:
    """ADB payload 构造器。

    payload 的前 8 字节是 adb_hdr（compat_ver, ver, reserved, root），
    所有偏移都相对 payload 起点（即含这 8 字节）。
    """

    def __init__(self):
        self.buf = bytearray(8)  # adb_hdr 占位，最后回填 root

    # -- 基础写入 ---------------------------------------------------------
    def _add(self, data):
        off = len(self.buf)
        self.buf += data
        return off

    # -- 标量 -------------------------------------------------------------
    def blob(self, data):
        """写一个 blob，返回 adb_val_t。按长度自动选 BLOB_8/16/32。"""
        if isinstance(data, str):
            data = data.encode("utf-8")
        n = len(data)
        if n <= 0xFF:
            hdr = bytes([n])
            typ = ADB_TYPE_BLOB_8
        elif n <= 0xFFFF:
            hdr = struct.pack("<H", n)
            typ = ADB_TYPE_BLOB_16
        else:
            hdr = struct.pack("<I", n)
            typ = ADB_TYPE_BLOB_32
        return typ | self._add(hdr + data)

    def int(self, v):
        """写一个整数。放得进 28 位就直接内联，否则写 INT_32。"""
        v = int(v)
        if 0 <= v <= ADB_VALUE_MASK:
            return ADB_TYPE_INT | v
        return ADB_TYPE_INT_32 | self._add(struct.pack("<I", v & 0xFFFFFFFF))

    def null(self):
        return 0  # ADB_VAL_NULL

    # -- 容器 -------------------------------------------------------------
    def _slots(self, items):
        return (
            struct.pack("<I", len(items) + 1)
            + b"".join(struct.pack("<I", x & 0xFFFFFFFF) for x in items)
        )

    def obj(self, slots):
        """slots: 从 ID 1 开始的 adb_val_t 列表（不含 count）。"""
        return ADB_TYPE_OBJECT | self._add(self._slots(slots))

    def arr(self, items):
        return ADB_TYPE_ARRAY | self._add(self._slots(items))

    # -- 收尾 -------------------------------------------------------------
    def finish(self, root):
        struct.pack_into("<I", self.buf, 4, root & 0xFFFFFFFF)
        return bytes(self.buf)


def acl(p, mode, user="root", group="root"):
    """ACL 对象：1=mode 2=user 3=group"""
    return p.obj([p.int(mode), p.blob(user), p.blob(group)])


def hexblob(p, hexstr):
    """hexblob 字段：**必须存原始二进制**，不能存 hex 字符串。

    踩坑记录：一开始按博客的「hexblob 以字符串形式存储」写成 64 字符的 hex 串，
    结果 apk adbdump 显示成一长串「hex 的 hex」（apk 把存储的字节当原始值再做一次
    hex 编码）。对照官方 zlib 包：file hash 存的是 32 字节原始 SHA256，
    pkginfo hashes 存的是 20 字节原始 SHA1。
    """
    return p.blob(bytes.fromhex(hexstr))


def dep(p, name, version=None, match=MATCH_EQUAL):
    """依赖对象：1=name 2=version 3=match"""
    slots = [p.blob(name)]
    if version:
        slots.append(p.blob(version))
        slots.append(p.int(match))
    return p.obj(slots)


def dep_array(p, specs):
    """specs: ["libc", "luci-base", ...] -> ARRAY of dep objects"""
    return p.arr([dep(p, s) for s in specs])


def file_entry(p, name, mode, data=None, link=None, mtime=0):
    """文件项：1=name 2=acl 3=size 4=mtime 5=hashes 6=target

    * 普通文件：size = 内容长度，hash = SHA256 hex
    * 符号链接：size = **链接目标字符串长度**（不含 2 字节类型头），
                target blob = u16(S_IFLNK) + 目标字符串；hash 槽留空
    """
    slots = [p.blob(name), acl(p, mode)]
    if link is not None:
        tgt = link.encode("utf-8")
        slots.append(p.int(len(tgt)))          # size
        slots.append(p.int(mtime))
        slots.append(0)                        # hashes 空槽
        slots.append(p.blob(struct.pack("<H", 0o120000) + tgt))
    else:
        slots.append(p.int(len(data)))         # size
        slots.append(p.int(mtime))
        slots.append(hexblob(p, hashlib.sha256(data).hexdigest()))
    return p.obj(slots)


class PkgBuilder:
    """按 OpenWrt 的目录树布局组装一个 v3 包。"""

    def __init__(self, info, compression=9):
        self.info = info
        self.compression = compression
        # paths: [(dirname, mode, [(fname, mode, data|None, link|None)])]
        self.paths = {}

    def add_file(self, path, mode, data, mtime=None):
        path = path.lstrip("/")
        d, _, fname = path.rpartition("/")
        if mtime is None:
            mtime = int(time.time())
        self.paths.setdefault(d, []).append((fname, mode, data, None, mtime))

    def add_link(self, path, target, mtime=None):
        path = path.lstrip("/")
        d, _, fname = path.rpartition("/")
        if mtime is None:
            mtime = int(time.time())
        self.paths.setdefault(d, []).append((fname, 0o777, None, target, mtime))

    def add_dir(self, path, mode=0o755):
        path = path.strip("/")
        self.paths.setdefault(path, [])

    # ------------------------------------------------------------------
    def build(self):
        p = Payload()
        mtime_default = int(time.time())

        # ---- PKGINFO ---------------------------------------------------
        # 槽位（1 起）：1 name 2 version 3 hashes 4 description 5 arch 6 license
        #               7 origin 8 maintainer 9 url 10 repo_commit 11 build_time
        #               12 installed_size 13 file_size 14 provider_priority
        #               15 depends 16 provides 17 replaces 18 install_if
        #               19 recommends 20 layer 21 tags
        installed_size = sum(
            len(d) for _, _, d, _, _ in
            (e for v in self.paths.values() for e in v) if d is not None
        )
        def _b(s):
            """空串 -> null 槽（adbdump 里不会显示无意义的空字段）"""
            return p.blob(s) if s else 0

        pkginfo = p.obj([
            p.blob(self.info["name"]),
            p.blob(self.info["version"]),
            0,                                              # 3 hashes（不填）
            _b(self.info.get("description", "")),
            p.blob(self.info["arch"]),
            _b(self.info.get("license", "")),
            _b(self.info.get("origin", "")),
            _b(self.info.get("maintainer", "")),
            _b(self.info.get("url", "")),
            0,                                              # 10 repo-commit
            p.int(self.info.get("build_time", mtime_default)),
            p.int(installed_size),
            0,                                              # 13 file-size
            0,                                              # 14 provider-priority
            dep_array(p, self.info.get("depends", [])),
            dep_array(p, self.info.get("provides", [])),
        ])

        # ---- PATHS -----------------------------------------------------
        # 先算好每个目录里有哪些文件，顺序必须稳定（DATA 块的 path_idx 依赖它）
        dirnames = sorted(self.paths.keys(), key=lambda x: (x.count("/"), x))
        if "" not in dirnames:
            dirnames.insert(0, "")
        path_vals = []
        for d in dirnames:
            entries = sorted(self.paths.get(d, []), key=lambda e: e[0])
            fvals = [
                file_entry(p, fn, mode, data=data, link=link, mtime=mt)
                for fn, mode, data, link, mt in entries
            ]
            slots = [p.blob(d) if d else 0, acl(p, 0o755)]
            if fvals:
                slots.append(p.arr(fvals))
            path_vals.append(p.obj(slots))
        paths_obj = p.arr(path_vals)

        # ---- root OBJECT：1 PKGINFO 2 PATHS 3 SCRIPTS 4 TRIGGERS -------
        root_slots = [pkginfo, paths_obj]
        if self.info.get("scripts"):
            sc = self.info["scripts"]
            order = ["trigger", "preinst", "postinst", "predeinst",
                     "postdeinst", "preupgrade", "postupgrade"]
            # 【坑】脚本槽是**按位置**的：只填 postinst 时必须补 null 占位，
            # 否则会被当成 slot1=trigger 解读。末尾空槽再裁掉。
            scslots = []
            for k in order:
                v = sc.get(k)
                scslots.append(p.blob(v) if v else 0)
            while scslots and scslots[-1] == 0:
                scslots.pop()
            if scslots:
                root_slots.append(p.obj(scslots))
        root = p.obj(root_slots)

        payload = p.finish(root)

        # ---- 组装 body --------------------------------------------------
        body = b"ADB." + b"pckg"
        body += adb_block(ADB_BLOCK_ADB, payload)

        # DATA 块：每个普通文件一个，(path_idx, file_idx) 均为 1 基
        for pi, d in enumerate(dirnames, start=1):
            entries = sorted(self.paths.get(d, []), key=lambda e: e[0])
            for fi, (fn, mode, data, link, mt) in enumerate(entries, start=1):
                if data is None:
                    continue  # 符号链接没有内容
                hdr = struct.pack("<II", pi, fi)
                body += adb_block(ADB_BLOCK_DATA, hdr + data)

        # ---- 文件头 + 压缩 ----------------------------------------------
        if self.compression is None:
            return b"ADB." + body
        co = zlib.compressobj(self.compression, zlib.DEFLATED, -zlib.MAX_WBITS)
        comp = co.compress(body) + co.flush()
        return b"ADBd" + comp


def adb_block(typ, payload):
    """构造一个 ADB 块：4 字节头 + payload，并补齐到 8 字节边界。"""
    raw = 4 + len(payload)
    out = struct.pack("<I", (typ << 30) | raw) + payload
    pad = (-raw) % ADB_BLOCK_ALIGNMENT
    return out + b"\x00" * pad


# --------------------------------------------------------------------------
# 从目录树生成 spec
# --------------------------------------------------------------------------
def collect_tree(root_dir):
    """把 root_dir 下的文件/链接收集成 [(relpath, mode, data|None, link|None)]"""
    out = []
    for dirpath, dirnames, filenames in os.walk(root_dir):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root_dir).replace("\\", "/")
            if os.path.islink(full):
                out.append((rel, 0o777, None, os.readlink(full)))
            else:
                st = os.stat(full)
                with open(full, "rb") as f:
                    out.append((rel, st.st_mode & 0o7777, f.read(), None))
    return out


def main():
    ap = argparse.ArgumentParser(description="apk v3 (ADB) packer")
    ap.add_argument("--spec", required=True, help="JSON 描述文件")
    ap.add_argument("--out", required=True, help="输出 .apk 路径")
    ap.add_argument("--no-compress", action="store_true", help="不压缩（调试用）")
    args = ap.parse_args()

    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)

    b = PkgBuilder(spec["info"],
                   compression=None if args.no_compress else 9)
    for d in spec.get("dirs", []):
        b.add_dir(d)
    for item in spec["files"]:
        src = item["src"]
        if item.get("link"):
            b.add_link(item["dest"], item["link"])
            continue
        with open(src, "rb") as f:
            data = f.read()
        b.add_file(item["dest"], int(item.get("mode", "644"), 8), data)

    out = b.build()
    with open(args.out, "wb") as f:
        f.write(out)
    print("生成 %s (%d 字节)" % (args.out, len(out)))


if __name__ == "__main__":
    main()
