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
#   ./scripts/probe-thai.sh -n 5 mi/large        # ระบุเอง
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

CONTAINER="hermes-line-agent"
[ -f .env ] && { set -a; . ./.env; set +a; CONTAINER="${CONTAINER_PREFIX:-hermes-line}-agent"; }

ROUNDS=3
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -n) ROUNDS="$2"; shift 2 ;;
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
  marks=""; thai_n=0
  for _ in $(seq 1 "$ROUNDS"); do
    out=$(timeout 240 docker exec "$CONTAINER" /opt/hermes/.venv/bin/hermes \
      -z "$PROMPT" -m "$m" --provider custom:litellm --yolo 2>&1)
    lang=$(OUT="$out" python3 scripts/_lang.py)
    case "$lang" in
      th) marks="$marks${GREEN}ไทย${RESET} "; thai_n=$((thai_n+1)) ;;
      zh) marks="$marks${RED}จีน${RESET} " ;;
      en) marks="$marks${YELLOW}อังกฤษ${RESET} " ;;
      *)  marks="$marks${RED}พัง${RESET} " ;;
    esac
  done
  score="$thai_n/$ROUNDS"
  printf '%-22s %-6s %b\n' "$m" "$score" "$marks"
done
echo
echo "${DIM}เกณฑ์: ตัวที่จะใช้เป็น main ต้องได้เต็ม — บอทไทยที่ตอบอังกฤษบ้างใช้งานจริงไม่ได้${RESET}"
