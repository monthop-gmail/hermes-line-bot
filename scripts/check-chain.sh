#!/usr/bin/env bash
# ============================================================================
# check-chain.sh — โมเดลทุกตัวที่ config อ้างถึง ยังใช้ได้จริงไหม
#
# ทำไมต้องมี:
#   2026-08-27 พบว่า or/ox-alpha (fallback อันดับ 1) ตายถาวรมาไม่รู้กี่วัน
#   OpenRouter จบช่วง stealth testing แล้วปิดชื่อทิ้ง — บอทไม่แสดงอาการอะไรเลย
#   เพราะ main ยังดีอยู่ กว่าจะรู้ก็ตอนมานั่งไล่ยิงมือ
#
#   chain ที่ไม่เคยถูกทดสอบ = chain ที่ไม่มีอยู่จริง
#
#   ./scripts/check-chain.sh            # ตรวจทุกตัวที่ config อ้างถึง
#   ./scripts/check-chain.sh -q         # เงียบ ๆ เอาแต่ exit code (ใส่ cron ได้)
#
# exit 0 = main ใช้ได้ และมีตัวสำรองที่ใช้ได้อย่างน้อย 1 ตัว
# exit 1 = main พัง หรือ ตัวสำรองตายหมด
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

[ -f .env ] || { echo "${RED}✗ ไม่มี .env — รัน ./scripts/init.sh ก่อน${RESET}" >&2; exit 2; }
set -a; . ./.env; set +a
: "${LITELLM_BASE_URL:?ต้องมี LITELLM_BASE_URL ใน .env}"
: "${LITELLM_KEY:?ต้องมี LITELLM_KEY ใน .env}"

TMPL=config/config.yaml.tmpl
[ -f "$TMPL" ] || { echo "${RED}✗ ไม่เจอ $TMPL${RESET}" >&2; exit 2; }

# ---------------------------------------------------------------------------
# ดึงรายชื่อโมเดลที่ config อ้างถึงจริง พร้อมบทบาท — ไม่ hardcode
# ถ้าใครแก้ config แล้วลืมแก้สคริปต์นี้ ก็ยังตรวจถูกอยู่
# ---------------------------------------------------------------------------
ROLES=$(python3 - "$TMPL" <<'PY'
import os, re, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
seen, out = set(), []

def expand(v):
    """template ใช้ ${HERMES_MODEL} — ขยายจาก .env ที่ source เข้ามาแล้ว"""
    if not isinstance(v, str):
        return v
    return re.sub(r"\$\{(\w+)\}", lambda m: os.environ.get(m.group(1), m.group(0)), v)

def add(model, role):
    model = expand(model)
    if not model or model.startswith("${"):
        if model:
            out.append(f"{model}\t{role} (ขยายตัวแปรไม่ออก)")
        return
    if model not in seen:
        seen.add(model); out.append(f"{model}\t{role}")

add((cfg.get("model") or {}).get("default"), "main")
for i, f in enumerate(cfg.get("fallback_providers") or [], 1):
    add(f.get("model"), f"fallback {i}")
for k, v in (cfg.get("auxiliary") or {}).items():
    add((v or {}).get("model"), f"auxiliary ({k})")
for name, v in (cfg.get("quick_commands") or {}).items():
    t = (v or {}).get("target") or ""
    if t.startswith("model "):
        add(t.split()[-1], f"/{name}")
print("\n".join(out))
PY
) || { echo "${RED}✗ อ่าน $TMPL ไม่ได้ — เป็น YAML ที่ parse ได้ไหม${RESET}" >&2; exit 2; }

[ -n "$ROLES" ] || { echo "${RED}✗ ไม่เจอโมเดลใน config เลย${RESET}" >&2; exit 2; }

# ---------------------------------------------------------------------------
# ยิงจริงทีละตัว
#   🔴 disable_fallbacks: true — ไม่งั้นวัดตัวสำรองแล้วบันทึกใส่ชื่อตัวที่ขอ
#   ⚠️ BASE_URL ลงท้าย /v1 อยู่แล้ว ห้ามเติมซ้ำ (เคยได้ 404 detail:Not Found)
#   ⚠️ max_tokens ต้องเผื่อ reasoning model — ตั้งต่ำไปได้ content ว่างแล้วอ่านผลผิด
# ---------------------------------------------------------------------------
TIMEOUT="${CHAIN_TIMEOUT:-120}"
URL="${LITELLM_BASE_URL%/}/chat/completions"
main_ok=0; fb_total=0; fb_ok=0

[ "$QUIET" = 1 ] || {
  echo "${DIM}ยิงจริงด้วย disable_fallbacks:true — ผลที่ได้คือของโมเดลตัวนั้นแน่นอน${RESET}"
  echo
  printf '%-24s %-18s %s\n' MODEL บทบาท ผล
  printf '%.0s-' {1..76}; echo
}

while IFS=$'\t' read -r model role; do
  [ -n "$model" ] || continue
  case "$role" in fallback*) fb_total=$((fb_total+1)) ;; esac

  body=$(docker run --rm --network llm-clients curlimages/curl:latest \
    -sS --max-time "$TIMEOUT" -w '\n__H__%{http_code}' -X POST "$URL" \
    -H "Authorization: Bearer $LITELLM_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":200,\"disable_fallbacks\":true}" 2>&1)

  verdict=$(MODEL="$model" python3 scripts/_verdict.py <<<"$body")
  status=${verdict%%$'\t'*}
  detail=${verdict#*$'\t'}

  case "$status" in
    ok)     mark="${GREEN}✓ ใช้ได้${RESET}"
            [ "$role" = "main" ] && main_ok=1
            case "$role" in fallback*) fb_ok=$((fb_ok+1)) ;; esac ;;
    quota)  mark="${YELLOW}◐ โควตาหมด${RESET}" ;;
    slow)   mark="${YELLOW}◐ ช้าเกิน${TIMEOUT}s${RESET}" ;;
    dead)   mark="${RED}✗ ตายถาวร${RESET}" ;;
    wrong)  mark="${RED}✗ วัดผิด${RESET}" ;;
    *)      mark="${RED}✗ พัง${RESET}" ;;
  esac
  [ "$QUIET" = 1 ] || printf '%-24s %-18s %b %s\n' "$model" "$role" "$mark" "${DIM}${detail}${RESET}"
done <<< "$ROLES"

rc=0
[ "$main_ok" = 1 ] || rc=1
[ "$fb_total" = 0 ] || [ "$fb_ok" -gt 0 ] || rc=1

[ "$QUIET" = 1 ] || {
  echo
  echo "${DIM}ตัวสำรองที่ใช้ได้ตอนนี้: $fb_ok/$fb_total${RESET}"
  if [ "$rc" = 0 ]; then
    echo "${GREEN}chain ยังใช้งานได้${RESET}"
  else
    echo "${RED}chain มีปัญหา — main พัง หรือตัวสำรองตายหมด${RESET}"
  fi
  echo "${DIM}หมายเหตุ: 'โควตาหมด' ไม่ใช่ความผิดพลาด ตัวสำรองที่ดีคือตัวที่ว่างตอนตัวหลักตาย${RESET}"
}
exit $rc
