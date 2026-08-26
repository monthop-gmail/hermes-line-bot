#!/usr/bin/env bash
# Probe: โมเดลไหนใน LiteLLM gateway รับ Hermes ไหว
#
# Hermes ยิง ~13.5K tokens ทุก call และวิ่งด้วย tool loop ล้วน ๆ
# เกณฑ์ผ่านจึงมี 3 ข้อ ต้องผ่านครบ:
#   1. tool_calls กลับมาเป็น field จริง ไม่ใช่ <tool_call> ปนใน content
#   2. รับ prompt ~14K tokens ได้ ไม่ 429/413
#   3. ตอบไทยรู้เรื่อง
#
#   ./scripts/probe-litellm.sh                 # ยิงชุด default
#   ./scripts/probe-litellm.sh or/ox-alpha ... # ระบุเอง
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000/v1}"
KEY="${LITELLM_KEY:-}"
if [[ -z "$KEY" && -f .env ]]; then
  KEY=$(grep -E '^LITELLM_KEY=' .env | cut -d= -f2- || true)
fi
# ไม่ fallback ไปหยิบ LITELLM_MASTER_KEY โดยตั้งใจ — master key เป็น admin ของทั้ง
# gateway (ออก/เพิกถอน key คนอื่น ดู spend ทุกใบ ข้าม budget) ต้องใช้ virtual key
[[ -n "$KEY" ]] || { echo "ไม่มี LITELLM_KEY — ใส่ใน .env หรือ export มา" >&2; exit 1; }

# ตัวที่ context ใหญ่พอสำหรับ Hermes — แก้ให้ตรงกับโมเดลที่ gateway ของคุณมี
DEFAULT_MODELS=(
  or/nemotron-ultra-550b   # 1M ctx
  or/ox-alpha              # 1M ctx
  or/dots-3-note           # 512K ctx
  or/nemotron-super-120b   # 262K
  or/gemma-4-31b           # 262K
  oc/nemotron-3-ultra
  oc/gpt-oss-120b
  gq/gpt-oss-120b
  nim/deepseek-v4-flash
  mi/large
  cb/gpt-oss-120b
  or/auto-free
)
MODELS=("${@:-}")
[[ -z "${MODELS[0]:-}" ]] && MODELS=("${DEFAULT_MODELS[@]}")

mkdir -p results
printf '%-24s %-6s %-7s %-9s %s\n' MODEL TOOLS BIG-CTX TIME NOTE
printf '%.0s-' {1..78}; echo

for m in "${MODELS[@]}"; do
  BASE="$BASE" KEY="$KEY" MODEL="$m" python3 - <<'PY'
import json, os, time, urllib.request, urllib.error

base, key, model = os.environ["BASE"], os.environ["KEY"], os.environ["MODEL"]

def call(payload, timeout=180):
    # 🔴 ปิด fallback ของ LiteLLM เสมอ — ไม่งั้นพอโมเดลที่ขอตาย มันสลับไปตัวสำรอง
    # เงียบ ๆ แล้วเราบันทึกผลของ "ตัวสำรอง" ใส่ชื่อโมเดลที่ขอ
    # (บทเรียนจาก llm-gateway: ค่า latency_ms_14k ที่ส่งไปรอบแรกผิดไป 11 ตัวเพราะข้อนี้)
    payload = {**payload, "disable_fallbacks": True}
    req = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200]
        return e.code, {"_raw": body}
    except Exception as e:
        return 0, {"_raw": f"{type(e).__name__}: {e}"[:200]}

TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_shell",
        "description": "รันคำสั่ง shell แล้วคืน stdout",
        "parameters": {
            "type": "object",
            "properties": {"cmd": {"type": "string"}},
            "required": ["cmd"],
        },
    },
}]

# --- 1) tool calling + ภาษาไทย ---------------------------------------------
t0 = time.time()
st, body = call({
    "model": model,
    "messages": [
        {"role": "system", "content": "คุณเป็นผู้ช่วยที่ตอบเป็นภาษาไทย เรียกใช้ tool เมื่อจำเป็น"},
        {"role": "user", "content": "ช่วยดูหน่อยว่าในโฟลเดอร์ /tmp มีไฟล์อะไรบ้าง"},
    ],
    "tools": TOOLS,
    "max_tokens": 512,
})
elapsed = time.time() - t0

tools_ok, note, mismatch = "no", "", ""
if st != 200:
    note = f"HTTP {st}: {str(body.get('_raw', body))[:60]}"
elif not body.get("choices"):
    note = "ไม่มี choices: " + json.dumps(body)[:60]
else:
    # ตรวจซ้ำว่าใครตอบจริง — disable_fallbacks ควรกันได้แล้ว แต่ยืนยันไว้ดีกว่าเดา
    answered = body.get("model") or ""
    mismatch = (f"⚠️ ตอบโดย {answered} ไม่ใช่ {model} · "
                if answered and model.split("/")[-1] not in answered else "")
    msg = body["choices"][0].get("message") or {}
    content = msg.get("content") or ""
    if msg.get("tool_calls"):
        tools_ok = "YES"
    elif "<tool_call>" in content or '"name"' in content and "run_shell" in content:
        tools_ok = "text"          # พ่น tool call ปนใน text — Hermes ใช้ไม่ได้
        note = "tool call ปนใน content"
    else:
        note = "ไม่เรียก tool: " + content.replace("\n", " ")[:50]

# --- 2) prompt ใหญ่ ~14K tokens (พื้นของ Hermes ทุก call) -------------------
big = "บรรทัดที่ %d: ข้อมูลตัวอย่างสำหรับวัดว่า context รับไหวไหม\n"
filler = "".join(big % i for i in range(1400))     # ~14K tokens
bst, bbody = call({
    "model": model,
    "messages": [
        {"role": "system", "content": filler},
        {"role": "user", "content": "ตอบสั้น ๆ ว่า 'รับได้' ถ้าคุณอ่านข้อความข้างบนครบ"},
    ],
    "tools": TOOLS,
    "max_tokens": 64,
}, timeout=240)
big_ok = "YES" if bst == 200 and bbody.get("choices") else "no"
if big_ok == "no" and not note:
    note = f"ctx {bst}: {str(bbody.get('_raw', bbody))[:50]}"

print("%-24s %-6s %-7s %-9s %s" % (model, tools_ok, big_ok, f"{elapsed:.1f}s", mismatch + note))
PY
done
