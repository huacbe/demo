# ============================================================
# app.py —— FastAPI 后端服务
#
# 职责：
#   1. 接收网页发来的用户消息
#   2. 用向量库检索相关知识片段（RAG）
#   3. 把知识片段 + 用户消息拼成 prompt，调用 DeepSeek 生成回答
#   4. 返回回答给网页
#
# 启动：python app.py
# 然后浏览器打开 web/index.html（或访问 http://127.0.0.1:8000/）
# ============================================================

import math

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import config
import vector_db


# ------------------------------------------------------------
# 创建 FastAPI 应用
# ------------------------------------------------------------
app = FastAPI(title="餐厅 AI 助手后端")

# 允许网页跨域访问（本地调试用）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ------------------------------------------------------------
# 请求/响应模型
# ------------------------------------------------------------
class ChatRequest(BaseModel):
    message: str          # 用户输入
    history: list = []    # 可选：对话历史 [{role, content}, ...]


class DishItem(BaseModel):
    name: str             # 菜名
    price: str = ""       # 价格（字符串，避免浮点精度问题）


class ChatResponse(BaseModel):
    reply: str
    sources: list = []    # 命中的知识来源（便于前端展示"参考来源"）
    dishes: list = []     # 本次推荐的菜品列表 [{name, price}]，用于前端生成"加入购物车"按钮
    total: float = 0      # 配菜总价（仅配菜时用）
    people: int = 0       # 配菜人数（仅配菜时用）
    is_meal: bool = False # 是否为配菜结果


# ------------------------------------------------------------
# 计算两点（经纬度）之间的距离，用 Haversine 公式，返回公里数
# ------------------------------------------------------------
def haversine(lng1, lat1, lng2, lat2):
    R = 6371.0  # 地球半径（公里）
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(a))


def find_nearest_branch(lng, lat):
    """根据用户坐标找最近的门店"""
    best = None
    best_dist = float("inf")
    for b in config.BRANCHES:
        d = haversine(lng, lat, b["lng"], b["lat"])
        if d < best_dist:
            best_dist = d
            best = b
    if best:
        best = dict(best)
        best["distance_km"] = round(best_dist, 2)
    return best


# ------------------------------------------------------------
# 调用 DeepSeek 生成回答
# ------------------------------------------------------------
def call_deepseek(messages, json_mode=False, max_tokens=1500, thinking_budget=0, meal=False):
    """调用大模型生成回答
    json_mode=True 时强制返回 JSON 格式
    thinking_budget>0 时开启千问思考模式并限制思考 token 数（越大越慢越准）
    meal=True 时使用千问（配菜专用），否则使用 DeepSeek（日常对话）
    """
    from openai import OpenAI

    if meal:
        api_key = config.MEAL_API_KEY
        base_url = config.MEAL_BASE_URL
        model = config.MEAL_MODEL
    else:
        api_key = config.DEEPSEEK_API_KEY
        base_url = config.DEEPSEEK_BASE_URL
        model = config.DEEPSEEK_MODEL

    client = OpenAI(api_key=api_key, base_url=base_url)

    extra = {}
    if meal and thinking_budget > 0:
        # 千问开启思考模式，限制思考 token 数
        extra = {"enable_thinking": True, "thinking_budget": thinking_budget}
    elif meal and thinking_budget == -1:
        # 千问思考拉满：开启思考，不限制预算，用模型默认最高强度
        extra = {"enable_thinking": True}
    elif meal:
        # 千问关闭思考模式，加快响应
        extra = {"enable_thinking": False}

    kwargs = dict(
        model=model,
        messages=messages,
        temperature=0.7,
        max_tokens=max_tokens,
    )
    if extra:
        kwargs["extra_body"] = extra
    if json_mode:
        kwargs["response_format"] = {"type": "json_object"}

    resp = client.chat.completions.create(**kwargs)
    return resp.choices[0].message.content


