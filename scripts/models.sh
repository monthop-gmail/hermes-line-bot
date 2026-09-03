#!/usr/bin/env bash
# ============================================================================
# models.sh — ดูรายชื่อโมเดลใน gateway เพื่อคัดกรองก่อนลองเล่น
#
# ⚠️ ไฟล์นี้ไม่มีตรรกะของตัวเอง — มันแค่ "เรียก" pick-model.sh ของทีม llm-gateway
#    ให้ถูกวิธี เจตนาคือ **ไม่ลอกสคริปต์เขามาไว้ที่เรา** เพราะจะกลายเป็นสำเนา
#    ที่สองที่ต้องดูแล (บทเรียนเดียวกับ quick_commands ที่ถอดไปเมื่อ 2026-09-03)
#
#    เขาแก้ pick-model.sh 4 ครั้งในสัปดาห์เดียว — clone ใหม่ทุกครั้งจึงได้ของล่าสุดเสมอ
#
# สิ่งที่ต้องจำแล้วลืมบ่อย และไฟล์นี้จำแทน:
#   1. LITELLM_URL ต้องไม่มี /v1 ต่อท้าย (ต่างจาก LITELLM_BASE_URL ใน .env ของเรา)
#   2. สคริปต์เขาอ่านตัวแปรชื่อ LITELLM_MASTER_KEY แต่ virtual key ของเราใช้ได้
#      — /model/info เป็น management endpoint ที่ virtual key เรียกได้ ไม่ต้องใช้ master key
#   3. llm-litellm publish port 4000 ออก host จึงยิงจาก host ได้ตรง ๆ
#
#   ./scripts/models.sh                # ดูหมวดทั้งหมด
#   ./scripts/models.sh agent 60000    # ใช้กับ agent ที่ turn ~60K (ของเรา ~59K)
#   ./scripts/models.sh thai           # โมเดลภาษาไทย
#   ./scripts/models.sh typhoon        # ค้นอิสระจากชื่อ/คำอธิบาย
#
# ฟรี — /model/info ไม่ใช่ LLM call เรียกกี่ครั้งก็ไม่เสียโควตา
#
# 💡 เห็นชื่อที่อยากลองแล้วพิมพ์ /model <ชื่อ> ในแชทได้เลย ไม่ต้องแก้ config
#    Hermes ยอมชื่อที่ไม่อยู่ใน custom_providers.models (เรียกว่า unknown hidden
#    model) — ลิสต์นั้นมีไว้บอกว่า "ตัวไหนผ่านเกณฑ์แล้ว" ไม่ได้กันการใช้
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO=https://github.com/monthop-gmail/llm-gateway.git

[ -f .env ] || { echo "✗ ไม่มี .env — รัน ./scripts/init.sh ก่อน" >&2; exit 2; }
set -a; . ./.env; set +a
: "${LITELLM_KEY:?ต้องมี LITELLM_KEY ใน .env}"

# ตัด /v1 ออก — สคริปต์เขาต่อ /model/info เอง เติมซ้ำได้ 404
URL="${LITELLM_URL:-${LITELLM_BASE_URL%/v1}}"
URL="${URL%/}"

# ยิงจาก host ผ่าน port ที่ publish ไว้ — ถ้าใน .env เป็นชื่อ container จะแก้ให้
case "$URL" in
  *llm-litellm*) URL="http://localhost:4000" ;;
esac

command -v git >/dev/null || { echo "✗ ต้องมี git" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --depth 1 "$REPO" "$tmp/gw" 2>/dev/null || {
  echo "✗ clone $REPO ไม่ได้ — เน็ตมีปัญหาหรือ repo ย้าย" >&2; exit 2; }

cd "$tmp/gw" || exit 2
LITELLM_URL="$URL" LITELLM_MASTER_KEY="$LITELLM_KEY" ./scripts/pick-model.sh "$@"
