#!/usr/bin/env bash
# ============================================================================
# probe-thai.sh — โมเดลไหน "อยู่กับภาษาไทย" ได้ตอนวิ่ง tool loop จริง
#
# ทำไมต้องมีสคริปต์นี้แยกจาก probe-litellm.sh:
#   probe-litellm.sh ทดสอบด้วยการยิง API ตรง ๆ 2 turn — โมเดลตอบไทยผ่านหมด
#   แต่พอรันใน Hermes จริง (system prompt อังกฤษ 16 KB + ผล tool เป็นอังกฤษ
#   ล้วน ๆ ในบริบท) โมเดลบางตัว "ไหล" ไปตอบอังกฤษหรือจีนแทน
#   ต้องวัดในสภาพจริงเท่านั้นถึงจะเห็น
#
#   ./scripts/probe-thai.sh                      # ชุด default 3 รอบต่อโมเดล
#   ./scripts/probe-thai.sh -n 5 mi/large        # ระบุจำนวนรอบ + โมเดล
#   ./scripts/probe-thai.sh -t 600 mi/magistral-medium   # ยืด timeout ให้ตัวที่ช้า
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# ชื่อ container — ตั้ง HERMES_CONTAINER ทับได้
# บอทที่ deploy ด้วย botforge ใช้ชื่อ <prefix>-line-bot ไม่ใช่ <prefix>-agent
#   HERMES_CONTAINER=nst-hermes-line-bot ./scripts/probe-thai.sh mi/ministral-14b
_container_override="${HERMES_CONTAINER:-}"
CONTAINER="hermes-line-agent"
[ -f .env ] && { set -a; . ./.env; set +a; CONTAINER="${CONTAINER_PREFIX:-hermes-line}-agent"; }
[ -n "$_container_override" ] && CONTAINER="$_container_override"

ROUNDS=3
# ตั้งสูงไว้ก่อน — reasoning model บางตัวใช้ 200s+ ต่อ turn ตัดสายเร็วไปจะอ่านผลผิด
TIMEOUT="${PROBE_TIMEOUT:-400}"
LANG_PY="$(dirname "$0")/_lang.py"
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -n) ROUNDS="$2"; shift 2 ;;
    -t) TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
MODELS=("$@")
[ "${#MODELS[@]}" -gt 0 ] || MODELS=(oc/gpt-oss-120b mi/large or/ox-alpha cb/gpt-oss-120b oc/nemotron-3-ultra)

docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
  echo "${RED}✗ container $CONTAINER ไม่ได้รัน${RESET}" >&2; exit 1; }

# โจทย์ต้องบังคับให้ "ใช้ tool" — ผล tool เป็นอังกฤษล้วนคือตัวที่ทำให้โมเดลไหล
PROMPT="สรุปให้หน่อยว่าในโฟลเดอร์ /opt/data/logs มีไฟล์อะไรบ้าง และแต่ละอันน่าจะเก็บอะไร"

echo "${DIM}โจทย์: $PROMPT${RESET}"
echo "${DIM}รอบละโมเดล: $ROUNDS${RESET}"
echo
printf '%-22s %-6s %s\n' MODEL ไทย ผล
printf '%.0s-' {1..72}; echo

for m in "${MODELS[@]}"; do
  marks=""; thai_n=0; slow_n=0; err_n=0; wrong_n=0; wrong_detail=""
  for _ in $(seq 1 "$ROUNDS"); do
    # ⚠️ แยก "เราตัดสายเอง" ออกจาก "โมเดลพัง" — timeout คืน exit code 124
    #    เคยรายงาน mi/magistral-medium เป็น "พัง 0/3" ทั้งที่มันตอบไทยได้ปกติ
    #    แค่ใช้ 146-227s ต่อ turn ซึ่งชน timeout เดิมที่ตั้งไว้ 240s
    #    ถ้าไม่แยกจะอ่านผลผิดว่าโมเดลใช้ไม่ได้
    # 🔴 Hermes มี fallback_providers ของตัวเอง — ถ้าโมเดลที่ขอตาย มันไล่ไปตัวถัดไป
    #    "เงียบ ๆ" แล้วเราจะวัดภาษาของตัวสำรองใส่ชื่อตัวที่ขอ
    #    (บทเรียนจาก llm-gateway: latency_ms_14k รอบแรกผิด 11 ตัวเพราะเรื่องนี้)
    #
    #    ยิงผ่าน CLI จึงใส่ disable_fallbacks ใน request เองไม่ได้ และ CLI ก็ไม่เขียน
    #    "API call #" ลง agent.log ของ gateway ด้วย — ใช้ --usage-file แทน
    #    ซึ่งบันทึก "model" ที่ตอบจริงไว้ ตรวจได้แน่นอน
    UF=/tmp/probe-thai-usage.json
    docker exec "$CONTAINER" rm -f "$UF" 2>/dev/null
    out=$(timeout "$TIMEOUT" docker exec "$CONTAINER" /opt/hermes/.venv/bin/hermes \
      -z "$PROMPT" -m "$m" --provider custom:litellm --usage-file "$UF" --yolo 2>&1)
    rc=$?
    if [ "$rc" = 124 ]; then
      marks="$marks${YELLOW}ช้า>${TIMEOUT}s${RESET} "; slow_n=$((slow_n+1)); continue
    fi
    answered=$(docker exec "$CONTAINER" sh -c "cat $UF 2>/dev/null" \
      | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("model",""))
except Exception: print("")' 2>/dev/null)
    if [ -n "$answered" ] && [ "$answered" != "$m" ]; then
      marks="$marks${RED}วัดผิด${RESET} "; wrong_n=$((wrong_n+1)); wrong_detail="$answered"
      continue
    fi
    lang=$(OUT="$out" python3 "$LANG_PY")
    case "$lang" in
      th) marks="$marks${GREEN}ไทย${RESET} "; thai_n=$((thai_n+1)) ;;
      zh) marks="$marks${RED}จีน${RESET} " ;;
      en) marks="$marks${YELLOW}อังกฤษ${RESET} " ;;
      *)  marks="$marks${RED}พัง${RESET} "; err_n=$((err_n+1)) ;;
    esac
  done
  score="$thai_n/$ROUNDS"
  note=""
  [ "$slow_n" -gt 0 ] && note="ช้าเกิน ${TIMEOUT}s $slow_n ครั้ง "
  [ "$err_n" -gt 0 ] && note="${note}error $err_n ครั้ง "
  [ "$wrong_n" -gt 0 ] && note="${note}🔴 fallback ไปตอบแทน $wrong_n ครั้ง ($wrong_detail)"
  printf '%-22s %-6s %b%s\n' "$m" "$score" "$marks" "${DIM}${note}${RESET}"
done
echo
echo "${DIM}เกณฑ์: ตัวที่จะใช้เป็น main ต้องได้เต็ม — บอทไทยที่ตอบอังกฤษบ้างใช้งานจริงไม่ได้${RESET}"