# ------------------------------------------------------------
# 构建系统提示词（餐厅文化 + 记忆逻辑约定）
# ------------------------------------------------------------
SYSTEM_PROMPT = """你是一家连锁餐厅的智能助手，负责为顾客提供菜品推荐和餐厅文化介绍。

你的职责：
1. 推荐菜品：根据顾客的口味、忌口、场景等推荐合适的菜品。
2. 介绍餐厅文化：介绍本餐厅的历史、理念、招牌特色等。
3. 回答与门店相关的问题（营业时间、地址、电话、停车等）。

回答要求：
- 优先基于【参考资料】里的内容回答，不要编造资料里没有的信息。
- 如果参考资料不足以回答，可以结合你的常识补充，但涉及本店具体信息（菜品价格、门店地址等）时必须以参考资料为准。
- 语气亲切、简洁、有条理。
- 用中文回答。
- 重要：请输出纯文本，不要使用任何 Markdown 格式符号，包括但不限于：不要用「-」或「*」作为列表前缀，不要用「**加粗**」「# 标题」等标记，不要用反引号。列表直接换行或用「1. 2. 3.」这样的数字序号即可。
"""

# 用于 JSON 输出的系统提示词（在推荐菜品时返回结构化数据）
SYSTEM_PROMPT_JSON = """你是一家连锁餐厅的智能助手。你需要用 JSON 格式回复，输出必须是合法的 json 对象。

你的输出必须是一个合法的 JSON 对象，格式如下：
{
  "reply": "给顾客看的纯文本回答（不要带 Markdown 符号，列表用 1. 2. 3.）",
  "dishes": [
    {"name": "菜名", "price": "价格数字"}
  ]
}

规则：
1. reply 字段：你对顾客说的话，纯文本。
2. dishes 字段：本次回复中你推荐到的菜品列表。每个元素包含 name（菜名）和 price（价格，纯数字字符串，不含"元"字）。只列出你在 reply 中明确推荐、且能在【参考资料】里找到的菜品。如果没有推荐具体菜品，dishes 就是空数组 []。
3. 价格必须从【参考资料】里抄，不能编造。
4. 菜名必须和参考资料里的完全一致。
"""

# 配菜专用系统提示词
SYSTEM_PROMPT_MEAL = """你是一家连锁餐厅的配菜助手。顾客想让你帮忙搭配一桌菜。

你的任务：根据顾客的人数、预算、口味偏好、忌口等，从【菜单清单】里挑选菜品，搭配出一桌合理的菜。

【菜单清单】列出了本店所有菜品及其精确价格，你只能从这里选菜，菜名和价格必须和清单完全一致，不能编造。

配菜要求：
1. 荤素搭配、冷热搭配、口味有层次，兼顾大众口味。
2. 预算控制：配菜总价可以在顾客指定预算的上下浮动 50 元（例如预算 800 元，总价在 750~850 元之间都算合理）。
3. 菜量要匹配人数（一般人均 1~2 道菜，含主食/汤）。
4. 如果顾客提到了忌口（如不吃辣、不吃香菜、不吃海鲜等），要避开相关菜品。

你需要用 JSON 格式回复，输出必须是合法的 json 对象，格式如下：
{
  "reply": "给顾客看的配菜说明（纯文本，列表用 1. 2. 3.，说明为什么这么配、总价）",
  "dishes": [
    {"name": "菜名", "price": "价格数字"}
  ],
  "total": 总价数字,
  "people": 人数
}

规则：
1. dishes 里列出你配的所有菜，name 和 price 必须来自【菜单清单】，不能编造。
2. total 是所有菜的价格之和（数字）。
3. people 是顾客用餐人数（如果顾客没说，就按合理人数估算）。
4. 所有价格必须从【菜单清单】里抄，绝不能自己编。
5. reply 里只需要说明总价，不要计算或提及人均金额。
"""


# ------------------------------------------------------------
# 判断用户是否在请求「配菜」
# ------------------------------------------------------------
def is_meal_planning(text):
    """粗略判断用户意图是否为配菜/点一桌菜"""
    keywords = ["配菜", "搭配一桌", "配一套", "帮我配", "点一桌", "搭配菜",
                "请客", "聚餐", "宴请", "配桌", "点菜方案", "按预算", "预算"]
    return any(k in text for k in keywords)


