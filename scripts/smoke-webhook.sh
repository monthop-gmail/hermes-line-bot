#!/usr/bin/env bash
# ============================================================================
# smoke-webhook.sh — ยิง webhook ปลอมที่ "เซ็นถูก" เข้า LINE adapter
#
# ใช้พิสูจน์ทั้งเส้นทางโดยไม่ต้องมี LINE OA จริง: ลายเซ็น → allowlist →
# session → โมเดล  ตัวที่เหลือให้ LINE ทำจริงคือ "การส่งกลับ" เท่านั้น
# (reply token ปลอมจะได้ 400 จาก api.line.me เป็นเรื่องปกติ)
#
#   ./scripts/smoke-webhook.sh                       # เป็นแชทส่วนตัว
#   ./scripts/smoke-webhook.sh --group               # เป็นข้อความในกลุ่ม
#   ./scripts/smoke-webhook.sh --room                # เป็นข้อความในห้อง
#   ./scripts/smoke-webhook.sh -m "สวัสดี ทำอะไรได้บ้าง"
#   ./scripts/smoke-webhook.sh --bad-sig             # ต้องได้ 401
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

[ -f .env ] || { echo "ไม่มี .env" >&2; exit 1; }
set -a; . ./.env; set +a

: "${LINE_PORT:=8646}"
: "${BIND_ADDR:=127.0.0.1}"
: "${LINE_WEBHOOK_PATH:=/line/webhook}"
URL="http://${BIND_ADDR}:${LINE_PORT}${LINE_WEBHOOK_PATH:-/line/webhook}"

SRC=user; TEXT="สวัสดี ช่วยบอกหน่อยว่าตอนนี้เป็นเวลาอะไร"; BAD_SIG=false; FORCE_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --group) SRC=group; shift ;;
    --room)  SRC=room;  shift ;;
    --bad-sig) BAD_SIG=true; shift ;;
    -m|--message) TEXT="$2"; shift 2 ;;
    --id) FORCE_ID="$2"; shift 2 ;;   # ยิงด้วย id ที่กำหนดเอง — ใช้ทดสอบว่า allowlist กันจริง
    -u|--url) URL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# id ที่ใช้ยิงต้องอยู่ใน allowlist ไม่งั้น adapter ตีตกเงียบ ๆ (ตอบ 200 แต่ไม่ทำอะไร)
pick() { echo "$1" | cut -d, -f1 | tr -d ' '; }
case "$SRC" in
  user)  ID="$(pick "${LINE_ALLOWED_USERS:-}")";  ID="${ID:-Usmoketest0000000000000000000000}"; SRC_JSON="{\"type\":\"user\",\"userId\":\"$ID\"}" ;;
  group) GID="$(pick "${LINE_ALLOWED_GROUPS:-}")"; GID="${GID:-Csmoketest0000000000000000000000}"
         UID_="$(pick "${LINE_ALLOWED_USERS:-}")"; UID_="${UID_:-Usmoketest0000000000000000000000}"
         ID="$GID"; SRC_JSON="{\"type\":\"group\",\"groupId\":\"$GID\",\"userId\":\"$UID_\"}" ;;
  room)  RID="$(pick "${LINE_ALLOWED_ROOMS:-}")"; RID="${RID:-Rsmoketest0000000000000000000000}"
         UID_="$(pick "${LINE_ALLOWED_USERS:-}")"; UID_="${UID_:-Usmoketest0000000000000000000000}"
         ID="$RID"; SRC_JSON="{\"type\":\"room\",\"roomId\":\"$RID\",\"userId\":\"$UID_\"}" ;;
esac

# --id ทับค่าที่หยิบจาก allowlist — ต้องทำหลัง case เพราะ .env ถูก source ไปแล้ว
if [ -n "$FORCE_ID" ]; then
  ID="$FORCE_ID"
  case "$SRC" in
    user)  SRC_JSON="{\"type\":\"user\",\"userId\":\"$ID\"}" ;;
    group) SRC_JSON="{\"type\":\"group\",\"groupId\":\"$ID\",\"userId\":\"$ID\"}" ;;
    room)  SRC_JSON="{\"type\":\"room\",\"roomId\":\"$ID\",\"userId\":\"$ID\"}" ;;
  esac
fi

