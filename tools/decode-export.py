#!/usr/bin/env python3
"""Decode a DMGAssist Watchdog export string into readable JSON.

A SavedVariables file works too (WTF/Account/<account>/SavedVariables/DMGAssist_Watchdog.lua): every stored fight.

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


def lua_saved_variables(text: str):
    """The Watchdog's SavedVariables file (WTF/Account/<account>/SavedVariables/DMGAssist_Watchdog.lua) as the same
    structure an export decodes to: every stored fight with its recording, no copying and pasting of parts (owner,
    2026-11-16: "copy and paste on 15 different sections is annoying and obviously error prone")."""
    i, n = 0, len(text)

    def ws():
        nonlocal i
        while i < n:
            if text[i] in " \t\r\n,;":
                i += 1
            elif text.startswith("--", i):
                j = text.find("\n", i)
                i = n if j < 0 else j + 1
            else:
                break

    def string():
        nonlocal i
        q = text[i]
        i += 1
        out = []
        while text[i] != q:
            c = text[i]
            if c == "\\":
                i += 1
                e = text[i]
                if e.isdigit():
                    j = i
                    while j < i + 3 and j < n and text[j].isdigit():
                        j += 1
                    out.append(chr(int(text[i:j])))
                    i = j
                    continue
                out.append({"n": "\n", "t": "\t", "r": "\r", "\n": "\n"}.get(e, e))
            else:
                out.append(c)
            i += 1
        i += 1
        return "".join(out)

    def value():
        nonlocal i
        ws()
        c = text[i]
        if c == "{":
            i += 1
            arr, obj = [], {}
            while True:
                ws()
                if text[i] == "}":
                    i += 1
                    break
                if text[i] == "[":
                    i += 1
                    ws()
                    k = value()
                    ws()
                    i += 1  # ]
                    ws()
                    i += 1  # =
                    obj[k] = value()
                else:
                    arr.append(value())
            if obj and not arr:
                keys = list(obj)
                if all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
                    return [obj[k] for k in range(1, len(keys) + 1)]
                return {str(k): v for k, v in obj.items()}
            if obj:
                for k, v in obj.items():
                    if isinstance(k, int) and k == len(arr) + 1:
                        arr.append(v)
                return arr
            return arr
        if c in "\"'":
            return string()
        m = re.match(r"-?(?:\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+|inf|nan)", text[i:i + 40])
        if text.startswith("true", i):
            i += 4
            return True
        if text.startswith("false", i):
            i += 5
            return False
        if text.startswith("nil", i):
            i += 3
            return None
        if m:
            i += len(m.group(0))
            v = float(m.group(0))
            return int(v) if v.is_integer() and "." not in m.group(0) else v
        raise ValueError("SavedVariables: can't read at %d: %r" % (i, text[i:i + 30]))

    at = text.find("DMGAssistWatchdogDB")
    i = text.find("=", at) + 1
    db = value()
    db["format"] = "dmgassist-watchdog"
    db["fromSavedVariables"] = True
    return db


def decode(text: str):
    if "DMGAssistWatchdogDB" in text[:200]:
        return lua_saved_variables(text)
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
    text = sys.stdin.read() if args.source == "-" else open(args.source, encoding="utf-8", errors="replace").read()
    data = decode(text)
    out = json.dumps(data, indent=2, sort_keys=True)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(out)
    else:
        print(out)


if __name__ == "__main__":
    main()