# ------------------------------------------------------------
# 对话接口
# ------------------------------------------------------------
@app.post("/api/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    user_msg = req.message.strip()
    if not user_msg:
        return ChatResponse(reply="请告诉我你想了解什么～", sources=[])

    # 0) 检测是否为「配菜」请求
    if is_meal_planning(user_msg):
        return await meal_planning(req, user_msg)

    # 1) 检索相关知识片段
    hits = vector_db.search(user_msg)

    # 2) 组装上下文（把知识片段拼进 prompt）
    context_text = ""
    sources = []
    if hits:
        context_text = "\n\n".join(
            f"【{h['category']}】{h['text']}" for h in hits
        )
        # 去重后的来源文件列表，用于前端展示
        seen = set()
        for h in hits:
            if h["source"] not in seen:
                seen.add(h["source"])
                sources.append({"category": h["category"], "source": h["source"]})

    # 3) 拼 messages（用 JSON 模式，让 AI 返回 reply + dishes）
    messages = [{"role": "system", "content": SYSTEM_PROMPT_JSON}]

    # 对话历史（最多保留最近 10 条，控制 token）
    for m in req.history[-10:]:
        messages.append({"role": m.get("role", "user"), "content": m.get("content", "")})

    if context_text:
        messages.append({
            "role": "user",
            "content": f"【参考资料】\n{context_text}\n\n【顾客问题】\n{user_msg}",
        })
    else:
        messages.append({"role": "user", "content": user_msg})

    # 4) 调用 DeepSeek（JSON 模式，失败时降级到普通模式）
    reply = ""
    dishes = []
    try:
        import json
        raw = call_deepseek(messages, json_mode=True)

        # 清理可能的 markdown 代码块包裹
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            # 去掉 ```json ... ``` 包裹
            cleaned = cleaned.strip("`")
            if cleaned.lower().startswith("json"):
                cleaned = cleaned[4:]
            cleaned = cleaned.strip()

        data = json.loads(cleaned)
        reply = data.get("reply", "")
        raw_dishes = data.get("dishes", [])
        if isinstance(raw_dishes, list):
            for d in raw_dishes:
                if isinstance(d, dict) and d.get("name"):
                    dishes.append({
                        "name": str(d["name"]).strip(),
                        "price": str(d.get("price", "")).strip(),
                    })
    except Exception as e:
        # JSON 解析失败：降级用普通模式再试一次，至少返回文字回答
        print(f"[警告] JSON 模式解析失败（{e}），降级为普通模式重试")
        try:
            # 用普通 SYSTEM_PROMPT 重试（不强制 JSON）
            fallback_messages = [{"role": "system", "content": SYSTEM_PROMPT}]
            for m in req.history[-10:]:
                fallback_messages.append({"role": m.get("role", "user"), "content": m.get("content", "")})
            if context_text:
                fallback_messages.append({
                    "role": "user",
                    "content": f"【参考资料】\n{context_text}\n\n【顾客问题】\n{user_msg}",
                })
            else:
                fallback_messages.append({"role": "user", "content": user_msg})
            reply = call_deepseek(fallback_messages)
        except Exception as e2:
            reply = f"抱歉，AI 服务暂时不可用，请稍后再试。（{e2}）"

    return ChatResponse(reply=reply, sources=sources, dishes=dishes)


# ------------------------------------------------------------
# 配菜功能
# ------------------------------------------------------------
async def meal_planning(req: ChatRequest, user_msg: str):
    """
    配菜流程：
    1. 从向量库读出全量菜单（含精确价格）
    2. 把菜单清单 + 用户需求塞给 DeepSeek（JSON 模式）
    3. 解析结果，校验总价（允许超 10%），超了重配一次
    4. 返回 reply + dishes + total + people
    """
    import json

    # 1) 读全量菜单
    menu = vector_db.get_full_menu()
    if not menu:
        return ChatResponse(reply="菜单数据为空，请先入库菜品。", is_meal=True)

    # 拼菜单清单文本
    menu_text_lines = []
    for m in menu:
        menu_text_lines.append(f"【{m['category']}】{m['name']}（{m['price']}元）")
    menu_text = "\n".join(menu_text_lines)

    # 1.5) 从向量库检索「ai点菜基本规则」分类的规则（动态加载，不硬编码）
    rules_text = ""
    try:
        rule_hits = vector_db.search("配菜规则 预算 食材搭配 组合", top_k=20, category="ai点菜基本规则")
        if rule_hits:
            rules_text = "\n".join(h["text"] for h in rule_hits)
    except Exception as e:
        print(f"[配菜] 检索规则失败（忽略）：{e}")

    # 2) 拼 messages
    messages = [{"role": "system", "content": SYSTEM_PROMPT_MEAL}]
    for m in req.history[-6:]:
        messages.append({"role": m.get("role", "user"), "content": m.get("content", "")})

    # 如果检索到规则，拼进用户消息
    content = f"【菜单清单】\n{menu_text}\n\n【顾客需求】\n{user_msg}"
    if rules_text:
        content = f"【配菜规则】\n{rules_text}\n\n{content}"
    messages.append({"role": "user", "content": content})

    # 3) 调用 DeepSeek（JSON 模式），最多尝试 2 次（预算超了重配）
    reply = ""
    dishes = []
    total = 0.0
    people = 0

    for attempt in range(2):
        try:
            raw = call_deepseek(messages, json_mode=True, max_tokens=2000, thinking_budget=1800, meal=True)
            cleaned = raw.strip()
            if cleaned.startswith("```"):
                cleaned = cleaned.strip("`")
                if cleaned.lower().startswith("json"):
                    cleaned = cleaned[4:]
                cleaned = cleaned.strip()

            data = json.loads(cleaned)
            reply = data.get("reply", "")
            raw_dishes = data.get("dishes", [])
            dishes = []
            if isinstance(raw_dishes, list):
                for d in raw_dishes:
                    if isinstance(d, dict) and d.get("name"):
                        dishes.append({
                            "name": str(d["name"]).strip(),
                            "price": str(d.get("price", "")).strip(),
                        })
            total = float(data.get("total", 0) or 0)
            people = int(data.get("people", 0) or 0)

            # 校验总价是否与 dishes 相加一致（允许 AI 的 total 与真实和有小误差，以真实和为准）
            real_total = sum(float(d["price"]) for d in dishes if d["price"])
            if abs(real_total - total) > 1:
                total = real_total  # 用真实加总，避免 AI 算错

            # 预算校验：从 user_msg 里提取预算数字（如果有）
            import re as _re
            budget_match = _re.search(r"(\d+)\s*(?:元|块|左右|以内|以内预算|预算)", user_msg)
            if budget_match:
                budget = float(budget_match.group(1))
                if total > budget * 1.1 and attempt == 0:
                    # 超预算超 10%，重配一次，并提示 AI
                    messages.append({
                        "role": "user",
                        "content": f"你配的总价 {total} 元超过预算 {budget} 元太多了，请重新配，控制在预算 ±10% 以内。",
                    })
                    continue
            break  # 成功或不需要重配

        except Exception as e:
            print(f"[配菜] 第 {attempt+1} 次调用失败：{e}")
            if attempt == 0:
                continue
            reply = f"抱歉，配菜服务暂时不可用，请稍后再试。（{e}）"

    # 5) 兜底：如果 AI 返回了文字说明，但 dishes 清单为空，
    #    尝试从 reply 文字里反解析菜名，用全量菜单比对补全 dishes
    if reply and not dishes:
        import re as _re2
        # 用全量菜单里的菜名，检查哪些菜名出现在 reply 文字里
        for m in menu:
            name = m["name"]
            if name and name in reply:
                dishes.append({
                    "name": name,
                    "price": m["price"],
                })
        # 去重（按菜名）
        seen_names = set()
        deduped = []
        for d in dishes:
            if d["name"] not in seen_names:
                seen_names.add(d["name"])
                deduped.append(d)
        dishes = deduped

        # 重新计算总价
        if dishes:
            total = sum(float(d["price"]) for d in dishes if d["price"])
            print(f"[配菜兜底] 从 reply 反解析出 {len(dishes)} 道菜，总价 {total}")

    return ChatResponse(
        reply=reply,
        sources=[],
        dishes=dishes,
        total=total,
        people=people,
        is_meal=True,
    )


# ------------------------------------------------------------
# 就近门店推荐接口（预留：读取用户位置）
# ------------------------------------------------------------
class LocationRequest(BaseModel):
    lng: float
    lat: float


@app.post("/api/nearest")
async def nearest(loc: LocationRequest):
    branch = find_nearest_branch(loc.lng, loc.lat)
    return {"branch": branch}


# ------------------------------------------------------------
# 向量库状态接口（调试用）
# ------------------------------------------------------------
@app.get("/api/stats")
async def stats():
    return vector_db.stats()


# ------------------------------------------------------------
# 静态托管：让网页能通过后端访问（可选）
# ------------------------------------------------------------
app.mount("/", StaticFiles(directory=str(config.BASE_DIR / "web"), html=True), name="web")


# ------------------------------------------------------------
# 启动入口
# ------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    # 启动前先确保向量库模型已加载（预热）
    print("=" * 50)
    print("餐厅 AI 助手后端启动中……")
    print("=" * 50)
    vector_db.get_collection()

    uvicorn.run(app, host=config.SERVER_HOST, port=config.SERVER_PORT)
