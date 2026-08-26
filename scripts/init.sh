#!/usr/bin/env bash
# ============================================================================
# init.sh — เตรียม data/ ให้พร้อมก่อน docker compose up ครั้งแรก
#
#   ./scripts/init.sh           # สร้างของที่ยังไม่มี ไม่แตะของเดิม
#   ./scripts/init.sh --force   # เขียน data/config.yaml ทับจาก template
#
# ทำ 5 อย่าง:
#   1. ตรวจ .env (LITELLM_KEY บังคับ / LINE creds เตือนถ้าขาด)
#   2. สร้าง data/ + โครงย่อย แล้ว chown ให้ตรง PUID/PGID
#   3. gen data/config.yaml จาก config/config.yaml.tmpl
#   4. ตรวจว่า network llm-clients + LiteLLM ต่อติดจริง
#   5. ให้ hermes ตรวจ config ตัวเอง
#
# รันซ้ำได้ปลอดภัย — ของเดิมไม่ถูกแตะ ยกเว้นสั่ง --force
# ============================================================================
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

# ---------------------------------------------------------------- 1. env ---
echo
echo "${BOLD}${BLUE}▸ 1. ตรวจ .env${RESET}"

if [ ! -f .env ]; then
  echo "${RED}  ✗ ไม่มี .env${RESET}"
  echo "    cp .env.example .env  แล้วเติม LITELLM_KEY + LINE creds"
  exit 1
fi
set -a; . ./.env; set +a

if [ -z "${LITELLM_KEY:-}" ]; then
  echo "${RED}  ✗ LITELLM_KEY ว่าง${RESET}"
  echo "    ออก virtual key แยกใบจากฝั่ง LiteLLM แล้วใส่ใน .env (อย่าใช้ master key)"
  exit 1
fi

: "${LITELLM_BASE_URL:=http://llm-litellm:4000/v1}"
: "${HERMES_MODEL:=oc/gpt-oss-120b}"
: "${HERMES_MAX_TURNS:=60}"
: "${LINE_PORT:=8646}"
: "${TZ:=Asia/Bangkok}"
: "${PUID:=$(id -u)}"
: "${PGID:=$(id -g)}"

perm=$(stat -c '%a' .env)
if [ "$perm" != "600" ]; then
  chmod 600 .env
  echo "${YELLOW}  ! .env เปิดกว้างไป ($perm) → แก้เป็น 600 ให้แล้ว${RESET}"
fi
echo "${GREEN}  ok${RESET} ${DIM}(key ${LITELLM_KEY:0:8}… / model $HERMES_MODEL / uid $PUID:$PGID)${RESET}"

# LINE creds ยังไม่มีก็ทำงานต่อได้ — gateway จะขึ้นแต่ adapter LINE ไม่ start
LINE_READY=true
if [ -z "${LINE_CHANNEL_ACCESS_TOKEN:-}" ] || [ -z "${LINE_CHANNEL_SECRET:-}" ]; then
  LINE_READY=false
  echo "${YELLOW}  ! LINE_CHANNEL_ACCESS_TOKEN / LINE_CHANNEL_SECRET ยังว่าง${RESET}"
  echo "${DIM}    gateway จะขึ้นได้ แต่ LINE adapter จะไม่ start จนกว่าจะเติม${RESET}"
fi
if [ "${LINE_ALLOW_ALL_USERS:-false}" = "true" ]; then
  echo "${YELLOW}  ! LINE_ALLOW_ALL_USERS=true — ใครก็คุยกับบอทได้ ใช้เก็บ id เท่านั้น${RESET}"
elif [ "$LINE_READY" = true ] \
  && [ -z "${LINE_ALLOWED_USERS:-}" ] && [ -z "${LINE_ALLOWED_GROUPS:-}" ] && [ -z "${LINE_ALLOWED_ROOMS:-}" ]; then
  echo "${YELLOW}  ! allowlist ว่างทั้ง 3 ชั้น — บอทจะปฏิเสธทุกข้อความ${RESET}"
  echo "${DIM}    เก็บ id รอบแรกด้วย LINE_ALLOW_ALL_USERS=true แล้วดู logs${RESET}"
fi

