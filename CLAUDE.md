# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## repo นี้คืออะไร

POC ต่อ Hermes Agent เข้า LINE OA โดยใช้โมเดลจาก LiteLLM gateway
**ไม่มีโค้ด bridge** — Hermes มี LINE adapter ในตัว (`plugins/platforms/line/adapter.py`)
repo นี้จึงมีแต่ config + สคริปต์ + บันทึกบั๊กที่เจอ

ของในนี้ถูกยกไปเป็น `templates/bot-service-hermes/` ของ botforge แล้ว

## ⚠️ โฟลเดอร์ไหนเป็นของใคร

| path | เจ้าของ | ทำอะไรได้ |
|---|---|---|
| `/opt/docker-test/test-hermes-line` | **เรา** | repo นี้ = `hermes-line-bot` (public) |
| `/opt/docker-test/poc-huggingface` | **อีกทีม** | **อ่านอย่างเดียว** — ห้าม git/แก้ไฟล์ |
| `/opt/docker-test/server-botforge-v2` | **อีกทีม** | **อ่านอย่างเดียว** — ส่ง PR ไป ไม่ commit ตรง |

**สื่อสารกับทีมอื่นผ่าน GitHub issues/PR เท่านั้น** เคยเผลอ `git checkout -b` ในโฟลเดอร์
อีกทีม (2026-08-26) ผลบน GitHub ถูก แต่ทิ้งรอยใน reflog เขาและเสี่ยงชน working tree

### จะแก้ repo ของทีมอื่น → clone ลง scratchpad

**ห้ามสร้างโฟลเดอร์ถาวรใน `/opt/docker-test/`** — ชื่อจะไปชนกับของทีมอื่นและดูเหมือน
เป็นของเขา ให้ clone ใหม่ทุก session ลง scratchpad แทน (ใช้เวลา ~2 วินาที):

```bash
git clone https://github.com/monthop-gmail/llm-gateway.git "$SCRATCH/llm-gateway"
cd "$SCRATCH/llm-gateway" && git checkout -b fix/... && gh pr create ...
```

การอ่านไฟล์/ดู log/ดูสคริปต์ในโฟลเดอร์เขาโดยตรงทำได้ตามปกติ — read-only ไม่กระทบใคร

## บอทจริงไม่ได้รันจาก repo นี้

รันจาก botforge: `/opt/docker-test/server-botforge-v2/projects/nst-hermes/bot-service/`
container ชื่อ **`nst-hermes-line-bot`** ไม่ใช่ `hermes-line-agent`

สคริปต์ probe จึงต้องระบุ container:

```bash
HERMES_CONTAINER=nst-hermes-line-bot ./scripts/probe-thai.sh -n 3 zen/hy3
```

## 🌅 เริ่มวันด้วยคำสั่งนี้ — คำสั่งเดียวจบ

```bash
./scripts/daily.sh
```

รวมงานประจำวันไว้ทั้งหมด **พร้อมพารามิเตอร์ที่ถูกต้องอยู่ในตัวแล้ว** ไม่ต้องจำ:

1. บอทยังวิ่งไหม (`nst-hermes-line-bot`)
2. fallback chain — ยิงจริงทุกตัว
3. สำเนา `config.yaml.tmpl` ทั้ง 3 ที่ยังตรงกันไหม
4. โมเดลที่รอโควตาคืน — ถ้าคืนแล้วมันพิมพ์คำสั่ง probe ที่พร้อมวางให้เลย
5. issue/PR ที่ยังเปิดอยู่ใน 3 repo

ตัวแปรที่ต้องจำ (ชื่อ container · path ของบอท · รายชื่อ repo · โมเดลที่รอโควตา)
รวมไว้บนหัวไฟล์ `scripts/daily.sh` ที่เดียว — สถานการณ์เปลี่ยนก็แก้ตรงนั้น

`--no-github` ข้ามส่วนที่ยิง GitHub API (ตอนโดน rate limit) · `--quota` เช็คเฉพาะข้อ 4

## คำสั่งอื่น

```bash
./scripts/init.sh                  # สร้าง data/config.yaml จาก template (--force = ทับ)
docker compose up -d               # profile tunnel: docker compose --profile tunnel up -d
./scripts/smoke-webhook.sh         # ทดสอบ webhook โดยไม่ต้องมี LINE จริง (--group / --room / --id)
./scripts/trim-skills.sh           # ตัด skills ตาม config/skills-keep.txt (--restore = คืน 71 ตัว)
./scripts/probe-litellm.sh         # คัดโมเดล: ยิง API ตรง
./scripts/probe-thai.sh            # คัดโมเดล: ยิงผ่าน agent loop จริง — ตัวชี้ขาด
./scripts/check-chain.sh           # ⭐ โมเดลทุกตัวที่ config อ้างถึงยังใช้ได้ไหม (-q = เอาแต่ exit code)
```

**รัน `check-chain.sh` ก่อนเริ่มงานทุกครั้ง** — มันยิงจริงทุกตัวใน chain ด้วย
`disable_fallbacks` แล้วแยก `ตายถาวร / โควตาหมด / ช้าเกิน / วัดผิด` ออกจากกัน
chain ที่ไม่เคยถูกทดสอบคือ chain ที่ไม่มีอยู่จริง

นอกจากยิงทีละตัวแล้วมันตรวจ **โครงของ chain** ด้วย (`_chain_audit.py`):

- ชั้นติดกันอยู่ `quota_pool` เดียวกันไหม — ถ้าใช่คือหมดพร้อมกัน เท่ากับไม่มีตัวสำรอง
- ชื่อในchain มีอยู่จริงใน `/model/info` ไหม — **ชื่อผิด LiteLLM เงียบ** คืน error
  ของตัวหลักมาเฉย ๆ อาการเหมือนไม่ได้ตั้ง fallback เลยทุกประการ
