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


def decode(text: str):
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
