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


PART = re.compile(r"DMGWP (\d+)/(\d+) (?:c=(\d+)\.([0-9a-f]+) )?")


def part_check(chunk: str) -> int:
    """Export.lua X.PartCheck."""
    total = 0
    for ch in chunk.encode():
        total = (total * 31 + ch) % 16777213
    return total


def join_parts(text: str) -> str:
    """A report in parts ("DMGWP 1/3 DMGW1:...", "DMGWP 2/3 ...", pasted together or one after another): their
    slices joined in order. Text without part tags comes back unchanged."""
    marks = list(PART.finditer(text))
    if not marks:
        return text
    total = int(marks[0].group(2))
    slices, bad = {}, []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        chunk = text[m.end():end]
        # whatever the player typed after a part (the next message's "What went wrong:") is not report data
        chunk = re.split(r"\n\s*What went wrong:|\n\s*What I was doing:", chunk)[0]
        # ... nor a note after the last part ("Quick note, I noticed..."): its letters would decode as data and garble
        # the end of the report. The data is base64 with no spaces; the first paragraph that isn't ends it.
        keep = []
        for para in re.split(r"\n\s*\n", chunk):
            if para.strip() and not re.fullmatch(r"[A-Za-z0-9+/=:\r\n ]+", para.strip()):
                break
            keep.append(para)
        data = "".join("".join(keep).split())
        if m.group(3):  # 1.6.0.33x+: "c=<length>.<checksum>" and END
            ended = data.endswith("END")
            data = data[:-3] if ended else data
            if not ended:
                bad.append("part %s has no END: cut off in the copy or the paste" % m.group(1))
            elif len(data) != int(m.group(3)) or part_check(data) != int(m.group(4), 16):
                bad.append("part %s changed in the copy or the paste (%d characters, expected %s)"
                           % (m.group(1), len(data), m.group(3)))
        slices[int(m.group(1))] = data
    if bad:
        print("WARNING: " + "; ".join(bad) + " - copy those parts again", file=sys.stderr)
    missing = [i for i in range(1, total + 1) if i not in slices]
    if missing:
        raise ValueError("report parts missing: %s of %d" % (missing, total))
    return "".join(slices[i] for i in range(1, total + 1))


def loads_salvage(js: str):
    """json.loads; when the end is garbled (a character changed in transit: raw deflate has no checksum, so what
    follows decodes as nonsense - a 1.6.0.321 report broke 99.5% of the way in), keep everything up to the last whole
    event before the damage and close what was open. Says so on stderr."""
    try:
        return json.loads(js)
    except json.JSONDecodeError as err:
        bad = err.pos
    def closed(head):
        stack, in_str, esc = [], False, False
        for ch in head:
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch in "[{":
                stack.append(ch)
            elif ch in "]}" and stack:
                stack.pop()
        if in_str:
            return None
        return head + "".join("]" if c == "[" else "}" for c in reversed(stack))

    # (the damage can start before the point the parser stops: step back event by event until what is left parses)
    cut, data = bad, None
    for _ in range(500):
        cut = js.rfind("],[", 0, cut)
        if cut < 0:
            break
        whole = closed(js[:cut + 1])
        if whole:
            try:
                data = json.loads(whole)
                break
            except json.JSONDecodeError:
                pass
    if data is None:
        raise ValueError("report damaged at %d and nothing before it could be kept" % bad)
    sys.stderr.write("warning: the report is damaged at %d of %d characters (a changed character in the pasted "
                     "text?): kept what came before it\n" % (bad, len(js)))
    if isinstance(data, dict):
        data["damagedAt"] = bad
    return data


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
        return loads_salvage(inflate(raw).decode("utf-8", errors="replace"))
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
