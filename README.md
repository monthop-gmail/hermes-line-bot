# hermes-line

**POC: ต่อ Hermes Agent เข้า LINE OA ให้คุยได้ทั้งแชทส่วนตัวและในกลุ่ม
โดยใช้โมเดลจาก [`llm-gateway`](https://github.com/monthop-gmail/llm-gateway) (LiteLLM)**

> เริ่ม 2026-08-25 · ต่อยอดจากการคัดโมเดลใน [`hermes-free-model`](https://github.com/monthop-gmail/hermes-free-model) (Hermes × OKMD)
> ที่ตันเพราะโควตา — รอบนี้เปลี่ยนแหล่งโมเดลเป็น LiteLLM ที่มี 72 โมเดลและ fallback ของตัวเอง
>
> **สถานะ: คุยผ่าน LINE ได้จริงแล้ว ทั้ง 1:1 และในกลุ่ม** (ยืนยัน 2026-08-25 18:15)
> 12 ข้อความจริง ตอบสำเร็จ 12 — private เฉลี่ย 5.7s · group เฉลี่ย 4.5s
> ดูรายละเอียดที่หัวข้อ [ยืนยันแล้ว](#ยืนยันแล้ว--ยังไม่ได้ยืนยัน)

---

## POC นี้จบที่ไหน

repo นี้มีสองบทบาท:

1. **พิสูจน์ว่า Hermes Agent คุย LINE OA ได้จริง** — ทั้งแชทส่วนตัวและกลุ่ม
   โดยไม่ต้องเขียน bridge เพราะ Hermes เป็นเจ้าของ LINE channel เอง
2. **เป็นต้นแบบของ `hermes` engine ใน [botforge](https://github.com/monthop-gmail/botforge)**
   ซึ่งสร้าง LINE bot ได้ด้วยคำสั่งเดียว — ของในนี้ถูกยกไปเป็น
   `templates/bot-service-hermes/` แล้ว

ถ้าจะ **สร้างบอทหลายตัว** ใช้ botforge จะง่ายกว่า (scaffold + tunnel + DNS ให้อัตโนมัติ)
repo นี้เหมาะกับการ **เข้าใจว่ามันทำงานยังไง** และเป็นที่บันทึกบั๊กที่เจอระหว่างทาง

### repo ที่เกี่ยวข้อง

| repo | บทบาท |
|---|---|
| [`llm-gateway`](https://github.com/monthop-gmail/llm-gateway) | LiteLLM gateway ที่เป็นแหล่งโมเดล |
| [`hermes-free-model`](https://github.com/monthop-gmail/hermes-free-model) | คัดว่า free model ตัวไหนรับ Hermes ไหว |
| [`botforge`](https://github.com/monthop-gmail/botforge) | ปลายทาง — สร้าง LINE bot หลายตัวจากเทมเพลต |

---

## ข้อค้นพบที่เปลี่ยนรูปงานทั้งหมด

**Hermes มี LINE adapter อยู่ในตัวแล้ว** — `plugins/platforms/line/adapter.py`
1,758 บรรทัด เป็น bundled plugin ที่มาพร้อม image ไม่ต้องลงอะไรเพิ่ม

แผนเดิมที่คิดไว้คือเขียน bridge เอง (แบบ `nst-opencode-line-bot` ที่รันอยู่บนเครื่องนี้:
bun + `@line/bot-sdk` 1,298 บรรทัด คุยกับ opencode server) **ไม่ต้องทำแล้ว**
งานที่เหลือคือ config ล้วน ๆ

สิ่งที่ adapter ทำให้แล้ว — ตรวจจาก source ไม่ได้เชื่อ doc:

| ความสามารถ | สถานะ | ที่มา |
|---|---|---|
| แชทส่วนตัว (`source.type=user`) | ✅ | `_resolve_chat()` → `chat_type="dm"` |
| กลุ่ม (`source.type=group`, C…) | ✅ | → `chat_type="group"` |
| ห้อง multi-chat (`source.type=room`, R…) | ✅ | → `chat_type="room"` |
| ตรวจลายเซ็น HMAC-SHA256 | ✅ | `_verify_signature()` + `hmac.compare_digest` |
| กัน webhook ส่งซ้ำ | ✅ | dedup ด้วย `webhookEventId` |
| กันบอทตอบตัวเอง | ✅ | เทียบกับ `bot_user_id` จาก `/v2/bot/info` |
| allowlist 3 ชั้น (user/group/room) | ✅ | `_allowed_for_source()` |
| reply token ก่อน แล้วค่อย Push | ✅ | reply ฟรี / Push กินโควตาข้อความ OA |
| ตอบช้า → ปุ่ม postback ขอคำตอบ | ✅ | เกิน 45s ยิง Template Buttons ให้กดรับด้วย token ใหม่ (ฟรี) |
| ตัดข้อความยาวเป็นหลาย bubble | ✅ | 4,500 ตัว/bubble, ≤5 bubble ต่อ call |
| รับรูป/เสียง/วิดีโอ/ไฟล์ | ✅ | ดึงจาก `api-data.line.me` เข้า media cache |
| loading indicator | ✅ | `chat/loading/start` |

**สิ่งที่ adapter ไม่ทำ:**

- 🔴 **ไม่มีเงื่อนไข @mention** — ในกลุ่มที่ผ่าน allowlist บอทตอบ **ทุกข้อความ**
  (grep หา "mention" ทั้งไฟล์ได้ 0 ครั้ง ต่างจาก Mattermost ที่มี `MATTERMOST_REQUIRE_MENTION`)
  กลุ่มที่คนคุยกันเยอะจะเผาโควตาโมเดลเร็วมาก — คุมด้วย `LINE_ALLOWED_GROUPS` ให้แคบไว้ก่อน
- 🔴 **ไม่อ่านรูป** — ไม่ใช่ความผิด adapter แต่ LiteLLM gateway ไม่มีโมเดล vision แล้ว
  (ดู [`docs/MODEL-PROBE.md`](docs/MODEL-PROBE.md))

---

## สถาปัตยกรรม

```
                    LINE Platform
                         │  webhook (https เท่านั้น)
                         ▼
        https://<โดเมนของคุณ>/line/webhook
                         │
              hermes-line-tunnel (cloudflared)
                         │  ingress → http://hermes-line-agent:3000
                         ▼
        ┌────────────────────────────────────────┐
        │ hermes-line-agent      (container)     │
        │  ├── LINE adapter        :3000/line/webhook│
        │  ├── agent loop (14 tools / 4 skills)  │
        │  ├── gateway API         :8642         │
        │  └── dashboard           :9119 (ปิดอยู่)│
        └──────────────┬─────────────────────────┘
                       │ OpenAI-compatible
                       ▼
              llm-litellm:4000/v1    ← network llm-clients (ดู "เน็ตเวิร์ก")
                       │
                       ▼
        Ollama Cloud / NVIDIA NIM / Mistral / OpenRouter / Cerebras
```

**network 2 วง** — `hermes-line_default` (hermes ↔ cloudflared) และ `llm-clients`
(hermes ↔ llm-litellm เท่านั้น) จงใจไม่เอา hermes ไปไว้บน `llm-net` เพราะวงนั้นมี
`llm-db` กับ `openwebui` อยู่ด้วย และ Hermes รันคำสั่งใน container ได้จริง

`./data` → `/opt/data` ในคอนเทนเนอร์ = ทุกอย่างที่ต้องเก็บ:
`config.yaml` `sessions/` `memories/` `skills/` `logs/`

---

## เริ่มใช้

```bash
cp .env.example .env          # แล้วเติม LINE creds (LITELLM_KEY ใส่ไว้ให้แล้ว)
./scripts/init.sh             # เตรียม data/ + gen config + ตรวจทาง LiteLLM
docker compose up -d
docker compose logs -f hermes
```

`init.sh` รันซ้ำได้ปลอดภัย ตรวจให้ 5 อย่าง: `.env` ครบไหม, `data/` + สิทธิ์,
gen `data/config.yaml` จาก template, **ยิง LiteLLM จากในเน็ตเวิร์กเดียวกับที่ hermes จะใช้**
(จะได้เจอปัญหา DNS/route ตั้งแต่ตอนนี้ ไม่ใช่ตอน container ขึ้นแล้ว), และให้ hermes ตรวจ config เอง

### ตั้ง LINE channel

1. [LINE Developers Console](https://developers.line.biz/console/) → สร้าง **Messaging API channel**
2. **Messaging API** tab:
   - *Channel access token (long-lived)* → Issue → ใส่ `LINE_CHANNEL_ACCESS_TOKEN`
   - *Webhook URL* → `https://<โดเมนของคุณ><path>` → **Verify**
     (`<path>` ต้องตรงกับ `platforms.line.extra.webhook_path` — default ของ Hermes
     คือ `/line/webhook` แต่ของที่ยืมมาตอนนี้คือ `/webhook`)
   - *Use webhook* → เปิด
   - *Auto-reply messages* / *Greeting messages* → **ปิด** (ไม่งั้นชนกับบอท)
   - *Allow bot to join group chats* → **เปิด** ← ขาดข้อนี้แล้วใช้ในกลุ่มไม่ได้
3. **Basic settings** → *Channel secret* → ใส่ `LINE_CHANNEL_SECRET`

### allowlist

ปิด `LINE_ALLOW_ALL_USERS` แล้วใส่ id ที่เก็บมาได้:

```
LINE_ALLOWED_USERS=U0123456789abcdef0123456789abcdef
LINE_ALLOWED_GROUPS=C0123456789abcdef0123456789abcdef
```

ทดสอบแล้วว่ากันจริง: id ที่อนุญาต → 200 + ประมวลผล · id แปลกหน้า → 200 แต่ถูกตีตก
(`LINE: rejecting unauthorized source`) ที่ต้องตอบ 200 ให้คนนอกด้วยเพราะไม่งั้น LINE จะ retry

```bash
./scripts/smoke-webhook.sh --id Uffffffffffffffffffffffffffffffff   # ต้องถูกตีตก
./scripts/smoke-webhook.sh --group --id Cfffffffffffffffffffffffffffffff
```

> 🔴 **ห้ามเขียนคอมเมนต์ต่อท้ายบรรทัดค่าใน `.env`** — docker compose **ไม่ตัด
> inline comment** ตัวคอมเมนต์จะกลายเป็นส่วนหนึ่งของค่าและเข้าไปอยู่ใน allowlist จริง ๆ
> เจอมาแล้ว: `LINE_ALLOWED_ROOMS=   # R0123...` ทำให้ค่าในคอนเทนเนอร์เป็น
> `[# R0123... (ห้องแบบหลายคนที่ไม่ใช่กลุ่ม)]` ให้เขียนคอมเมนต์ไว้บรรทัดบนแทน

allowlist แยก 3 ลิสต์จริง ๆ — ใส่ user id ไม่ได้ทำให้คุยในกลุ่มได้ ต้องใส่ group id ด้วย

```bash
# รอบแรก: เปิดรับทุกคนชั่วคราวเพื่อเก็บ id
sed -i 's/^LINE_ALLOW_ALL_USERS=.*/LINE_ALLOW_ALL_USERS=true/' .env
docker compose up -d --force-recreate hermes

# ทักบอทจากแชทส่วนตัว แล้วเชิญเข้ากลุ่มแล้วทักในกลุ่ม
docker compose logs -f hermes | grep -i "line:"

# เอา U… / C… ที่เห็นไปใส่ LINE_ALLOWED_USERS / LINE_ALLOWED_GROUPS
# แล้วปิดกลับ
sed -i 's/^LINE_ALLOW_ALL_USERS=.*/LINE_ALLOW_ALL_USERS=false/' .env
docker compose up -d --force-recreate hermes
```

### ทดสอบโดยไม่ต้องมี LINE จริง

```bash
./scripts/smoke-webhook.sh              # แชทส่วนตัว
./scripts/smoke-webhook.sh --group      # ในกลุ่ม
./scripts/smoke-webhook.sh --bad-sig    # ต้องได้ 401
./scripts/smoke-webhook.sh --id U…      # ยิงด้วย id ที่กำหนดเอง (ทดสอบ allowlist)
./scripts/smoke-webhook.sh -m "สรุปให้หน่อยว่าเมื่อกี้คุยอะไรกัน"
```

ยิง webhook ปลอมที่ **เซ็นด้วย channel secret จริง** เข้า `127.0.0.1:3000`
พิสูจน์ได้ทั้งเส้น: ลายเซ็น → allowlist → session → โมเดล
ส่วนที่พิสูจน์ไม่ได้คือ "การส่งกลับ" เพราะ reply token ปลอมจะโดน `api.line.me` ตีกลับ 400 —
คำตอบจริงไปโผล่ใน `docker compose logs hermes`

---

## ทางเข้าจากอินเทอร์เน็ต

LINE ยิง webhook ได้เฉพาะ **https + โดเมนจริง** ยิง IP เปล่าหรือ http ไม่ได้

### ทาง 1 — cloudflared (แนะนำ)

```bash
# สร้าง tunnel ที่ https://one.dash.cloudflare.com → Networks → Tunnels
# ingress:  <hostname ที่เลือก>  →  http://hermes-line-agent:3000
echo 'CLOUDFLARE_TUNNEL_TOKEN=eyJ...' >> .env
docker compose --profile tunnel up -d
```

แล้วตั้งใน `.env` ให้ครบ:

```
LINE_PUBLIC_URL=https://<hostname ที่เลือก>    # ต้องมี ไม่งั้นส่งรูป/ไฟล์กลับเข้า LINE ไม่ได้
LINE_PORT=3000
LINE_WEBHOOK_PATH=/line/webhook                 # ต้องตรงกับที่ตั้งใน LINE Console
```

### ยืม tunnel ที่มีอยู่แล้ว (ไม่ต้องแตะ Cloudflare)

ถ้ามี tunnel ที่ ingress ชี้ไปที่ container อื่นอยู่แล้ว และอยากให้ Hermes รับแทน
**ไม่ต้องแก้ ingress ที่ Cloudflare และไม่ต้องแก้ Webhook URL ที่ LINE Console** —
ใช้ network alias ให้ชื่อเดิมชี้มาที่ container นี้:

```yaml
# docker-compose.yml — service hermes
    networks:
      default:
        aliases:
          - <ชื่อ container ที่ ingress เดิมชี้ไว้>
      llm-clients:
```

แล้วตั้งอีก 2 อย่างให้ตรงกับของเดิม:

| ที่ตั้ง | ที่ไหน |
|---|---|
| `LINE_PORT` = port ที่ ingress ชี้ | `.env` |
| `webhook_path` = path ที่ LINE Console ตั้งไว้ | `config/config.yaml.tmpl` + `LINE_WEBHOOK_PATH` ใน `.env` |

ใช้ได้จริง ทดสอบแล้ว — เหมาะกับตอน POC ที่ยังไม่อยากสร้าง tunnel/OA ใหม่

> 🔴 **container เดิมกับตัวนี้รันพร้อมกันไม่ได้** — ชื่อชนกัน และ tunnel เดียวกัน
> ถูกรันสองที่ ต้องลงตัวใดตัวหนึ่งก่อน

### ทาง 2 — reverse proxy ของคุณเอง (ไม่ต้องใช้ token)

ถ้ามี Caddy/nginx ที่ถือโดเมนอยู่แล้ว เพิ่ม vhost ชี้มาที่ container นี้:

```caddy
hermes-line.example.com {
	reverse_proxy hermes-line-agent:3000
}
```

แล้วต้องทำอีก 2 อย่าง ไม่งั้น 502:
1. ชี้ DNS A record ของ hostname นั้นมาที่ IP เครื่องนี้
2. ให้ caddy กับ hermes อยู่เน็ตเวิร์กเดียวกัน — caddy อยู่ `odoo-public`
   ส่วน hermes อยู่ `hermes-line_default` + `llm-clients`
   → `docker network connect odoo-public hermes-line-agent` (หรือเพิ่มใน compose)

ไม่ว่าทางไหน **ต้องตั้ง `LINE_PUBLIC_URL` ให้ตรงกับโดเมนนั้นด้วย** ไม่งั้นส่งรูป/ไฟล์กลับเข้า LINE ไม่ได้

---

## persona — ทำไมต้องมี

`config/SOUL.md` → `data/SOUL.md` (init.sh คัดลอกให้)

**LINE แสดงผลเป็นข้อความล้วน ไม่ render markdown** — `**ตัวหนา**` โผล่เป็นดอกจันจริง ๆ
ตารางเละ code block ไม่มีกรอบ  ตอนทดสอบโมเดลตรง ๆ ทุกตัวตอบมาเป็น markdown หมด
SOUL.md จึงสั่งเพิ่ม 4 เรื่อง: ห้าม markdown / ตอบสั้น (คนอ่านบนมือถือ, เกิน 4,500 ตัวโดนหั่นฟอง) /
ตอบภาษาเดียวกับที่ผู้ใช้ทัก / งานยาวให้บอกก่อนเพราะ reply token อายุ ~1 นาที

บวกกฎสำหรับกลุ่มอีกชุด: ไม่ใช่ทุกข้อความที่ถามบอท ถ้าเขาคุยกันเองอย่าแทรก,
อย่าเอาเรื่องจากแชทส่วนตัวมาพูดในกลุ่ม, และก่อนลบ/เขียนทับอะไรให้ถามยืนยันก่อน
(ข้อหลังสำคัญเพราะในกลุ่มมีคนหลายคนสั่งงานได้)

ปรับ persona ที่ `config/SOUL.md` แล้วรัน `./scripts/init.sh --force`

---

## พฤติกรรมในกลุ่ม

```yaml
group_sessions_per_user: false      # ตั้งไว้ใน config/config.yaml.tmpl
```

- `false` (ที่ตั้งไว้) — **ทั้งกลุ่มใช้ session เดียว** บอทเห็นบทสนทนาต่อเนื่องของทุกคน
  เหมาะกับ "ผู้ช่วยประจำกลุ่ม" ซึ่งคือโจทย์ของ POC นี้
- `true` (default ของ Hermes) — แยก session รายคนในกลุ่ม บอทจำข้ามคนไม่ได้
  เหมาะกับกลุ่มที่ต้องการความเป็นส่วนตัวรายคน

⚠️ กับ `false` ทุกคนในกลุ่มเห็นบริบทเดียวกัน **อย่าเอาข้อมูลลับเข้ากลุ่ม**
และเพราะไม่มีเงื่อนไข @mention บอทจะตอบทุกข้อความในกลุ่ม

---

## โมเดล

main **`mi/ministral-14b`** · fallback `zen/laguna-s-2.1` → `mi/devstral-medium` → `nim/minimax-m3`

ทุกชั้นข้าม `quota_pool` — Mistral / OpenCode Zen / Ollama Cloud / NVIDIA NIM
เพราะโควตาผูกกับผู้ให้บริการ ไม่ใช่กับชื่อโมเดล

```bash
./scripts/check-chain.sh    # ยิงจริงทุกตัวว่ายังใช้ได้ไหม — รันก่อนเริ่มงานทุกครั้ง
```

> 🔴 **`or/ox-alpha` ตายถาวร 2026-08-27** — OpenRouter จบช่วง stealth testing
> (`openrouter/stealth/ox-alpha` — คำว่า *stealth* อยู่ในชื่อตั้งแต่แรกแต่ไม่มีใครสังเกต)
> มันเป็น fallback อันดับ 1 และตายมาไม่รู้กี่วันโดยไม่มีอะไรฟ้อง เพราะ main ยังดีอยู่
> **นั่นคือเหตุผลที่มี `check-chain.sh`** — chain ที่ไม่เคยถูกทดสอบคือ chain ที่ไม่มีอยู่จริง

คัดจากการยิงจริง 14 ตัว — ผ่านครบ 3 เกณฑ์ 7 ตัว
เหตุผลและตารางเต็มอยู่ที่ [`docs/MODEL-PROBE.md`](docs/MODEL-PROBE.md)

เวลาที่วัดจากการคุยผ่าน LINE จริง:

| model | ต่อ 1 turn | หมายเหตุ |
|---|---|---|
| `mi/ministral-14b` | **~18s** | main — 1B token/เดือน โควตาใจกว้างสุด |
| `mi/devstral-medium` | ~51s | ใกล้เพดาน reply token ของ LINE (60s) |
| `zen/laguna-s-2.1` | reasoning | ไม่ต้องมี key · ไทย 3/3 · `verified_max_prompt` 127,914 |
| `nim/minimax-m3` | 5.7–20.3s | minimax · แกว่งมาก บาง endpoint ช้า/timeout |

**Hermes กิน ~13K tokens ต่อ 1 call เป็นอย่างต่ำ** (system prompt 15.3 KB +
tool schemas 31.0 KB เมื่อวัดที่ `--platform line`) — ยืนยันจาก log จริง:
call แรกของ session อยู่ที่ 12,756–13,600 tokens

แต่ **call ถัดไปในบทสนทนาเดียวกันขึ้นไปถึง 43,330** เพราะบวกบทสนทนาสะสม
ถ้าจะวางแผนโควตาให้ใช้ช่วง **26–60K ต่อ turn** ไม่ใช่ตัวเลขเดียว
(ดูตัวเลขเต็มใน [`docs/MODEL-PROBE.md`](docs/MODEL-PROBE.md))

```bash
docker exec hermes-line-agent hermes prompt-size --platform line   # พื้นต่อ call
./scripts/probe-litellm.sh                                          # คัดโมเดลใหม่
./scripts/probe-thai.sh                                             # วัดว่าอยู่กับภาษาไทยไหม
```

### สลับโมเดลจากในแชท

```
/model <ชื่อ>              เช่น /model zen/laguna-s-2.1
/model <ชื่อ> --global     ให้จำข้าม session
```

`/model` เป็นคำสั่ง built-in ของ Hermes อ่านรายชื่อจาก `custom_providers` ตรง ๆ

> **เคยมีทางลัด `/turbo` `/minimax` `/big` `/nim` `/mistral` — ถอดออกแล้ว 2026-09-03**
> เพราะเป็นสำเนาที่สองของรายชื่อโมเดลที่ต้องดูแลแยก วันนั้นพบว่า **3 ใน 5 ชี้ไป
> โมเดลที่ใช้ไม่ได้แล้วโดยไม่มีใครรู้** ทุกครั้งที่เปลี่ยนโมเดลใน chain ต้องมาไล่แก้
> ที่นี่ด้วย ซึ่งลืมได้ง่าย — เหตุผลเต็มอยู่ในคอมเมนต์ของ `config/config.yaml.tmpl`

> 🔴 **ต้องประกาศ provider เป็น `custom_providers:` (list) ไม่ใช่ `providers:` (dict)**
> ถ้าใช้ dict Hermes จะนับ provider ตัวเดียวเป็นสองตัว (slug `litellm` จาก key
> + `custom:<name>` จากตัวแปลง) แล้ว `_configured_provider_matches()` ปฏิเสธทุกครั้ง
> ที่พิมพ์ชื่อโมเดลเปล่า ๆ ด้วย *"is declared by multiple configured providers"*
> ทำให้ต้องพิมพ์ `/model <ชื่อ> --provider litellm` ยาว ๆ ทุกครั้ง
> ย้ายมาเป็น list แล้วตัวซ้ำหายไป — ยืนยันด้วยการเรียก `switch_model()` ตรง ๆ
>
> ⚠️ prefix ที่ใช้ได้จริงมีแค่ `litellm/` (มาจาก `custom_provider_aliases()`)
> พิมพ์ prefix มั่ว เช่น `gateway/or/ox-alpha` **จะไม่ error แต่ส่งชื่อนั้นไปทั้งก้อน**
> แล้วไปพังที่ LiteLLM เป็น `Invalid model name passed in model=gateway/or/ox-alpha`

### ตัด skills แล้ว: 71 → 4

```bash
./scripts/trim-skills.sh                    # ตัดตาม config/skills-keep.txt
./scripts/trim-skills.sh --list-available   # ดูรายชื่อทั้งหมดที่เลือกได้
./scripts/trim-skills.sh --restore          # เอา 71 ตัวกลับมา
```

| | ก่อน | หลัง |
|---|---|---|
| จำนวน skills | 71 | **4** |
| skills index (อยู่ใน system prompt ทุก call) | 6,886 B | **835 B** |
| system prompt รวม | 25,974 B | **19,923 B** |

ที่เก็บไว้ 4 ตัว (แก้ที่ [`config/skills-keep.txt`](config/skills-keep.txt)):

| skill | ทำไมเก็บ |
|---|---|
| `autonomous-ai-agents/hermes-agent` | ถามบอทเรื่องตัวมันเอง/ปรับ config ได้ — ใช้บ่อยสุดตอน POC |
| `research/grounded-citations` | ตอบคำถามแบบมีที่มาอ้างอิง ไม่มั่ว |
| `productivity/ocr-and-documents` | คนส่งไฟล์เข้า LINE บ่อย adapter ดึงเข้า media cache ให้แล้ว |
| `productivity/pdf` | เหมือนกัน |

> ทั้งสองตัวหลังสกัด "ข้อความ" ไม่ใช่ vision จึงใช้ได้แม้ gateway ยังไม่มีโมเดล vision

ที่ตัดทิ้งคือของที่ไม่เกี่ยวกับโจทย์นี้เลย — `apple/imessage` `apple/findmy` `comfyui`
`manim-video` `p5js` `touchdesigner-mcp` `polymarket` `openhue` `songwriting-and-ai-music`
`research-paper-writing` และอีก 57 ตัว

**ทำไมต้องมีสคริปต์ ไม่ลบมือ** — container sync bundled skills กลับทุกครั้งที่ boot
(`Done: 0 new, 0 updated, 71 unchanged`) ลบมือแล้วมันกลับมาเอง
ตัวที่หยุด sync คือ marker `/opt/data/.no-bundled-skills`
(`tools/skills_sync.py:688` เช็คก่อนทำอะไรทั้งสิ้น) สคริปต์เขียน marker ให้
แล้วค่อย copy เฉพาะตัวใน keep-list กลับเข้าไป — ตัวที่ copy กลับหลังตั้ง marker
ถูกมองเป็น local skill ไม่ใช่ bundled จึงอยู่รอดข้าม restart และข้าม `hermes update`

ยืนยันแล้ว: restart แล้ว log ขึ้น `(skipped — profile opted out of bundled skills)`
· `0 total bundled` · รันสคริปต์ซ้ำได้ผลเท่าเดิม (idempotent)

> ⚠️ `hermes skills opt-out --remove` **ไม่ลบ "official optional" skills**
> (ตัวที่มีทั้งใน `skills/` และ `optional-skills/` เช่น `mlops/inference` `mlops/models`)
> สคริปต์จึงมีขั้น 2b กวาดซ้ำเอง โดยยึด keep-list เป็นตัวตัดสินสุดท้าย

### ตัด toolsets แล้ว: 27 → 14 tools

พื้นต่อ call ที่ `--platform line` (ตัวเลขฝั่ง `cli` ต่างออกไปเล็กน้อย):

```
                      ก่อน        หลัง
system prompt      25,974 B    16,386 B     ← ตัด skills
tool schemas       44,758 B    31,772 B     ← ตัด toolsets
──────────────────────────────────────
พื้นต่อ call       ~70.7 KB    ~47.0 KB     ≈ 17-20K → ~13K tokens
```

**tool schemas ใหญ่กว่า system prompt ทั้งก้อนสองเท่า** — จะลดพื้นจริงจังต้องมาทางนี้

| toolset | ขนาด | ใช้กับ LINE ไหม |
|---|---|---|
| `session_search` | 6,457 B | ค้น session เก่า — ได้ใช้ |
| `browser` | 6,341 B | ต้องมี chrome + shm 1g เปิดเว็บจริง |
| `file` | 6,143 B | ได้ใช้ |
| `skills` | 5,617 B | ได้ใช้ |
| `terminal` | 4,819 B | ได้ใช้ |
| `delegation` | 3,859 B | แตก sub-agent |
| `memory` | 2,833 B | ได้ใช้ |
| `clarify` | 2,414 B | ได้ใช้ |
| `code_execution` | 2,089 B | ทับกับ terminal |
| `tts` | 1,834 B | ยังไม่ได้ตั้งเสียงออก |
| `todo` | 1,372 B | ได้ใช้ |
| `vision` | 926 B | **gateway ไม่มีโมเดล vision** |

ตัด `browser` + `delegation` + `tts` + `vision` = ลดอีก ~12.9 KB (~29% ของ tool schemas)

ตัดแล้ว — `platform_toolsets` ใน `config/config.yaml.tmpl` เป็น **allowlist**
(ตัวที่ไม่อยู่ในลิสต์ = ปิด) ผลที่ `--platform line`: **44,758 B → 31,772 B (27 → 14 tools)**

> ⚠️ `hermes tools disable --platform line` **ใช้ไม่ได้** — validator ของ CLI รู้จัก
> เฉพาะ platform ที่ built-in (cli, telegram, discord, …) ไม่รู้จัก plugin platform
> อย่าง `line` แต่ตัวอ่าน config รู้จัก จึงต้องเขียน key `line` ลง config เอง
> ยืนยันด้วย `hermes prompt-size --platform line` แล้วตัวเลขลดจริง
>
> ⚠️ `hermes tools disable` **เขียนทับ `data/config.yaml` โดยตรง** ถ้าใช้คำสั่งนั้น
> แล้วรัน `./scripts/init.sh --force` ทีหลัง ค่าจะหาย — แก้ที่ template เท่านั้น

รวมทั้งสองอย่าง (skills + toolsets) พื้นต่อ call ลดจาก ~70.7 KB เหลือ **~47.0 KB**

---

## ยืนยันแล้ว / ยังไม่ได้ยืนยัน

**ยืนยันแล้ว (2026-08-25)**

- ✅ **คุยผ่าน LINE ได้จริง ทั้ง 1:1 และในกลุ่ม** — 12 ข้อความจริง ตอบสำเร็จ 12
  · แชทส่วนตัว 2 ข้อความ เฉลี่ย 5.7s ช้าสุด 7.5s
  · กลุ่ม 10 ข้อความ เฉลี่ย 4.5s ช้าสุด 20.5s
  · ไม่มี error กับ traffic จริงเลย
- ✅ **session รวมทั้งกลุ่มทำงาน** — บอกชื่อในกลุ่มแล้วมันจำได้ข้ามข้อความ (`api_calls=2`)
- ✅ LINE adapter ขึ้นจริง — `LINE: webhook listening on 0.0.0.0:3000/webhook` · `✓ line connected`
- ✅ cloudflared ต่อติด ingress ตรง — `<โดเมน>` → `http://hermes-line-agent:3000`
- ✅ **allowlist กันได้จริง** — id ที่อนุญาต 200 + ประมวลผล / id แปลกหน้า 200 แต่ถูกตีตก
  (`rejecting unauthorized source`) ทดสอบครบทั้ง user และ group
- ✅ ลายเซ็นผิด → **401** (ไม่ใช่ 403 — 403 สงวนให้ media endpoint, `adapter.py:952` vs `:1418`)
- ✅ `data/config.yaml` โหลดผ่าน — `Config version: 33 ✓` ไม่มี warning
- ✅ **เส้นทางโมเดลครบวงจร** — LINE → adapter → LiteLLM → โมเดล → tool call → ตอบไทย
- ✅ **persona สำหรับ LINE ทำงาน** — ตอบข้อความล้วน ไม่มี `**bold**` / ตาราง markdown
- ✅ **ตัด skills 71 → 4** — skills index 6,886 B → 835 B · อยู่รอดข้าม restart
  (log ขึ้น `skipped — profile opted out`) · รันซ้ำได้ผลเท่าเดิม
- ✅ **ตัด toolsets 27 → 14 tools** — tool schemas 44,758 B → 31,772 B ที่ `--platform line`
- ✅ **`/model` พิมพ์ชื่อเปล่าได้** หลังย้ายไป `custom_providers:` + `quick_commands` โหลดครบ 4 ตัว
- ✅ **network แยกแล้ว** — hermes อยู่บน `llm-clients` เห็นแค่ `llm-litellm` ไม่เห็น `llm-db`

**ยังไม่ได้ยืนยัน / ยังไม่ได้ทำ**

- ❌ ยังไม่ได้ทดสอบส่ง/รับ **รูป เสียง ไฟล์** ผ่าน LINE
- ❌ ยังไม่ได้ทดสอบ **ปุ่ม postback ตอนตอบช้าเกิน 45s** (ยังไม่มี turn ไหนเกิน)
- ❌ ยังไม่ได้ตั้ง `LINE_PUBLIC_URL` — ส่งรูป/ไฟล์กลับเข้า LINE จะยังไม่ได้
- ❌ ยังไม่ได้ทดสอบ fallback ตอนโควตาโมเดลหลักหมด

---

## เน็ตเวิร์ก — ทำไมไม่เกาะ `llm-net`

`llm-net` ของ [`llm-gateway`](https://github.com/monthop-gmail/llm-gateway) มี **`llm-db` กับ `openwebui` อยู่ด้วย**
เอา hermes ไปไว้วงนั้นแปลว่า agent ที่รันคำสั่งได้จริงมองเห็น Postgres ของ stack อื่น

จึงแยกเป็น **`llm-clients`** ที่มีแค่ `llm-litellm` กับ client:

```bash
docker network create llm-clients
docker network connect llm-clients llm-litellm     # ต่อสด ไม่ต้อง recreate
```

ต่อสดด้วย `network connect` เพราะ `llm-litellm` กำลังเสิร์ฟ `nst-opencode` กับ
`openwebui` อยู่ — `docker compose up` จะ recreate แล้วทำให้สองตัวนั้นสะดุด
แล้วค่อยเพิ่ม `llm-clients` เข้า `docker-compose.yml` ของ LiteLLM ให้ persist

```
llm-net      : llm-litellm, llm-db, nst-opencode-server        ← ของเดิม
llm-clients  : llm-litellm, hermes-line-agent                  ← ใหม่ ไม่มี db
hermes-line_default : hermes-line-agent, hermes-line-tunnel
```

### เคยติด: docker หมด address pool

ตอนตั้งครั้งแรกเครื่องนี้มี 34 network แล้วสร้างเพิ่มไม่ได้:

```
Error response from daemon: all predefined address pools have been fully subnetted
```

ตอนนั้นแก้ชั่วคราวด้วยการเกาะ `llm-net` ไปก่อน หลังจาก down stack อื่นไปหลายตัว
(เหลือ 26 network) ก็สร้างได้แล้ว **ถ้าเจออีก**: ขยาย pool ใน `/etc/docker/daemon.json`
แล้ว restart docker (กระทบทุก stack — ต้องนัดเวลา) หรือลบ network ที่ไม่มี container เกาะ
(`docker network ls` แล้วเช็คด้วย `docker network inspect <ชื่อ> --format '{{len .Containers}}'`)
— compose สร้างใหม่เองตอน `up` ครั้งถัดไป

---

## ความเสี่ยงที่ต้องดูตอนขึ้นจริง

| ความเสี่ยง | ผลถ้าเกิด | ทางรับมือ |
|---|---|---|
| ไม่มีเงื่อนไข @mention ในกลุ่ม | กลุ่มคุยกันเยอะ = เผาโควตาโมเดล + บอทกวน | `LINE_ALLOWED_GROUPS` แคบไว้ก่อน / ถ้าจำเป็นต้อง patch adapter |
| **Hermes มี terminal tool ที่รันคำสั่งได้จริง** | คนในกลุ่ม LINE สั่งรันคำสั่งในคอนเทนเนอร์ได้ | อยู่ใน container + ไม่ mount อะไรเกินจำเป็น + allowlist แคบ |
| `group_sessions_per_user: false` | ทุกคนในกลุ่มเห็นบริบทเดียวกัน | อย่าเอาข้อมูลลับเข้ากลุ่ม / สลับเป็น `true` ถ้าต้องการแยก |
| โควตาโมเดลฟรีหมด | บอทเงียบ | fallback ข้าม provider 4 ชั้น + LiteLLM มี fallback ของตัวเองอีกชั้น |
| Push API กินโควตาข้อความ OA | ค่าใช้จ่าย/เพดานข้อความ | `LINE_SLOW_RESPONSE_THRESHOLD=45` ให้ใช้ปุ่ม postback (ฟรี) แทน Push |
| ~~hermes อยู่เน็ตเวิร์กเดียวกับ llm-db~~ | — | ✅ **แก้แล้ว** — แยกไป `llm-clients` |
| โมเดลหลุดไปตอบภาษาอื่น | บอทไทยตอบจีน/อังกฤษ | เลี่ยง `oc/gpt-oss-120b` · วัดด้วย `./scripts/probe-thai.sh` |
| รันสอง gateway ชี้ `data/` เดียวกัน | session/memory พัง | ห้ามทำ — ไม่ concurrent-safe |

---

## โครงไฟล์

```
test-hermes-line/
├── docker-compose.yml          # hermes + cloudflared (profile: tunnel)
├── .env.example / .env         # .env gitignore ไว้ chmod 600
├── config/
│   ├── config.yaml.tmpl        # template ที่ commit — ของจริงคือ data/config.yaml
│   ├── SOUL.md                 # persona — ของจริงคือ data/SOUL.md
│   └── skills-keep.txt         # skills ที่ให้ seed (71 → 4)
├── scripts/
│   ├── init.sh                 # เตรียม data/ + gen config + ตรวจทาง LiteLLM
│   ├── probe-litellm.sh        # คัดโมเดลด้วยเกณฑ์ของ Hermes
│   ├── probe-thai.sh + _lang.py # วัดว่าโมเดลอยู่กับภาษาไทยไหมตอนวิ่ง tool loop
│   ├── trim-skills.sh          # ตัด bundled skills ตาม keep-list
│   └── smoke-webhook.sh        # ยิง webhook ที่เซ็นถูก ทดสอบโดยไม่ต้องมี LINE
├── docs/MODEL-PROBE.md         # ผลคัดโมเดล 12 ตัว
└── data/                       # → /opt/data (gitignore)
```