# ---------------------------------------------------------------- 2. dirs --
echo
echo "${BOLD}${BLUE}▸ 2. เตรียม data/${RESET}"

for d in data data/sessions data/memories data/skills data/logs data/home data/profiles; do
  if [ -d "$d" ]; then
    echo "${DIM}  มีอยู่แล้ว  $d${RESET}"
  else
    mkdir -p "$d"
    echo "${GREEN}  สร้าง      $d${RESET}"
  fi
done

cur="$(stat -c '%u:%g' data)"
if [ "$cur" != "$PUID:$PGID" ]; then
  if chown -R "$PUID:$PGID" data 2>/dev/null; then
    echo "${GREEN}  chown${RESET} ${DIM}data/ → $PUID:$PGID${RESET}"
  else
    echo "${YELLOW}  ! chown data/ ไม่สำเร็จ (ต้องใช้ sudo)${RESET}"
    echo "${DIM}    sudo chown -R $PUID:$PGID $ROOT/data${RESET}"
  fi
fi

# ---------------------------------------------------------------- 3. config -
echo
echo "${BOLD}${BLUE}▸ 3. gen data/config.yaml${RESET}"

TMPL="config/config.yaml.tmpl"
[ -f "$TMPL" ] || { echo "${RED}  ✗ ไม่มี $TMPL${RESET}"; exit 1; }

if [ -f data/config.yaml ] && ! $FORCE; then
  echo "${YELLOW}  ! data/config.yaml มีอยู่แล้ว — ข้าม${RESET}"
  echo "${DIM}    เขียนทับจาก template: ./scripts/init.sh --force${RESET}"
else
  if [ -f data/config.yaml ]; then
    bak="data/config.yaml.bak.$(date +%Y%m%d-%H%M%S)"
    cp data/config.yaml "$bak"
    echo "${DIM}  สำรองของเดิมไว้ที่ $bak${RESET}"
  fi
  # แทนเฉพาะตัวแปรที่ตั้งใจ — ไม่ใช้ envsubst เปล่า ๆ กัน ${...} อื่นโดนกินไปด้วย
  LITELLM_BASE_URL="$LITELLM_BASE_URL" HERMES_MODEL="$HERMES_MODEL" \
  HERMES_MAX_TURNS="$HERMES_MAX_TURNS" LINE_PORT="$LINE_PORT" TZ="$TZ" \
  python3 -c '
import os, re, sys
allowed = ("LITELLM_BASE_URL", "HERMES_MODEL", "HERMES_MAX_TURNS", "LINE_PORT", "TZ")
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(r"\$\{(\w+)\}", lambda m: os.environ[m.group(1)] if m.group(1) in allowed else m.group(0), src)
open(sys.argv[2], "w", encoding="utf-8").write(out)
' "$TMPL" data/config.yaml
  chown "$PUID:$PGID" data/config.yaml 2>/dev/null || true
  echo "${GREEN}  ok${RESET} ${DIM}(จาก $TMPL)${RESET}"
fi

# --- SOUL.md = persona ---
# แยกจาก config.yaml เพราะ Hermes อ่านคนละไฟล์ ตัวจริงคือ data/SOUL.md
# ที่ commit ลง repo คือ config/SOUL.md — ปรับ persona ที่นั่น
if [ -f config/SOUL.md ]; then
  if [ -f data/SOUL.md ] && ! $FORCE && ! cmp -s config/SOUL.md data/SOUL.md; then
    echo "${YELLOW}  ! data/SOUL.md ต่างจาก config/SOUL.md — ข้าม (ใช้ --force ทับ)${RESET}"
  else
    cp config/SOUL.md data/SOUL.md
    chown "$PUID:$PGID" data/SOUL.md 2>/dev/null || true
    echo "${GREEN}  ok${RESET} ${DIM}data/SOUL.md ← config/SOUL.md${RESET}"
  fi
fi

# กันพลาด: ตัวแปรที่ไม่ถูกแทนหลงเหลือ (ข้ามบรรทัด comment)
if grep -vE '^\s*#' data/config.yaml | grep -q '\${'; then
  echo "${RED}  ✗ ยังมี \${...} ที่ไม่ถูกแทนค้างอยู่:${RESET}"
  grep -nE '\$\{' data/config.yaml | grep -vE '^[0-9]+:\s*#' | sed 's/^/      /'
  exit 1
