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
"""
import json
import sys


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

    problems = []

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

    if problems:
        print("\nปัญหาที่เจอ:")
        for p in problems:
            print("  x " + p)
        return 1
    print("ไม่มีชั้นไหนซ้ำ pool กัน และทุกชื่อมีอยู่จริงใน gateway")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
