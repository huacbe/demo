# ============================================================
# vector_db.py —— 向量知识库的核心封装（基于 Chroma）
#
# 提供：
#   1. get_db()          —— 获取/初始化向量库（单例）
#   2. ingest_file()     —— 把单个知识文件切块后写入向量库
#   3. ingest_directory()—— 批量把 knowledge/ 目录下所有文件写入
#   4. search()          —— 语义检索，返回最相关的知识片段
#   5. stats()           —— 查看库里有多少条数据
# ============================================================

import chromadb

import config
from embedding import QwenEmbeddingFunction


# ------------------------------------------------------------
# 全局单例：模型加载很慢，只加载一次
# ------------------------------------------------------------
_ef = None
_collection = None


def get_embedding_function():
    """获取（并缓存）千问 embedding 函数"""
    global _ef
    if _ef is None:
        print("正在加载 Qwen3-Embedding-0.6B 模型……（首次较慢，请耐心等待）")
        _ef = QwenEmbeddingFunction(config.QWEN_EMBEDDING_MODEL_DIR)
        print(f"模型加载完成，向量维度 = {_ef.dim}")
    return _ef


def get_collection():
    """获取（并缓存）Chroma 集合"""
    global _collection
    if _collection is None:
        # 用 PersistentClient 让数据落盘，下次启动不用重新灌
        client = chromadb.PersistentClient(path=str(config.CHROMA_DATA_DIR))
        ef = get_embedding_function()
        _collection = client.get_or_create_collection(
            name=config.COLLECTION_NAME,
            embedding_function=ef,
            # 用余弦相似度（因为向量已 L2 归一化，余弦=点积）
            metadata={"hnsw:space": "cosine"},
        )
    return _collection


# ------------------------------------------------------------
# 文本切块
# 因为模型有最大长度限制，长文档要切成小段再入库。
# 这里按「固定字数 + 少量重叠」切块，重叠可减少语义断裂。
# ------------------------------------------------------------
def split_text(text, chunk_size=300, overlap=30):
    """把长文本切成若干小块，返回块列表"""
    chunks = []
    start = 0
    n = len(text)
    while start < n:
        end = start + chunk_size
        chunks.append(text[start:end])
        if end >= n:
            break
        start = end - overlap  # 有 overlap，让上下文连续
    return chunks


# ------------------------------------------------------------
# 按「分类标题 + 每道菜」的格式拆分（支持两种格式）
#
# 格式一（txt）：
#   （旺火明炉）
#   黄焖爆炒鳝鱼（88）：描述……
#   大骨有机鱼（68）：描述……
#
# 格式二（Markdown）：
#   ## 旺火明炉
#   ### 黄焖爆炒鳝鱼（88元）
#   描述……
#   ### 大骨有机鱼（68元）
#   描述……
#
# 拆分后：每道菜独立成片段，带上所属分类，便于检索定位
# ------------------------------------------------------------
def split_text_by_menu(lines):
    """
    lines: 文本按行拆成的列表
    返回：[(分类名, 菜品文本), ...]
    """
    items = []
    current_category = ""
    current_dish_name = None   # 当前菜名（Markdown ### 标题）
    current_dish_lines = []    # 当前菜的描述行

    def flush_dish():
        """把当前积累的一道菜输出"""
        nonlocal current_dish_name, current_dish_lines
        if current_dish_name is not None:
            # 菜名 + 描述合并成一条
            desc = " ".join(current_dish_lines).strip()
            if desc:
                dish_text = f"{current_dish_name}：{desc}"
            else:
                dish_text = current_dish_name
            items.append((current_category, dish_text))
            current_dish_name = None
            current_dish_lines = []

    for line in lines:
        s = line.strip()
        if not s:
            continue

        # 跳过 Markdown 引用块（> 说明文字）
        if s.startswith(">"):
            continue

        # Markdown 分类标题：## xxx
        if s.startswith("## "):
            flush_dish()  # 先输出上一道菜
            current_category = s[3:].strip()
            continue
        # 跳过一级标题 # xxx
        if s.startswith("# ") and not s.startswith("##"):
            continue

        # Markdown 菜名标题：### xxx
        if s.startswith("### "):
            flush_dish()  # 先输出上一道菜
            current_dish_name = s[4:].strip()
            current_dish_lines = []
            continue

        # txt 格式分类标题：（xxx）
        if s.startswith("（") and s.endswith("）"):
            flush_dish()
            current_category = s.strip("（）")
            continue

        # txt 格式：一道菜一行（含「菜名（价格）：描述」）
        # 如果当前不在 Markdown 菜名模式下（没有 current_dish_name），
        # 则这一行本身就是一道菜
        if current_dish_name is not None:
            # Markdown 模式下，这一行是当前菜的描述
            current_dish_lines.append(s)
        elif current_category:
            # txt 模式下，这一行就是一道菜
            items.append((current_category, s))
        # 没有分类的普通行（说明文字等）直接忽略，不入库

    # 输出最后一道菜
    flush_dish()
    return items


