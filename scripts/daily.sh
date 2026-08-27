#!/usr/bin/env bash
# ============================================================================
# daily.sh — งานประจำวัน รันคำสั่งเดียวจบ
#
# ทำไมต้องมี:
#   พารามิเตอร์ที่ต้องจำมันเยอะ — ชื่อ container ไม่ตรงกับที่สคริปต์เดา,
#   repo อยู่คนละที่, โมเดลที่รอโควตาคืนมีตัวไหนบ้าง, สำเนา config อยู่ 3 ที่
#   พอ context เต็มแล้วลืม ก็ไปเดาใหม่แล้วเดาผิด
#
#   ทุกอย่างที่ต้องเช็คทุกวันอยู่ในไฟล์นี้ ไม่ต้องจำ
#
#   ./scripts/daily.sh              # เช็คทุกอย่าง
#   ./scripts/daily.sh --no-github  # ข้ามส่วนที่ยิง GitHub API (ตอนโดน rate limit)
#   ./scripts/daily.sh --quota      # เช็คเฉพาะของที่รอโควตาคืน
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# --- ค่าที่ต้องจำ เก็บไว้ที่เดียว -------------------------------------------
BOT_CONTAINER="${HERMES_CONTAINER:-nst-hermes-line-bot}"
BOT_DIR=/opt/docker-test/server-botforge-v2/projects/nst-hermes/bot-service
TEMPLATE_DIR=/opt/docker-test/server-botforge-v2/templates/bot-service-hermes
REPOS=(monthop-gmail/hermes-line-bot monthop-gmail/llm-gateway monthop-gmail/botforge)

# โมเดลที่ "ค้างเพราะโควตา" — ต้องวัดซ้ำเมื่อคืน แล้วส่งผลกลับเป็น PR
# เพิ่ม/ลบตรงนี้เมื่อสถานการณ์เปลี่ยน จะได้ไม่ต้องจำเอง
#
# ⚠️ ว่างอยู่โดยตั้งใจ (2026-08-27) — การวัดภาษาเป็นของ gateway แล้วตั้งแต่
#    llm-gateway#13 merge เราไม่ต้องยิงเองอีก แค่อ่าน language_th_* จาก /model/info
#    ใส่ตรงนี้เฉพาะของที่ "ต้องวัดในบริบทของเราเท่านั้น" ซึ่งตอนนี้ไม่มี
#
#    เดิมมี cf/llama-4-scout กับ oc/gpt-oss-120b อยู่ — ถอนออกเพราะเป็นงานของ gateway
#    (ผลเก่าของ cf ถอนไปแล้วที่ llm-gateway#16 เพราะวัดด้วยโจทย์ที่จับ drift ไม่ได้)
WAITING=()

# repo ที่ "จอดไว้ตั้งใจ" — ไม่ใช่ของค้าง อย่าไปเร่ง อย่าไปไล่ทำ
# เขียนเหตุผลกับวันที่ไว้ด้วย จะได้รู้ว่าเมื่อไหร่ควรกลับมาทบทวน
PARKED=(
  "botforge|จอดไว้จนกว่าจะเดินเข้า agent platform จริง (ตัดสิน 2026-08-27) — PR #29 เปิดค้างได้ ไม่ต้อง review"
)

DO_GITHUB=1; ONLY_QUOTA=0
for a in "$@"; do
  case "$a" in
    --no-github) DO_GITHUB=0 ;;
    --quota)     ONLY_QUOTA=1 ;;
    *) echo "unknown arg: $a" >&2; exit 1 ;;
  esac
done

hr() { printf "${DIM}%.0s─${RESET}" {1..76}; echo; }
head2() { echo; echo "${BOLD}$1${RESET}"; hr; }

