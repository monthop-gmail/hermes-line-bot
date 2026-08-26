#!/usr/bin/env bash
# ============================================================================
# trim-skills.sh — ตัด bundled skills เหลือเท่าที่อยู่ใน config/skills-keep.txt
#
#   ./scripts/trim-skills.sh                    # ตัดตาม keep-list
#   ./scripts/trim-skills.sh --list-available   # ดูรายชื่อทั้งหมดที่เลือกได้
#   ./scripts/trim-skills.sh --restore          # เอา 71 ตัวกลับมาทั้งหมด
#
# ทำไมต้องมีสคริปต์ ไม่ลบมือ:
#   container sync bundled skills กลับเข้า /opt/data/skills ทุกครั้งที่ boot
#   ("Done: 0 new, 0 updated, 71 unchanged") ลบมือแล้วมันกลับมาเอง
#   ตัวที่หยุด sync คือ marker /opt/data/.no-bundled-skills — สคริปต์นี้เขียนให้
#   (tools/skills_sync.py:688 เช็ค marker ก่อนทำอะไรทั้งสิ้น)
#
# skills ที่ copy กลับมาหลังตั้ง marker จะถูกมองเป็น local skill ไม่ใช่ bundled
# จึงอยู่รอดข้าม restart และข้าม `hermes update`
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

KEEP_FILE="config/skills-keep.txt"
CONTAINER="${CONTAINER_PREFIX:-hermes-line}-agent"
[ -f .env ] && { set -a; . ./.env; set +a; CONTAINER="${CONTAINER_PREFIX:-hermes-line}-agent"; }
: "${PUID:=$(id -u)}"; : "${PGID:=$(id -g)}"

running() { docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; }

if [ "${1:-}" = "--list-available" ]; then
  running || { echo "${RED}✗ container $CONTAINER ไม่ได้รัน${RESET}" >&2; exit 1; }
  docker exec "$CONTAINER" sh -c 'cd /opt/hermes/skills && for c in */; do
      [ "$c" = "index-cache/" ] && continue
      for s in "$c"*/; do [ -d "$s" ] && echo "${s%/}"; done
    done' | sort
  exit 0
fi

if [ "${1:-}" = "--restore" ]; then
  echo "${BOLD}${BLUE}▸ เอา bundled skills กลับมาทั้งหมด${RESET}"
  rm -f data/.no-bundled-skills
  running && docker exec "$CONTAINER" /opt/hermes/.venv/bin/hermes skills opt-in >/dev/null 2>&1 || true
  echo "${GREEN}  ลบ marker แล้ว — restart แล้ว container จะ sync 71 ตัวกลับเอง${RESET}"
  echo "${DIM}  docker compose restart hermes${RESET}"
  exit 0
fi

[ -f "$KEEP_FILE" ] || { echo "${RED}✗ ไม่มี $KEEP_FILE${RESET}" >&2; exit 1; }
running || { echo "${RED}✗ container $CONTAINER ไม่ได้รัน — docker compose up -d ก่อน${RESET}" >&2; exit 1; }

mapfile -t KEEP < <(grep -vE '^\s*#|^\s*$' "$KEEP_FILE" | tr -d ' \r')
[ "${#KEEP[@]}" -gt 0 ] || { echo "${RED}✗ keep-list ว่าง${RESET}" >&2; exit 1; }

# ตรวจก่อนลบว่าทุกตัวใน keep-list มีอยู่จริง — พิมพ์ผิดแล้วลบทิ้งหมดจะเจ็บ
echo
echo "${BOLD}${BLUE}▸ 1. ตรวจ keep-list (${#KEEP[@]} ตัว)${RESET}"
bad=0
for s in "${KEEP[@]}"; do
  if docker exec "$CONTAINER" test -f "/opt/hermes/skills/$s/SKILL.md" 2>/dev/null; then
    echo "${GREEN}  ✓${RESET} $s"
  else
    echo "${RED}  ✗ ไม่มี $s ใน /opt/hermes/skills${RESET}"; bad=1
  fi
done
[ "$bad" = 0 ] || { echo "${RED}✗ หยุด — แก้ $KEEP_FILE ก่อน (ดูรายชื่อ: --list-available)${RESET}"; exit 1; }

