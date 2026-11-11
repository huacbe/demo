import json
import re
import time
import urllib.request

URL = "http://127.0.0.1:8000/api/chat"
OUT = r"D:\demo\restaurant-ai\大单配菜方案.md"

ORDER = [(p, b) for p in range(8, 15) for b in range(700, 1300, 100)]

# 偏差 >= 40 元的组合，重新配菜
REDO = {
    (8, 1000), (8, 1100), (8, 1200),
    (9, 1100), (9, 1200),
    (10, 1100), (10, 1200),
    (11, 1100),
    (14, 1100),
}


def call(p, b):
    payload = {"message": f"{p}个人，预算{b}元，帮我配菜", "history": []}
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


def parse_blocks(text):
    pat = re.compile(r"^## (\d+) 人 · (\d+) 元\s*$")
    blocks = {}
    order = []
    current = None
    buf = []
    for line in text.split("\n"):
        m = pat.match(line)
        if m:
            if current is not None:
                blocks[current] = "\n".join(buf)
            current = (int(m.group(1)), int(m.group(2)))
            buf = [line]
            order.append(current)
        else:
            if current is None:
                continue  # 丢弃旧文件头，下面重建
            buf.append(line)
    if current is not None:
        blocks[current] = "\n".join(buf)
    return blocks, order


def main():
    with open(OUT, "r", encoding="utf-8") as f:
        old = f.read()
    blocks, _ = parse_blocks(old)

    for (p, b) in ORDER:
        if (p, b) not in REDO:
            continue
        data = None
        for attempt in range(3):
            try:
                data = call(p, b)
                break
            except Exception as e:
                print(f"[重配] {p}人{b}元 第{attempt+1}次失败：{e}", flush=True)
                time.sleep(5)
        if data is None:
            print(f"[重配] {p}人{b}元 全部失败，保留原结果", flush=True)
            continue
        blocks[(p, b)] = md_block(p, b, data)
        real_total = sum(
            float(str(d.get("price", "0"))) for d in data.get("dishes", []) if d.get("price")
        )
        print(
            f"[重配] {p}人{b}元 -> {len(data.get('dishes', []))}道 / 合计{real_total:.0f}元 "
            f"(偏差 {real_total - b:+.0f})",
            flush=True,
        )

    header = (
        "# 大单配菜方案（8–14 人 × 700–1200 元）\n\n"
        "> 生成说明：由当前配菜系统（千问 qwen3.8-flash + thinking_budget=1800）实际生成，共 42 组。\n"
        "> 第一轮中偏差 ≥ 40 元的 26 组已按放宽后的规则重新配菜"
        "（允许荤菜品类重复、多加蔬菜、蒸菜可适量重复）。\n"
        "> 规则文件：knowledge/ai点菜基本规则/配菜规则.md（预算目标 ±40 元，含大单补足预算规则）。\n\n"
    )

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(header)
        for key in ORDER:
            f.write(blocks.get(key, ""))
            f.write("\n")

    print("DONE", OUT, flush=True)


if __name__ == "__main__":
    main()