# ------------------------------------------------------------
# 单个文件入库
# ------------------------------------------------------------
def ingest_file(file_path, category):
    """
    file_path: 知识文件路径
    category : 分类标签（如 "菜品"/"分店"/"FAQ"），来自所在子文件夹名
    """
    col = get_collection()

    # 读取文件内容
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read().strip()
    if not content:
        print(f"  [跳过] {file_path} 内容为空")
        return 0

    # 文件名（不含扩展名）作为文档标识
    doc_name = file_path.stem

    # 切块：判断是否为「菜单格式」
    # 菜单格式的特征：含（分类）标题行 或 Markdown 的 ### 菜名标题
    lines = content.split("\n")
    has_menu_header = any(
        (ln.strip().startswith("（") and ln.strip().endswith("）"))
        or ln.strip().startswith("### ")
        for ln in lines
    )

    if has_menu_header:
        # 菜单格式：按「分类 + 每道菜」拆分
        items = split_text_by_menu(lines)
        chunks = []
        metadatas = []
        ids = []
        for i, (cat, dish_text) in enumerate(items):
            # 片段文本 = 分类 + 菜品（带分类语义，检索更准）
            if cat:
                chunk_text = f"【{cat}】{dish_text}"
            else:
                chunk_text = dish_text
            chunks.append(chunk_text)
            ids.append(f"{doc_name}::{i}")
            metadatas.append({
                "category": category,
                "source": file_path.name,
                "chunk": i,
                "sub_category": cat,   # 记录菜品所属的菜单分类
            })
    else:
        # 普通格式：按字数切块
        chunks = split_text(content)
        ids = [f"{doc_name}::{i}" for i in range(len(chunks))]
        metadatas = [
            {
                "category": category,
                "source": file_path.name,
                "chunk": i,
            }
            for i in range(len(chunks))
        ]

    # upsert：已存在同 ID 就覆盖，避免重复
    col.upsert(ids=ids, documents=chunks, metadatas=metadatas)

    print(f"  [入库] {category}/{file_path.name} → {len(chunks)} 个片段")
    return len(chunks)


# ------------------------------------------------------------
# 批量入库：扫描 knowledge/ 目录
# ------------------------------------------------------------
def ingest_directory():
    """扫描 config.KNOWLEDGE_DIR，按子文件夹名作为分类标签入库"""
    if not config.KNOWLEDGE_DIR.exists():
        print(f"知识目录不存在：{config.KNOWLEDGE_DIR}")
        return 0

    total = 0
    # 遍历所有子文件夹
    for sub in config.KNOWLEDGE_DIR.iterdir():
        if not sub.is_dir():
            continue
        category = sub.name  # 子文件夹名 = 分类
        # 遍历子文件夹里的所有文本文件
        for f in sub.iterdir():
            if f.suffix.lower() in config.SUPPORTED_EXTENSIONS:
                total += ingest_file(f, category)
    return total


# ------------------------------------------------------------
# 语义检索
# ------------------------------------------------------------
def search(query, top_k=None, category=None):
    """
    query   : 用户问题
    top_k   : 返回几条（默认取 config.TOP_K）
    category: 可选，只检索某个分类（如 "菜品"）
    返回：[{text, category, source, score}, ...]
    """
    top_k = top_k or config.TOP_K
    col = get_collection()

    where = None
    if category:
        where = {"category": category}

    # Chroma 的 query 会用 embedding_function 处理 query_texts
    # 但这里我们需要对查询句加 instruct 前缀，所以用 query_embeddings 手动传入向量
    ef = get_embedding_function()
    q_vec = ef.embed_query(query)

    result = col.query(
        query_embeddings=[q_vec.tolist()],
        n_results=top_k,
        where=where,
        include=["documents", "metadatas", "distances"],
    )

    # 整理成友好结构
    results = []
    docs = result["documents"][0]
    metas = result["metadatas"][0]
    dists = result["distances"][0]

    for doc, meta, dist in zip(docs, metas, dists):
        # Chroma 的 distance（余弦距离）= 1 - 余弦相似度
        score = 1 - dist
        if score < config.SIMILARITY_THRESHOLD:
            continue  # 低于阈值的丢弃
        results.append({
            "text": doc,
            "category": meta.get("category", ""),
            "source": meta.get("source", ""),
            "score": round(score, 4),
        })

    return results


# ------------------------------------------------------------
# 查看库状态
# ------------------------------------------------------------
def stats():
    col = get_collection()
    return {
        "count": col.count(),
        "name": col.name,
    }


# ------------------------------------------------------------
# 获取全量菜单（用于「配菜」功能）
# 从向量库读出所有片段，解析出「分类 + 菜名 + 价格」结构
# ------------------------------------------------------------
def get_full_menu():
    """
    返回菜单列表，每项 {category, name, price}
    price 为字符串（如 "88"），解析失败则为 ""
    """
    import re
    col = get_collection()
    data = col.get(include=["documents", "metadatas"])

    menu = []
    for doc, meta in zip(data["documents"], data["metadatas"]):
        # doc 形如：【旺火明炉】黄焖爆炒鳝鱼（88）：描述...
        sub_cat = meta.get("sub_category", "")
        # 解析菜名和价格：取「】」之后到第一个「（」之前是菜名，括号里是价格
        m = re.match(r"【(.*?)】(.*?)（(\d+)）", doc)
        if m:
            cat = m.group(1)
            name = m.group(2).strip()
            price = m.group(3)
            menu.append({
                "category": cat,
                "name": name,
                "price": price,
            })
        else:
            # 解析失败的兜底：整段存为 name，价格空
            menu.append({
                "category": sub_cat,
                "name": doc,
                "price": "",
            })

    return menu
