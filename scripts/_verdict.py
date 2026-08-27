#!/usr/bin/env python3
"""อ่าน response ของ LiteLLM จาก stdin แล้วบอกว่าโมเดลตัวนั้นอยู่ในสภาพไหน

ใช้โดย check-chain.sh — รับ body ที่มี "\\n__H__<http_code>" ต่อท้าย
คืน "<kind>\\t<รายละเอียด>" โดย kind = ok | quota | dead | wrong | broken

⚠️ ต้องดูทั้ง HTTP code และ choices — เช็คแค่ว่ามี key `error` ไหมไม่พอ
   LiteLLM คืน error ได้หลายรูป ทั้ง {"error":{"message":...}} และ {"detail":...}
   ตัวตรวจที่ดูรูปเดียวเคยรายงานว่า "ผ่านหมด" ทั้งที่ 404 ทุกตัว (2026-08-27)
"""
import json
import os
import re
import sys


def main() -> None:
    raw = sys.stdin.read()
    m = re.search(r"__H__(\d+)", raw)
    code = m.group(1) if m else "?"
    payload = re.sub(r"\n?__H__\d+$", "", raw)

    try:
        d = json.loads(payload)
    except Exception:
        # curl exit 28 = เราตัดสายเอง ไม่ใช่โมเดลพัง — แยกให้ชัดเหมือนที่
        # probe-thai.sh แยก exit 124 ออกจาก "พัง" (เคยอ่านผลผิดมาแล้ว)
        low = payload.lower()
        if "timed out" in low or "(28)" in low:
            print(f"slow\tไม่ตอบใน timeout ที่ตั้งไว้")
        else:
            print(f"broken\tHTTP {code} · อ่าน JSON ไม่ได้: {payload[:60]}")
        return

    if code == "200" and d.get("choices"):
        # gateway บอกตรง ๆ ว่าใครตอบผ่านฟิลด์ model — ต้องอ่าน ไม่ใช่เชื่อว่าได้ตัวที่ขอ
        answered = d.get("model") or ""
        want = (os.environ.get("MODEL") or "").split("/")[-1]
        if answered and want and want not in answered:
            print(f"wrong\tตอบโดย {answered} ไม่ใช่ตัวที่ขอ")
        else:
            print("ok\t")
        return

    msg = str((d.get("error") or {}).get("message") or d.get("detail") or d)
    low = msg.lower()
    if code == "404" or "testing period" in low or "no longer" in low:
        kind = "dead"
    elif code == "429" or "limit" in low or "quota" in low or "ratelimit" in low:
        kind = "quota"
    else:
        kind = "broken"
    print(f"{kind}\tHTTP {code} · {msg[:64]}")


if __name__ == "__main__":
    main()
