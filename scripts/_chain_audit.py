#!/usr/bin/env python3
"""ตรวจว่า fallback chain ข้าม quota_pool จริงไหม + ชื่อในchain มีอยู่จริงไหม

    python3 scripts/_chain_audit.py <model_info.json> <roles.tsv>

roles.tsv = ผลจาก check-chain.sh (คอลัมน์ model<TAB>role)

ทำไมต้องมี:
  README เขียนไว้ว่า "ทุกชั้นข้าม quota_pool" แต่ไม่มีอะไรตรวจ — ถ้าวันหนึ่งมีคน
  ใส่ mi/* สองตัวติดกัน มันจะหมดโควตาพร้อมกันแล้วเท่ากับไม่มีตัวสำรอง
  โดยไม่มีอาการอะไรจนกว่าจะถึงวันนั้น

  และทีม llm-gateway ทดสอบแล้วพบว่า **ชื่อผิดใน chain ไม่มีใครบอก** — LiteLLM
  เงียบแล้วคืน error ของตัวหลักมาเฉย ๆ พิมพ์ชื่อผิดจึงมีอาการเหมือนไม่ได้ตั้ง
  fallback เลยทุกประการ จึงต้องตรวจกับ /model/info ตอนบันทึก ไม่ใช่รอ runtime

  2026-09-03 เพิ่มการอ่าน "สัญญาณเตือน" จากแค็ตตาล็อกด้วย — เราดึง /model/info
  มาทั้งก้อนอยู่แล้ว (554 KB · ฟรี ไม่ใช่ LLM call) แต่เดิมอ่านแค่ quota_pool กับ
  answered_by ทั้งที่ในนั้นมี status · tags · stability · free_until · language_th_*

  ต่างกันตรงที่ "ปัญหา" คือพังแล้ว ส่วน "เตือน" คือกำลังจะพัง — gateway รู้ก่อนเรา
  เสมอเพราะเขา health-check ทุกวัน วันนี้เขาตั้ง oc/minimax-m3 เป็น deprecated
  ตอน 03:58 แต่เราเพิ่งรู้ตอนยิงเอง
"""
import json
import sys
from datetime import datetime, timezone


def main() -> int:
    info = json.load(open(sys.argv[1]))["data"]
    meta = {r["model_name"]: (r.get("model_info") or {}) for r in info}

    chain = []  # [(model, role)] เฉพาะ main + fallback ตามลำดับ
    unknown = []
    aliased = []
    for line in open(sys.argv[2]):
        if not line.strip():
            continue
        model, _, role = line.rstrip("\n").partition("\t")
        if model not in meta:
            unknown.append((model, role))
            continue
        if meta[model].get("answered_by"):
            aliased.append((model, role, meta[model]["answered_by"]))
        if role == "main" or role.startswith("fallback"):
            chain.append((model, role))

    problems, warnings = [], []

    # --- สัญญาณเตือนจากแค็ตตาล็อก — ฟรี เพราะดึงมาแล้ว ---------------------
    now = datetime.now(timezone.utc)

    def parse(s):
        try:
            return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        except Exception:
            return None

    for line in open(sys.argv[2]):
        if not line.strip():
            continue
        model, _, role = line.rstrip("\n").partition("\t")
        m = meta.get(model)
        if not m:
            continue

        st = m.get("status")
        # rate_limited ไม่ใช่คำเตือน — ตัวสำรองที่ดีคือตัวที่ว่างตอนตัวหลักตาย
        if st == "dead":
            warnings.append(f"{model} ({role}): gateway บันทึกว่า dead แล้ว")
        elif st == "unknown":
            warnings.append(f"{model} ({role}): status=unknown — gateway เองก็จำแนกไม่ออก ยิงเองก่อนเชื่อ")

        tags = m.get("tags") or []
        if "deprecated" in tags:
            warnings.append(f"{model} ({role}): tags มี deprecated — ควรย้ายออกก่อนมันหาย")

        stab = m.get("stability")
        if stab not in (None, "stable"):
            warnings.append(f"{model} ({role}): stability={stab} — มีวันหมดอายุในตัว อย่าวางเป็นตัวสำรองถาวร")

        fu = parse(m.get("free_until"))
        if fu:
            days = (fu - now).days
            if days < 0:
                warnings.append(f"{model} ({role}): free_until ผ่านมาแล้ว {-days} วัน — อาจไม่ฟรีแล้ว")
            elif days <= 30:
                warnings.append(f"{model} ({role}): free_until อีก {days} วัน ({m['free_until']})")

        for k, v in m.items():
            if k.startswith("language_") and isinstance(v, str) and v.startswith("drift"):
                warnings.append(f"{model} ({role}): {k}={v} — หลุดภาษาที่ขนาดบริบทนี้")

        checked = parse(m.get("status_checked_at"))
        if checked and (now - checked).days >= 3:
            warnings.append(f"{model} ({role}): status ตรวจล่าสุด {(now - checked).days} วันก่อน — ข้อมูลค้าง")

    # 1. ชื่อที่ไม่มีใน gateway — อาการเหมือนไม่ได้ตั้ง fallback เลย
    for model, role in unknown:
        problems.append(f"{role}: {model} ไม่มีใน /model/info — LiteLLM จะเงียบ ไม่มี error บอก")

    # 2. ชื่อที่เป็น alias ไป provider อื่นแล้ว — เจ้าของ chain ควรรู้ว่าได้โมเดลอื่น
    for model, role, ans in aliased:
        problems.append(f"{role}: {model} เป็น alias ไป {ans} — จะได้โมเดลอื่น ไม่ใช่ตัวที่เลือก")

    # 3. ชั้นติดกันอยู่ quota_pool เดียวกัน = หมดพร้อมกัน = ไม่มีตัวสำรองจริง
    print("ลำดับ chain กับ quota_pool:")
    prev_pool = prev_name = None
    for model, role in chain:
        pool = meta[model].get("quota_pool") or "?"
        flag = ""
        if prev_pool is not None and pool == prev_pool:
            flag = "  <-- ก้อนเดียวกับชั้นก่อนหน้า"
            problems.append(
                f"{role}: {model} อยู่ pool {pool} เดียวกับ {prev_name} — หมดโควตาพร้อมกัน"
            )
        print(f"  {role:<13} {model:<22} {pool}{flag}")
        prev_pool, prev_name = pool, model

    pools = {meta[m].get("quota_pool") or "?" for m, _ in chain}
    print(f"\nchain ยาว {len(chain)} ชั้น กระจายอยู่ {len(pools)} pool")

    if warnings:
        # เตือน = กำลังจะพัง ยังไม่ถือว่า chain ใช้ไม่ได้ จึงไม่ทำให้ exit 1
        print("\nสัญญาณเตือนจากแค็ตตาล็อก (ยังใช้ได้ แต่ควรจัดการก่อนมันพัง):")
        for w in dict.fromkeys(warnings):
            print("  ! " + w)

    if problems:
        print("\nปัญหาที่เจอ:")
        for p in problems:
            print("  x " + p)
        return 1
    if not warnings:
        print("ไม่มีชั้นไหนซ้ำ pool กัน · ทุกชื่อมีอยู่จริง · ไม่มีสัญญาณเตือนในแค็ตตาล็อก")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