fi

# ------------------------------------------------------------- 4. litellm --
echo
echo "${BOLD}${BLUE}▸ 4. ตรวจทาง LiteLLM${RESET}"

if docker network inspect llm-clients >/dev/null 2>&1; then
  echo "${GREEN}  ok${RESET} ${DIM}network llm-clients มีอยู่${RESET}"
else
  echo "${RED}  ✗ ไม่มี docker network 'llm-clients'${RESET}"
  echo "    docker network create llm-clients && docker network connect llm-clients llm-litellm"
  exit 1
fi

# ยิงจากในเน็ตเวิร์กเดียวกับที่ hermes จะใช้ ไม่ใช่จาก host — จะได้เจอปัญหา DNS/route ตั้งแต่ตอนนี้
probe=$(docker run --rm --network llm-clients curlimages/curl:latest -sS -m 20 \
  -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $LITELLM_KEY" \
  "${LITELLM_BASE_URL%/}/models" 2>&1 || echo "conn-fail")
case "$probe" in
  200) echo "${GREEN}  ok${RESET} ${DIM}$LITELLM_BASE_URL/models → 200${RESET}" ;;
  401|403) echo "${RED}  ✗ LITELLM_KEY ใช้ไม่ได้ (HTTP $probe)${RESET}"; exit 1 ;;
  *) echo "${RED}  ✗ ต่อ $LITELLM_BASE_URL ไม่ได้ ($probe)${RESET}"
     echo "${DIM}    เช็คว่า container llm-litellm รันอยู่: docker ps | grep litellm${RESET}"
     exit 1 ;;
esac

# ---------------------------------------------------------------- 5. ตรวจ --
echo
echo "${BOLD}${BLUE}▸ 5. ให้ hermes ตรวจ config เอง${RESET}"

IMG="nousresearch/hermes-agent:${HERMES_VERSION:-v2026.8.3}"
if docker image inspect "$IMG" >/dev/null 2>&1; then
  log="$(mktemp)"
  docker run --rm -v "$ROOT/data:/opt/data" -e PUID="$PUID" -e PGID="$PGID" \
    "$IMG" config check > "$log" 2>&1 || true
  grep -E "Config version|Required|WARNING|ERROR|✗|Missing" "$log" | sed 's/^/  /' || true
  if grep -q "WARNING\|ERROR" "$log"; then
    echo "${YELLOW}  ! มีคำเตือน — ดูเต็ม: docker compose run --rm hermes config check${RESET}"
  else
    echo "${GREEN}  config ผ่าน ไม่มีคำเตือน${RESET}"
  fi
  rm -f "$log"
else
  echo "${DIM}  ยังไม่มี image — docker compose pull ก่อน${RESET}"
fi

# ---------------------------------------------------------------- สรุป -----
echo
echo "${BOLD}${GREEN}✓ พร้อมแล้ว${RESET}"
echo
echo "  ${BOLD}ขั้นต่อไป${RESET}"
echo "    docker compose up -d                    ${DIM}# รัน gateway + LINE adapter${RESET}"
echo "    docker compose logs -f hermes           ${DIM}# ดูว่า LINE adapter ขึ้นไหม${RESET}"
echo "    ./scripts/smoke-webhook.sh              ${DIM}# ยิง webhook ปลอมที่เซ็นถูก${RESET}"
# ตัด skills ต้องรันหลัง container ขึ้นแล้ว (สคริปต์ exec เข้าไปในนั้น) จึงไม่รวมใน init
if [ ! -f data/.no-bundled-skills ]; then
  echo
  echo "  ${YELLOW}ยังไม่ได้ตัด skills — bundled 71 ตัวกิน 6.7 KB ใน system prompt ทุก call${RESET}"
  echo "    ./scripts/trim-skills.sh                ${DIM}# ตัดเหลือตาม config/skills-keep.txt${RESET}"
fi
if [ "$LINE_READY" = false ]; then
  echo
  echo "  ${YELLOW}ยังขาด LINE creds — เติมใน .env ก่อนถึงจะคุยผ่าน LINE ได้${RESET}"
fi
echo
