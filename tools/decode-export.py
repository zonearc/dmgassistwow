#!/usr/bin/env python3
"""Decode a DMGAssist Watchdog export string into readable JSON.

Usage:
    python3 tools/decode-export.py export.txt          # file containing the string
    python3 tools/decode-export.py - < export.txt      # from stdin
    python3 tools/decode-export.py export.txt -o out.json

Formats:
    DMGW1:<base64>   base64(deflate(json))   (C_EncodingUtil available)
    DMGW0:<lua>      Lua table literal       (fallback; printed as-is)
"""
import argparse
import base64
import json
import re
import sys
import zlib


def inflate(data: bytes) -> bytes:
    # CompressString's "Deflate" may be raw deflate or zlib-wrapped; try both.
    for wbits in (-15, 15, 31):
        try:
            return zlib.decompress(data, wbits)
        except zlib.error:
            continue
    raise ValueError("could not decompress payload (not deflate/zlib/gzip)")


PART = re.compile(r"DMGWP (\d+)/(\d+) ")


def join_parts(text: str) -> str:
    """A report in parts ("DMGWP 1/3 DMGW1:...", "DMGWP 2/3 ...", pasted together or one after another): their
    slices joined in order. Text without part tags comes back unchanged."""
    marks = list(PART.finditer(text))
    if not marks:
        return text
    total = int(marks[0].group(2))
    slices = {}
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        chunk = text[m.end():end]
        # whatever the player typed after a part (the next message's "What went wrong:") is not report data
        chunk = re.split(r"\n\s*What went wrong:|\n\s*What I was doing:", chunk)[0]
        slices[int(m.group(1))] = "".join(chunk.split())
    missing = [i for i in range(1, total + 1) if i not in slices]
    if missing:
        raise ValueError("report parts missing: %s of %d" % (missing, total))
    return "".join(slices[i] for i in range(1, total + 1))


def decode(text: str):
    text = join_parts(text)
    # A pasted report can start with the player's own words ("What went wrong: ..."); the string follows them.
    for prefix in ("DMGW1:", "DMGW0:"):
        at = text.find(prefix)
        if at > 0:
            text = text[at:]
            break
    text = "".join(text.split())  # copy/paste may add line breaks
    if text.startswith("DMGW1:"):
        raw = base64.b64decode(text[6:] + "=" * (-len(text[6:]) % 4))
        # a report cut mid-character (a long note trimmed by bytes) must still decode
        return json.loads(inflate(raw).decode("utf-8", errors="replace"))
    if text.startswith("DMGW0:"):
        return {"format": "lua-literal", "lua": text[6:]}
    raise ValueError("not a DMGAssist Watchdog export (expected DMGW1: or DMGW0: prefix)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="file with the export string, or - for stdin")
    ap.add_argument("-o", "--output", help="write JSON here instead of stdout")
    args = ap.parse_args()
    text = sys.stdin.read() if args.source == "-" else open(args.source, encoding="utf-8").read()
    data = decode(text)
    out = json.dumps(data, indent=2, sort_keys=True)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(out)
    else:
        print(out)


if __name__ == "__main__":
    main()