- ตัวไหนมี `answered_by` ไหม — ถ้ามีแปลว่าเป็น alias ไป provider อื่นแล้ว

### รัน CI ในเครื่องก่อน push

`.github/workflows/check.yml` รัน 5 อย่าง ทำเองได้ด้วย:

```bash
python3 -c "import yaml; yaml.safe_load(open('config/config.yaml.tmpl'))"
for f in scripts/*.sh; do bash -n "$f"; done
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -S warning scripts/*.sh
python3 -m py_compile scripts/_lang.py
```

## สถาปัตยกรรม

```
LINE ──https──> cloudflared ──> hermes (LINE adapter ในตัว) ──> LiteLLM gateway
                                    │                              (network llm-clients)
                                    └── /opt/data (= ./data) config.yaml .env sessions logs
```

**`config/config.yaml.tmpl` → `data/config.yaml`** — แก้ที่ template เสมอ แล้ว `init.sh --force`
ไฟล์ที่ Hermes อ่านจริงคือ `data/config.yaml` ซึ่ง gitignore ไว้

**template มี 3 สำเนาที่ต้องตรงกัน** (เคย drift มาแล้ว) — เช็คด้วย md5:

```
config/config.yaml.tmpl
/opt/docker-test/server-botforge-v2/templates/bot-service-hermes/config/config.yaml.tmpl
/opt/docker-test/server-botforge-v2/projects/nst-hermes/bot-service/config/config.yaml.tmpl
```

**network**: ต่อ LiteLLM ผ่าน `llm-clients` (มีแค่ litellm + client) ไม่ใช่ `llm-net`
ใช้ virtual key ไม่ใช่ master key

## กฎที่พลาดมาแล้วจริง — อย่าพลาดซ้ำ

### วัดค่าโมเดล ต้องส่ง `disable_fallbacks: true` เสมอ
ไม่งั้นได้ผลของตัวสำรองมาแปะชื่อโมเดลที่ขอ เกิดมาแล้ว 5 ครั้งในโปรเจกต์นี้กับ gateway
`probe-thai.sh` ยิงผ่าน CLI ใส่ในตัว request ไม่ได้ จึงใช้ `--usage-file` อ่านว่าใครตอบจริง

### อ่านค่าจาก `/model/info` ต้องเช็ค `answered_by`
มีค่า = ชื่อนั้นไม่ได้ตอบเอง ตัวเลขที่ติดมาเป็นของตัวสำรอง

### `LITELLM_BASE_URL` ลงท้ายด้วย `/v1` อยู่แล้ว
ต่อ `/chat/completions` ตรง ๆ — เติม `/v1` ซ้ำได้ 404 `{"detail":"Not Found"}`

### ตรวจ response ต้องดู HTTP code + `choices` ไม่ใช่แค่ว่ามี key `error` ไหม
LiteLLM คืน error หลายรูป (`error.message`, `detail`) ตัวตรวจที่ดูรูปเดียวจะรายงานว่าผ่านทั้งที่พัง

### YAML: `*` เปล่า ๆ คือ alias reference
`group_allowed_chats: *` ทำให้ไฟล์ parse ไม่ผ่านทั้งไฟล์ **และ `hermes config check`
ยังตอบว่า "✓ ไม่มีคำเตือน"** — ต้องใส่ quote `"*"` (CI จับให้แล้ว)

### `quick_commands` ห้ามชนชื่อคำสั่ง built-in
`/fast` ชนกับของ Hermes แล้ว alias เงียบไปเฉย ๆ ไม่มี error — เปลี่ยนเป็น `/turbo`
เช็คก่อนตั้งชื่อ: `docker exec <container> hermes --help`

### provider ต้องเป็น `custom_providers:` (list) ไม่ใช่ `providers:` (dict)
dict ทำให้ provider ถูกนับสองครั้ง แล้ว `/model <ชื่อ>` เด้ง
*"declared by multiple configured providers"*

### เลือกโมเดลต้องดู "ขนาดโควตา" ไม่ใช่แค่ `quota_window`
1 turn ของบอทนี้ = **~59K tokens** — `okmd/*` มี ~40K/วัน ซึ่ง**เล็กกว่า turn เดียว**
`quota_window: daily` เหมือนกันแต่ cerebras ~1M/วัน ต่างกันคนละโลก อ่าน `provider_quota`

### โมเดล stealth/preview มีวันหมดอายุในตัว
`or/ox-alpha` = `openrouter/stealth/ox-alpha` ตายถาวรกลางทาง อย่าเอาไปวางเป็น fallback

### `status` ใน `/model/info` เป็นภาพตอน health-check ล่าสุด ไม่ใช่สภาพตอนนี้
จะรู้ว่าตัวไหนใช้ได้จริงต้องยิงเอง

### อย่าแก้สคริปต์ขณะที่มันกำลังรันอยู่เบื้องหลัง
bash อ่านไฟล์ทีละส่วนระหว่างรัน พอไฟล์เลื่อนมันจะพ่น `syntax error near unexpected token`
ที่บรรทัดมั่ว ๆ **ทั้งที่ `bash -n` ผ่าน** — หลงคิดว่าสคริปต์พังไปแล้ว 2 รอบ
สคริปต์พวกนี้ยิงจริงหลายโมเดล ใช้เวลาเป็นนาที ให้รอจบก่อนค่อยแก้

## เอกสาร

- `README.md` — POC log เต็ม
- `docs/MODEL-PROBE.md` — ตารางผลคัดโมเดล
- `config/SOUL.md` — persona สำหรับ LINE (ห้าม markdown, ตอบสั้น, ภาษาเดียวกับผู้ใช้)