# --- 1. บอทยังวิ่งไหม --------------------------------------------------------
if [ "$ONLY_QUOTA" = 0 ]; then
  head2 "1. บอท"
  if s=$(docker ps --filter "name=$BOT_CONTAINER" --format '{{.Status}}' 2>/dev/null) && [ -n "$s" ]; then
    echo "  ${GREEN}✓${RESET} $BOT_CONTAINER — $s"
  else
    echo "  ${RED}✗${RESET} $BOT_CONTAINER ไม่ได้รัน"
    echo "  ${DIM}cd $BOT_DIR && docker compose up -d${RESET}"
  fi

  # --- 2. chain ---------------------------------------------------------------
  head2 "2. fallback chain (ยิงจริงทุกตัว)"
  # ⚠️ อย่าลดเวลารอลงเพื่อให้จบเร็ว — ลองมาแล้วสองรอบ ทั้งสองรอบให้ผลผิด
  #    45s → nim/minimax-m3 กับ mi/large ขึ้น "ช้าเกิน" รายงาน 2/4 ทั้งที่จริง 3/4
  #    90s → ยังไม่พอ ทั้งคู่ยังตกเหมือนเดิม
  #    ทั้งสองตัวช้าโดยธรรมชาติ (แค็ตตาล็อกเขียนไว้แล้วว่า mi/large 90-180s
  #    และ NIM บาง endpoint ช้า/timeout) ค่า default 120 ของ check-chain.sh
  #    คือค่าที่เห็นว่าผ่านจริง จึงไม่ทับ — งานประจำวันรันวันละครั้ง ช้าหน่อยไม่เป็นไร
  #    แต่รายงานผิดเป็นเรื่องใหญ่ เพราะจะไปหาตัวแทนให้โมเดลที่ไม่ได้พัง
  ./scripts/check-chain.sh || echo "  ${RED}→ ต้องหาตัวแทน${RESET} ${DIM}ดู ./scripts/probe-thai.sh${RESET}"

  # --- 3. สำเนา config ---------------------------------------------------------
  # เคย drift มาแล้ว — template ตกรุ่นแล้วบอทใหม่ที่ scaffold ออกมาได้ของเก่า
  head2 "3. สำเนา config.yaml.tmpl"
  ours=$(md5sum < config/config.yaml.tmpl | cut -c1-8)
  echo "  $ours  ${DIM}repo นี้ (ต้นทาง)${RESET}"
  for f in "$BOT_DIR/config/config.yaml.tmpl" "$TEMPLATE_DIR/config/config.yaml.tmpl"; do
    if [ -f "$f" ]; then
      h=$(md5sum < "$f" | cut -c1-8)
      [ "$h" = "$ours" ] && m="${GREEN}✓${RESET}" || m="${YELLOW}ต่าง${RESET}"
      echo "  $h  $m ${DIM}${f#/opt/docker-test/}${RESET}"
    else
      echo "  ${DIM}ไม่พบ ${f#/opt/docker-test/}${RESET}"
    fi
  done
  echo "  ${DIM}template ของ botforge จะต่างได้ถ้า PR ยังไม่ merge — เช็คว่าเป็นเพราะแบบนั้น${RESET}"
fi

# --- 4. ของที่รอโควตาคืน -----------------------------------------------------
head2 "4. ของที่รอโควตาคืน"
if [ ${#WAITING[@]} -eq 0 ]; then
  echo "  ${DIM}ไม่มี — การวัดภาษาเป็นของ gateway แล้ว อ่าน language_th_* จาก /model/info${RESET}"
fi
set -a; [ -f .env ] && . ./.env; set +a
if [ -z "${LITELLM_KEY:-}" ]; then
  echo "  ${DIM}ข้าม — ไม่มี LITELLM_KEY ใน .env${RESET}"
else
  URL="${LITELLM_BASE_URL%/}/chat/completions"
  for row in ${WAITING[@]+"${WAITING[@]}"}; do
    m="${row%%|*}"; why="${row#*|}"
    body=$(docker run --rm --network llm-clients curlimages/curl:latest \
      -sS --max-time 60 -w '\n__H__%{http_code}' -X POST "$URL" \
      -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":200,\"disable_fallbacks\":true}" 2>&1)
    v=$(MODEL="$m" python3 scripts/_verdict.py <<<"$body")
    case "${v%%$'\t'*}" in
      ok) echo "  ${GREEN}✓ $m โควตาคืนแล้ว — วัดได้${RESET}"
          echo "    ${DIM}$why${RESET}"
          echo "    ${DIM}HERMES_CONTAINER=$BOT_CONTAINER ./scripts/probe-thai.sh -n 3 $m${RESET}" ;;
      *)  echo "  ${DIM}◐ $m ยังไม่คืน${RESET}" ;;
    esac
  done
fi

# --- 5. งานค้างบน GitHub -----------------------------------------------------
if [ "$DO_GITHUB" = 1 ] && [ "$ONLY_QUOTA" = 0 ]; then
  head2 "5. งานค้างบน GitHub"
  if ! command -v gh >/dev/null; then
    echo "  ${DIM}ไม่มี gh${RESET}"
  else
    for r in "${REPOS[@]}"; do
      short="${r##*/}"
      note=""
      for row in "${PARKED[@]}"; do
        [ "${row%%|*}" = "$short" ] && note="${row#*|}"
      done
      if [ -n "$note" ]; then
        echo "  ${BOLD}${short}${RESET}  ${DIM}[จอดไว้]${RESET}"
        echo "    ${DIM}${note}${RESET}"
        continue
      fi
      echo "  ${BOLD}${short}${RESET}"
      gh issue list --repo "$r" --state open --limit 10 \
        --json number,title,updatedAt \
        --template '{{range .}}    #{{.number}}  {{.title}}{{"\n"}}{{end}}' 2>/dev/null \
        || echo "    ${DIM}(ดึงไม่ได้ — อาจโดน rate limit)${RESET}"
      gh pr list --repo "$r" --state open --limit 10 \
        --json number,title \
        --template '{{range .}}    PR #{{.number}}  {{.title}}{{"\n"}}{{end}}' 2>/dev/null
    done
    echo
    echo "  ${YELLOW}อ่านคอมเมนต์ใหม่ก่อนสรุปว่าค้างที่ใคร${RESET}"
    echo "  ${DIM}เคยพลาดมาแล้ว: ทีม gateway ตอบ #5 ว่า 'ส่ง PR มาได้เลย' แล้วเราไม่เห็น${RESET}"
    echo "  ${DIM}gh api repos/<owner>/<repo>/issues/<n>/comments --jq '.[-1].body'${RESET}"
  fi
fi

echo
hr
echo "${DIM}รายละเอียดกติกาทั้งหมดอยู่ใน CLAUDE.md${RESET}"
