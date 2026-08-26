"""ดูว่าคำตอบใน $OUT เป็นภาษาอะไร — ใช้โดย probe-thai.sh"""
import os
import re

text = os.environ.get("OUT", "")
thai = len(re.findall(r"[฀-๿]", text))
cjk = len(re.findall(r"[一-鿿]", text))
latin = len(re.findall(r"[A-Za-z]", text))

if not text.strip():
    print("err")
elif thai > 40:
    print("th")
elif cjk > 10:
    print("zh")
elif latin > 40:
    print("en")
else:
    print("err")