if [ "${LINE_ALLOW_ALL_USERS:-false}" != "true" ]; then
  case "$SRC" in
    user)  [ -n "${LINE_ALLOWED_USERS:-}" ]  || echo "${YELLOW}! LINE_ALLOWED_USERS ว่าง — adapter จะตีตก${RESET}" ;;
    group) [ -n "${LINE_ALLOWED_GROUPS:-}" ] || echo "${YELLOW}! LINE_ALLOWED_GROUPS ว่าง — adapter จะตีตก${RESET}" ;;
    room)  [ -n "${LINE_ALLOWED_ROOMS:-}" ]  || echo "${YELLOW}! LINE_ALLOWED_ROOMS ว่าง — adapter จะตีตก${RESET}" ;;
  esac
fi

# webhookEventId ต้องไม่ซ้ำ ไม่งั้นโดน dedup ทิ้ง
EVT="smoke$(date +%s%N | tail -c 12)"
BODY=$(SRC_JSON="$SRC_JSON" TEXT="$TEXT" EVT="$EVT" python3 - <<'PY'
import json, os, time
print(json.dumps({
    "destination": "Ufakedestination0000000000000000",
    "events": [{
        "type": "message",
        "mode": "active",
        "webhookEventId": os.environ["EVT"],
        "deliveryContext": {"isRedelivery": False},
        "timestamp": int(time.time() * 1000),
        "source": json.loads(os.environ["SRC_JSON"]),
        "replyToken": "smoke-reply-token-not-real",
        "message": {"type": "text", "id": os.environ["EVT"], "text": os.environ["TEXT"]},
    }],
}, ensure_ascii=False, separators=(",", ":")))
PY
)

# ลายเซ็น = base64( HMAC-SHA256( channel_secret, raw_body ) )  — ต้องเซ็น "ไบต์ที่ส่งจริง"
if $BAD_SIG; then
  SIG="ZmFrZS1zaWduYXR1cmUtdmFsdWU="
else
  [ -n "${LINE_CHANNEL_SECRET:-}" ] || { echo "${RED}✗ LINE_CHANNEL_SECRET ว่าง — เซ็นไม่ได้${RESET}" >&2; exit 1; }
  SIG=$(SECRET="$LINE_CHANNEL_SECRET" BODY="$BODY" python3 -c '
import base64, hashlib, hmac, os
print(base64.b64encode(hmac.new(os.environ["SECRET"].encode(),
      os.environ["BODY"].encode(), hashlib.sha256).digest()).decode())')
fi

echo "${DIM}POST $URL  (source=$SRC id=$ID)${RESET}"
echo "${DIM}  ข้อความ: $TEXT${RESET}"
t0=$(date +%s%N)
code=$(curl -sS -o /tmp/hermes-line-smoke.out -w '%{http_code}' -m 30 \
  -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "X-Line-Signature: $SIG" \
  --data-raw "$BODY") || { echo "${RED}✗ ต่อไม่ได้ — container ขึ้นหรือยัง${RESET}"; exit 1; }
ms=$(( ($(date +%s%N) - t0) / 1000000 ))

echo
if $BAD_SIG; then
  # adapter คืน 401 "invalid signature" (adapter.py:952) — ไม่ใช่ 403
  # 403 สงวนไว้ให้ media endpoint ที่กัน path traversal (adapter.py:1418)
  if [ "$code" = "401" ]; then
    echo "${GREEN}✓ signature ผิด → 401 ถูกต้อง${RESET} ${DIM}(${ms}ms)${RESET}"
  else
    echo "${RED}✗ signature ผิดแต่ได้ $code — ควรเป็น 401${RESET}"; exit 1
  fi
elif [ "$code" = "200" ]; then
  echo "${GREEN}✓ 200 OK${RESET} ${DIM}(${ms}ms — adapter รับแล้ว ตอบทันทีไม่รอโมเดล)${RESET}"
  echo
  echo "  ${DIM}คำตอบจริงไปโผล่ใน log (reply token ปลอม ส่งกลับ LINE ไม่ได้):${RESET}"
  echo "  docker compose logs --tail 60 hermes"
else
  echo "${RED}✗ HTTP $code${RESET}"; cat /tmp/hermes-line-smoke.out; exit 1
fi
