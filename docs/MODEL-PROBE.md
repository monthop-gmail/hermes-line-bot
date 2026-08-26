# ผลคัดโมเดลสำหรับ Hermes บน LiteLLM gateway

> ยิงจริงเมื่อ 2026-08-25 ด้วย `./scripts/probe-litellm.sh`
> gateway = `llm-litellm:4000` ของ [`llm-gateway`](https://github.com/monthop-gmail/llm-gateway) (72 โมเดล)

## ทำไมต้องคัด

Hermes ไม่ใช่ chatbot ธรรมดา — มันวิ่งด้วย tool loop ล้วน ๆ และยิง **พื้นคงที่ทุก call**:

```
System prompt  22,442 B  (21.9 KB) ← identity + skills index (71 skills)
Tool schemas   44,758 B  (43.7 KB) ← 27 tools / 12 toolsets
──────────────────────────────────
รวม            ~67 KB   ≈ 17-20K tokens  ต่อ "หนึ่ง call"
```

(วัดด้วย `docker exec hermes-line-agent hermes prompt-size`)

หนึ่ง turn ที่ใช้ tool = อย่างน้อย 2 calls → **~35-40K tokens ต่อ turn**
โมเดลจึงต้องผ่าน 3 ข้อ ไม่ใช่แค่ "ตอบได้":

1. คืน `tool_calls` เป็น field จริง ไม่ใช่ `<tool_call>` ปนใน `content`
2. รับ prompt ~14K tokens ได้ ไม่เด้ง 429/413
3. ตอบไทยรู้เรื่อง และรับผล tool กลับไปสรุปต่อได้ (turn 2)

## ผลรอบแรก — คัดด้วยเกณฑ์ 1 + 2

| model | tool_calls | prompt 14K | เวลา | หมายเหตุ |
|---|---|---|---|---|
| `oc/minimax-m3` | ✅ | ✅ | 2.3s | **ที่เลือกเป็น main** — Ollama Cloud |
| `nim/minimax-m3` | ✅ | ✅ | 5.6s | NVIDIA NIM — minimax ตัวเดียวกัน คนละเจ้า |
| `or/ox-alpha` | ✅ | ✅ | 5.8s | context 1M ฟรีแต่ไม่มี suffix `:free` |
| `oc/nemotron-3-ultra` | ✅ | ✅ | 105.0s | ใหญ่สุดที่ Ollama Cloud ให้ฟรี — call แรกช้ามาก |
| `oc/gpt-oss-120b` | ✅ | ✅ | 1.1s | |
| `mi/large` | ✅ | ✅ | 1.1s | Mistral 1B token/เดือน |
| `cb/gpt-oss-120b` | ✅ | ✅ | 0.4s | เร็วสุด |
| `gq/gpt-oss-120b` | ✅ | ❌ 429 | 0.6s | Groq ชนเพดานตอน prompt ใหญ่ |
| `nim/deepseek-v4-flash` | ✅ | ❌ timeout | 134.3s | prompt ใหญ่แล้วค้างเกิน 240s |

> 📌 **`nim/minimax-m3` ใช้ได้แล้ว (ยิงจริง 2026-08-25)** — README ของ `llm-gateway`
> ยังเขียนว่า *"chat ได้ แต่ใส่ tools แล้ว 404"* ซึ่งตกยุคแล้ว วันนี้ผ่านทั้ง tool calling
> และ prompt 14K
| `or/nemotron-ultra-550b` | ❌ 429 | ❌ 429 | 5.4s | 🔴 OpenRouter ชั้น `:free` ตัน |
| `or/dots-3-note` | ❌ 429 | ❌ 429 | 4.8s | 🔴 เหมือนกัน |
| `or/nemotron-super-120b` | ❌ 429 | ❌ 429 | 4.6s | 🔴 เหมือนกัน |
| `or/gemma-4-31b` | ❌ 429 | ❌ 429 | 5.8s | 🔴 เหมือนกัน |
| `or/auto-free` | ❌ 429 | ❌ 429 | 5.6s | 🔴 router ก็ตันตาม |

> 🔴 **โมเดล `:free` ของ OpenRouter ตันทั้งชุดในวันที่ทดสอบ** — 429 ตั้งแต่ call แรก
> `or/ox-alpha` รอดตัวเดียวเพราะฟรีแบบไม่มี suffix `:free` → คนละถังโควตา
> อย่าวางแผน fallback โดยไล่ `or/*` ต่อกันหลายชั้น มันตายพร้อมกัน

## ผลรอบสอง — คุณภาพไทย + tool loop รอบที่ 2

ป้อนผล tool กลับเข้าไปแล้วดูว่าสรุปต่อได้ไหม (นี่คือสิ่งที่ Hermes ทำทุก turn จริง ๆ)

| model | เวลารวม 2 turn | args ที่โมเดลสร้าง | คำตอบ |
|---|---|---|---|
| `cb/gpt-oss-120b` | **0.8s** | `{"cmd":"ls -la /tmp"}` | ✅ ไทยถูก จัด bullet |
| `oc/gpt-oss-120b` | **1.6s** | `{"cmd":"ls -la /tmp"}` | ✅ ไทยถูก |
| `oc/nemotron-3-ultra` | 5.7s | `{"cmd":"ls -la /tmp"}` | ✅ ไทยถูก |
| `mi/large` | 8.5s | `{"cmd": "ls /tmp"}` | ✅ ไทยถูก ใช้ bold |
| `or/ox-alpha` | 18.9s | `{"cmd":"ls -la /tmp"}` | ✅ ไทยถูก + ถามต่อเอง |

ทั้ง 5 ตัวผ่านหมด — ตัวตัดสินจึงเป็น **เวลา** กับ **ความทนโควตา**

## รอบสาม — โมเดล "อยู่กับภาษาไทย" ไหมตอนวิ่งใน Hermes จริง

รอบหนึ่งกับสองยิง API ตรง ๆ ซึ่ง**ไม่พอ** พอรันใน Hermes จริง บริบทมี system prompt
อังกฤษ 16 KB + ผล tool เป็นอังกฤษล้วน โมเดลบางตัว "ไหล" ไปตอบภาษาอื่นแทน

ทดสอบด้วย `./scripts/probe-thai.sh` (ยิงผ่าน `hermes -z` ในคอนเทนเนอร์จริง):

| โจทย์ | `oc/gpt-oss-120b` | `mi/large` | `or/ox-alpha` |
|---|---|---|---|
| "สรุปว่าใน /opt/data/logs มีไฟล์อะไรบ้าง และแต่ละอันน่าจะเก็บอะไร" | ไทย 3/3 | ไทย 3/3 | ไทย 3/3 |
| "ดูหน่อยว่า /opt/data/skills มีอะไรบ้าง แล้วบอกด้วยว่าเปิดเว็บได้ไหม ตอบสั้นๆ" | 🔴 **จีน 2/3** | — | — |

🔴 **`oc/gpt-oss-120b` หลุดไปตอบภาษาจีน** กับโจทย์ที่มีหลายคำถามในประโยคเดียว
บวก "ตอบสั้นๆ" — ทำซ้ำได้ 2 ใน 3 ครั้ง ทั้งที่ SOUL.md สั่งให้ตอบภาษาเดียวกับผู้ใช้
**ตัดออกจากตัวเลือก main สำหรับบอทไทย**

> บทเรียน: เกณฑ์ "ตอบไทยรู้เรื่อง" วัดจากการยิง API ตรง ๆ ไม่พอ ต้องวัดในสภาพจริง
> ที่บริบทเต็มไปด้วยอังกฤษ

## ที่เลือกใช้ และเหตุผล

```yaml
model:  oc/minimax-m3                   # main
fallback_providers:
  - nim/minimax-m3        # NVIDIA NIM — รุ่นเดียวกัน คนละเจ้า
  - mi/large              # Mistral
  - or/ox-alpha           # OpenRouter (ถังที่ไม่ใช่ :free)
  - cb/gpt-oss-120b       # Cerebras
auxiliary: cb/gpt-oss-120b              # compression / title / skills_hub
```

**main = `oc/minimax-m3`** — เร็ว (2.3s ตอน probe · 2.6–3.6s ตอนคุยผ่าน LINE จริง)
และไม่มีอาการหลุดภาษาแบบ `oc/gpt-oss-120b`

**ไม่ใช้ `cb/gpt-oss-120b` เป็น main** ทั้งที่เร็วกว่า (0.4s) เพราะ Cerebras จำกัดที่
**TPM สะสม ไม่ใช่ context** — Hermes ยิง ~16K tokens ทุก call ยิงไม่กี่ทีก็ชน
`token_quota_exceeded` Ollama Cloud ไม่ประกาศเพดานและยิงรัวไม่โดน rate limit

**ไม่ใช้ `or/ox-alpha` เป็น main** ทั้งที่ context 1M เพราะช้าสุด (~19s ต่อ turn)
แชท LINE รอไม่ไหว — เก็บไว้เป็น fallback และทางลัด `/big` สำหรับงานที่ต้องการ context ใหญ่

**fallback ข้าม provider ทุกชั้น** — โควตาผูกกับผู้ให้บริการ ไม่ใช่ชื่อโมเดล
ไล่ `oc/*` ต่อกันเองไม่มีประโยชน์ ตายพร้อมกัน (บทเรียนเดียวกับ OKMD ใน [`hermes-free-model`](https://github.com/monthop-gmail/hermes-free-model))

**aux อยู่คนละถังกับ main** — งานเบื้องหลัง (บีบ context, ตั้งชื่อ session) ไปลง
Cerebras ซึ่งเร็วและไม่ได้ใช้เป็นตัวหลัก จะได้ไม่ดูดโควตา Ollama Cloud ไปด้วย

## ยังไม่มี — vision

gateway ไม่มีโมเดล vision แล้ว (`or/nemotron-vl-12b` ถูก OpenRouter ถอด endpoint
เมื่อ 2026-08-23) **รูปที่ผู้ใช้ส่งเข้า LINE จะไม่ถูกอ่าน** จนกว่าจะเพิ่มโมเดล
vision เข้า LiteLLM ก่อน แล้วค่อยเติม `auxiliary.vision` ใน `config/config.yaml.tmpl`

## ยิงซ้ำเอง

```bash
./scripts/probe-litellm.sh                        # tool calling + context (ยิง API ตรง)
./scripts/probe-litellm.sh or/ox-alpha mi/large   # ระบุเอง
./scripts/probe-thai.sh                           # ภาษาไทย (ยิงผ่าน Hermes จริง)
./scripts/probe-thai.sh -n 5 oc/minimax-m3        # ระบุเอง + จำนวนรอบ
```

โมเดลฟรีเปลี่ยนบ่อยมาก (gateway ถอด/เพิ่มรายสัปดาห์) — ยิงซ้ำก่อนเชื่อตารางนี้
