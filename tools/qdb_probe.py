"""Probe QuestieDB baked TOC metadata (base64 -> zlib -> CBOR).

Read-only analysis helper. No game files are modified by this script.
"""
import re
import base64
import zlib
import struct
import sys
import json

TOC = r"D:\World of Warcraft\_forever_\Interface\AddOns\QuestieDB\QuestieDB_Forever.toc"


def load_meta(path=TOC):
    meta = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^## (X-[^:]+):[ ]?(.*)$", line.rstrip("\r\n"))
            if m:
                meta[m.group(1)] = m.group(2)
    return meta


def assemble(meta, key):
    head = meta.get(key)
    if head is None:
        return None
    m = re.fullmatch(r"~(\d+)~", head)
    if not m:
        return head
    n = int(m.group(1))
    parts = []
    for i in range(1, n + 1):
        part = meta.get("%s-%d" % (key, i))
        if part is None:
            raise KeyError("missing chunk %s-%d" % (key, i))
        parts.append(part)
    return "".join(parts)


def decode_cbor(data, off=0):
    """Minimal CBOR decoder sufficient for QuestieDB column blocks."""
    start = data[off]
    major, ai = start >> 5, start & 0x1F
    off += 1

    def arg(ai, off):
        if ai < 24:
            return ai, off
        if ai == 24:
            return data[off], off + 1
        if ai == 25:
            return struct.unpack_from(">H", data, off)[0], off + 2
        if ai == 26:
            return struct.unpack_from(">I", data, off)[0], off + 4
        if ai == 27:
            return struct.unpack_from(">Q", data, off)[0], off + 8
        if ai == 31:
            return None, off
        raise ValueError("bad additional info %d" % ai)

    val, off = arg(ai, off)
    if major == 0:
        return val, off
    if major == 1:
        return -1 - val, off
    if major in (2, 3):
        if val is None:  # indefinite
            chunks, out = [], bytearray()
            while data[off] != 0xFF:
                chunk, off = decode_cbor(data, off)
                out += chunk
            return (bytes(out) if major == 2 else out.decode("utf-8")), off + 1
        raw = data[off:off + val]
        off += val
        return (raw if major == 2 else raw.decode("utf-8")), off
    if major == 4:
        arr = []
        if val is None:
            while data[off] != 0xFF:
                item, off = decode_cbor(data, off)
                arr.append(item)
            return arr, off + 1
        for _ in range(val):
            item, off = decode_cbor(data, off)
            arr.append(item)
        return arr, off
    if major == 5:
        obj = {}
        if val is None:
            while data[off] != 0xFF:
                k, off = decode_cbor(data, off)
                v, off = decode_cbor(data, off)
                obj[k] = v
            return obj, off + 1
        for _ in range(val):
            k, off = decode_cbor(data, off)
            v, off = decode_cbor(data, off)
            obj[k] = v
        return obj, off
    if major == 6:
        item, off = decode_cbor(data, off)
        return item, off  # tags are transparent here
    if major == 7:
        if ai == 20:
            return False, off
        if ai == 21:
            return True, off
        if ai in (22, 23):
            return None, off
        if ai == 25:
            return struct.unpack_from(">e", data, off - 2)[0], off
        if ai == 26:
            return struct.unpack_from(">f", data, off - 4)[0], off
        if ai == 27:
            return struct.unpack_from(">d", data, off - 8)[0], off
        return val, off
    raise ValueError("bad major %d" % major)


def load_value(meta, key):
    enc = assemble(meta, key)
    if enc is None:
        return None
    raw = zlib.decompress(base64.b64decode(enc))
    value, end = decode_cbor(raw, 0)
    return value, raw, end


def describe(value, depth=0):
    pad = "  " * depth
    if isinstance(value, list):
        print("%slist len=%d" % (pad, len(value)))
        for i, v in enumerate(value[:3]):
            print("%s [%d] %s" % (pad, i, repr(v)[:220]))
            if isinstance(v, (list, dict)):
                describe(v, depth + 2)
    elif isinstance(value, dict):
        print("%sdict keys=%d sample=%s" % (pad, len(value), list(value)[:12]))
    else:
        print("%s%r" % (pad, value))


if __name__ == "__main__":
    meta = load_meta()
    print("metadata keys:", len(meta))
    keys = sys.argv[1:] or [
        "X-Quest-IDS", "X-l10n-zhCN-Quest", "X-l10n-zhCN-Npc",
        "X-l10n-zhCN-Item", "X-l10n-zhCN-Object",
    ]
    for key in keys:
        try:
            result = load_value(meta, key)
        except Exception as exc:
            print("\n== %s: ERROR %s" % (key, exc))
            continue
        if result is None:
            print("\n== %s: absent" % key)
            continue
        value, raw, end = result
        print("\n== %s: compressed=%d bytes cbor=%d consumed=%d" %
              (key, len(assemble(meta, key)) * 3 // 4, len(raw), end))
        describe(value)
