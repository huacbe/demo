import json
import time
import urllib.request
from datetime import datetime

URL = "http://127.0.0.1:8000/api/chat"
OUT = r"D:\demo\restaurant-ai\大单配菜方案.md"

combos = [(p, b) for p in range(8, 15) for b in range(700, 1300, 100)]


def call(p, b):
    payload = {
        "message": f"{p}个人，预算{b}元，帮我配菜",
        "history": [],
    }
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        URL,
        data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read().decode("utf-8"))


def md_block(p, b, data):
    reply = data.get("reply", "").strip()
    dishes = data.get("dishes", [])
    real_total = sum(float(str(d.get("price", "0"))) for d in dishes if d.get("price"))
    dev = real_total - b

    lines = [f"## {p} 人 · {b} 元", ""]
    lines.append("**配菜说明：**")
    lines.append("")
    lines.append(reply if reply else "（无说明）")
    lines.append("")
    lines.append(
        f"**菜品清单（{len(dishes)} 道，合计 {real_total:.0f} 元；预算 {b} 元，偏差 {dev:+.0f} 元）：**"
    )
    lines.append("")
    lines.append("| 菜名 | 价格（元） |")
    lines.append("| --- | --- |")
    for d in dishes:
        name = str(d.get("name", "")).strip()
        price = str(d.get("price", "")).strip()
        lines.append(f"| {name} | {price} |")
    lines.append("")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


header = (
    "# 大单配菜方案（8–14 人 × 700–1200 元）\n\n"
    "> 生成说明：由当前配菜系统（千问 qwen3.8-flash + thinking_budget=1800）"
    "逐组实际调用生成，共 42 组。\n\n"
)

with open(OUT, "w", encoding="utf-8") as f:
    f.write(header)

for i, (p, b) in enumerate(combos, 1):
    data = None
    for attempt in range(3):
        try:
            data = call(p, b)
            break
        except Exception as e:
            print(f"[{i}/{len(combos)}] {p}人{b}元 第{attempt+1}次失败：{e}", flush=True)
            time.sleep(5)
    if data is None:
        data = {"reply": "（生成失败）", "dishes": [], "total": 0, "people": p}

    block = md_block(p, b, data)
    with open(OUT, "a", encoding="utf-8") as f:
        f.write(block)

    real_total = sum(
        float(str(d.get("price", "0"))) for d in data.get("dishes", []) if d.get("price")
    )
    print(
        f"[{i}/{len(combos)}] {p}人{b}元 -> {len(data.get('dishes', []))}道 / "
        f"合计{real_total:.0f}元",
        flush=True,
    )

print("DONE", OUT, flush=True)
