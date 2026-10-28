#!/usr/bin/env python3
"""앱 문구 번역 점검: 코드의 L("한국어", "English")·XAML {local:T Ko=…, En=…}에서 영어 문구(키)를 모아
assets/i18n/<lang>.strings 에 빠진 번역·쓰지 않는 번역이 있는지 본다.

  python3 tools/i18n.py check          # 빠진 것이 있으면 종료 코드 1
  python3 tools/i18n.py keys > k.json  # [{"en", "ko", "where"}] — 번역할 때 참고
"""
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["ja", "zh-Hans", "zh-Hant"]
SOURCES = sorted(ROOT.glob("mac/*.swift")) + sorted(ROOT.glob("windows/WirelessAdbReconnect/*.cs"))
XAML = sorted(ROOT.glob("windows/WirelessAdbReconnect/*.xaml"))
CALL = re.compile(r"(?<![\w.])L\(")
ESC = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}


def args_of(src, i):
    """src[i]는 '(' 다음 글자. 맨 바깥 쉼표로 나눈 인자 문자열들을 돌려준다."""
    out, cur, depth = [], "", 0
    while i < len(src):
        c = src[i]
        if c == '"':  # 문자열 리터럴 통째로 (\(…) 보간 안의 따옴표는 Swift 리터럴에선 쓰지 않음)
            j = i + 1
            while src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            cur += src[i:j + 1]
            i = j + 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                out.append(cur.strip())
                return out
            depth -= 1
        elif c == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
            i += 1
            continue
        cur += c
        i += 1
    raise ValueError("닫는 괄호 없음")


def literal(a):
    """보간·이어 붙이기 없는 문자열 리터럴이면 값, 아니면 None"""
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', a)
    if not m or "\\(" in m.group(1):
        return None
    return re.sub(r"\\(.)", lambda e: ESC.get(e.group(1), e.group(1)), m.group(1))


def extract():
    keys, errors = {}, []
    for f in SOURCES:
        src = f.read_text(encoding="utf-8")
        for m in CALL.finditer(src):
            line_start = src.rfind("\n", 0, m.start()) + 1
            if re.search(r"(func|string)\s+$", src[line_start:m.start()]):
                continue  # 정의
            where = f"{f.relative_to(ROOT)}:{src.count(chr(10), 0, m.start()) + 1}"
            a = args_of(src, m.end())
            en = literal(a[1]) if len(a) >= 2 else None
            if en is None:
                errors.append(f"{where}: 영어 문구가 리터럴이 아님 → {{0}} 자리표시 사용")
                continue
            keys.setdefault(en, {"en": en, "ko": literal(a[0]) or a[0], "where": where})
    for f in XAML:
        src = f.read_text(encoding="utf-8")
        for m in re.finditer(r"local:T Ko='([^']*)',\s*En='([^']*)'", src):
            en = html.unescape(m.group(2))
            where = f"{f.relative_to(ROOT)}:{src.count(chr(10), 0, m.start()) + 1}"
            keys.setdefault(en, {"en": en, "ko": html.unescape(m.group(1)), "where": where})
    keys.pop("", None)
    return keys, errors


def load(lang):
    p = ROOT / "assets" / "i18n" / f"{lang}.strings"
    if not p.exists():
        return {}
    lit = r'"((?:[^"\\]|\\.)*)"'
    un = lambda s: re.sub(r"\\(.)", lambda e: ESC.get(e.group(1), e.group(1)), s)
    return {un(k): un(v) for k, v in re.findall(rf"^{lit}\s*=\s*{lit}\s*;", p.read_text(encoding="utf-8"), re.M)}


def main():
    keys, errors = extract()
    if sys.argv[1:] == ["keys"]:
        json.dump(list(keys.values()), sys.stdout, ensure_ascii=False, indent=1)
        return 0
    bad = bool(errors)
    for e in errors:
        print(e)
    for lang in LANGS:
        t = load(lang)
        missing = [k for k in keys if k not in t]
        unused = [k for k in t if k not in keys]
        holes = [k for k in keys if k in t and sorted(re.findall(r"\{\d\}", k)) != sorted(re.findall(r"\{\d\}", t[k]))]
        print(f"{lang}: 문구 {len(keys)}개 중 번역 {len(keys) - len(missing)}개, 빠짐 {len(missing)}, 안 씀 {len(unused)}, 자리표시 불일치 {len(holes)}")
        for k in missing:
            print(f"  빠짐: {keys[k]['where']}: {k!r}")
        for k in unused:
            print(f"  안 씀: {k!r}")
        for k in holes:
            print(f"  자리표시 불일치: {k!r}")
        bad |= bool(missing or holes)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