before=$(docker exec "$CONTAINER" sh -c 'ls -d /opt/data/skills/*/*/ 2>/dev/null | wc -l' || echo 0)

# ------------------------------------------------------------------ ตัด ---
echo
echo "${BOLD}${BLUE}▸ 2. ตั้ง marker + ลบ bundled skills ที่ไม่ได้แก้เอง${RESET}"
docker exec "$CONTAINER" /opt/hermes/.venv/bin/hermes skills opt-out --remove --yes 2>&1 \
  | grep -viE '^\s*$' | tail -5 | sed 's/^/  /' || true

# --- กวาดที่ opt-out ไม่แตะ ---
# `opt-out --remove` ลบเฉพาะ bundled ที่ไม่ได้แก้เอง — "official optional"
# skills (ตัวที่มีทั้งใน skills/ และ optional-skills/ เช่น mlops/inference,
# mlops/models) รอดมาเสมอ  keep-list ต้องเป็นตัวตัดสินสุดท้าย จึงกวาดซ้ำเอง
echo
echo "${BOLD}${BLUE}▸ 2b. กวาดตัวที่ opt-out ไม่แตะ${RESET}"
swept=0
while read -r d; do
  [ -n "$d" ] || continue
  for k in "${KEEP[@]}"; do [ "$k" = "$d" ] && continue 2; done
  docker exec "$CONTAINER" rm -rf "/opt/data/skills/$d"
  echo "${YELLOW}  −${RESET} $d ${DIM}(official optional — opt-out ไม่ลบให้)${RESET}"
  swept=$((swept+1))
done < <(docker exec "$CONTAINER" find /opt/data/skills -mindepth 2 -maxdepth 2 -type d \
  -printf '%P\n' 2>/dev/null || true)
[ "$swept" = 0 ] && echo "${DIM}  ไม่มีตัวตกค้าง${RESET}"

# --------------------------------------------------------------- copy กลับ -
echo
echo "${BOLD}${BLUE}▸ 3. copy เฉพาะตัวใน keep-list กลับเข้า /opt/data/skills${RESET}"
for s in "${KEEP[@]}"; do
  # ลบปลายทางก่อน — cp -a src dest ตอน dest มีอยู่แล้วจะได้ dest/<ชื่อ>/<ชื่อ> ซ้อนกัน
  # (เจอจริงตอนรันสคริปต์ซ้ำรอบสอง: skills index โตจาก 835 B เป็น 1,387 B)
  docker exec "$CONTAINER" sh -c "
    rm -rf '/opt/data/skills/$s' &&
    mkdir -p '/opt/data/skills/$(dirname "$s")' &&
    cp -a '/opt/hermes/skills/$s' '/opt/data/skills/$s'" 2>&1 | sed 's/^/  /'
  echo "${GREEN}  +${RESET} $s"
done

# DESCRIPTION.md ของหมวด — ไม่ใช่ skill แต่ index อ่านเพื่อจัดกลุ่ม
for c in $(printf '%s\n' "${KEEP[@]}" | cut -d/ -f1 | sort -u); do
  docker exec "$CONTAINER" sh -c "
    [ -f /opt/hermes/skills/$c/DESCRIPTION.md ] &&
    cp -a /opt/hermes/skills/$c/DESCRIPTION.md /opt/data/skills/$c/ || true" 2>/dev/null || true
done

after=$(docker exec "$CONTAINER" sh -c 'ls -d /opt/data/skills/*/*/ 2>/dev/null | wc -l' || echo 0)

# ------------------------------------------------------------------ วัด ---
echo
echo "${BOLD}${BLUE}▸ 4. วัดผล${RESET}"
echo "${DIM}  skills: $before → $after${RESET}"
docker exec "$CONTAINER" /opt/hermes/.venv/bin/hermes prompt-size 2>/dev/null \
  | grep -E "System prompt total|skills index|Tool schemas" | sed 's/^/  /' || true

echo
echo "${GREEN}✓ เสร็จ${RESET} ${DIM}— restart เพื่อให้ gateway โหลด index ใหม่:${RESET}"
echo "  docker compose restart hermes"
