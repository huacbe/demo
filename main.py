# ============================================================
# 第 0 步：先说清楚这个脚本要干什么
#   1) 读入 company_docs.txt（50 份公司文档）
#   2) 随机抽 10 份
#   3) 用 ModelScope 上的 Qwen3-Embedding-0.6B 把每份文档变成向量
#   4) 存盘，并做一次相似度检索，验证向量真的“懂语义”
# ============================================================

import os
import json
import random
import numpy as np

# ============================================================
# 第 1 步：配置路径
#   文档就是你现在记事本里打开的那份 company_docs.txt
#   模型稍后从 ModelScope 下载到项目目录下
# ============================================================

DOC_PATH = r"E:\embedding_practice\company_docs.txt"
MODEL_DIR = r"E:\demo\models\Qwen3-Embedding-0.6B"
OUT_DIR = r"E:\demo\output"
SEED = 42

# ============================================================
# 第 2 步：把文件拆成一份份文档
#   每份文档长这样：
#     文档编号：01
#     文档类型：会议纪要
#     文档标题：xxx
#     ##########################   ← 一行 # 号当分隔线
#     正文……
#   最稳的拆法：逐行扫描，遇到“文档编号：”就开一份新文档
# ============================================================

def parse_docs(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()

    docs, cur = [], None
    for line in lines:
        s = line.strip()
        if s.startswith("文档编号："):
            if cur:
                docs.append(cur)
            cur = {"id": s.split("：", 1)[1], "type": "", "title": "", "body": []}
        elif cur is None:
            continue                       # 文件开头的说明文字，跳过
        elif s.startswith("文档类型："):
            cur["type"] = s.split("：", 1)[1]
        elif s.startswith("文档标题："):
            cur["title"] = s.split("：", 1)[1]
        elif s and set(s) == {"#"}:
            continue                       # 纯 # 号的分隔线，跳过
        elif s:
            cur["body"].append(s)

    if cur:
        docs.append(cur)

    for d in docs:
        d["text"] = "\n".join(d["body"])
        del d["body"]
    return docs

# ============================================================
# 第 3 步：解析文件，然后随机抽 10 份
#   seed 固定，保证每次运行抽到的是同样的 10 份，方便复现
# ============================================================

docs = parse_docs(DOC_PATH)
print(f"文件里一共解析到 {len(docs)} 份文档")

random.seed(SEED)
sample = random.sample(docs, 10)
sample.sort(key=lambda d: d["id"])

print("\n本次抽中的 10 份文档：")
for d in sample:
    print(f"  [{d['id']}] {d['type']} | {d['title']}")

# ============================================================
# 第 4 步：加载 Qwen3-Embedding-0.6B
#   权重已经用 ModelScope 下到 MODEL_DIR，
#   这里用 transformers 从本地目录读，不走网络
# ============================================================

import torch
from transformers import AutoTokenizer, AutoModel

print("\n正在加载模型……")
tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR, padding_side="left")
model = AutoModel.from_pretrained(MODEL_DIR, dtype=torch.float32)
model.eval()

n_param = sum(p.numel() for p in model.parameters()) / 1e6
print(f"模型加载完成，参数量约 {n_param:.1f}M，向量维度 {model.config.hidden_size}")

# ============================================================
# 第 5 步：核心函数——把文本变成向量
#   Qwen3-Embedding 是“解码器式”模型，标准做法是：
#     文本 → token → 过模型 → 取【最后一个 token】的输出 → L2 归一化
# ============================================================

def embed(texts, batch_size=4, max_length=2048):
    all_vecs = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        enc = tokenizer(batch, padding=True, truncation=True,
                        max_length=max_length, return_tensors="pt")
        with torch.no_grad():
            out = model(**enc)
        last = out.last_hidden_state[:, -1]                      # 每个样本的最后一个 token
        last = torch.nn.functional.normalize(last, p=2, dim=1)   # 归一化成单位向量
        all_vecs.append(last.cpu().numpy())
    return np.vstack(all_vecs)

# ============================================================
# 第 6 步：对这 10 份文档做向量化
#   送进模型的文本 = 类型 + 标题 + 正文
#   把标题带上，能让向量更贴近“这份文档讲什么”
# ============================================================

texts = [f"{d['type']} | {d['title']}\n{d['text']}" for d in sample]
vectors = embed(texts)

print("\n向量矩阵形状：", vectors.shape)
print("每行的 L2 范数：", np.linalg.norm(vectors, axis=1).round(4))
print("\n第 1 条文档向量的前 8 维：")
print(vectors[0][:8].round(4))

# ============================================================
# 第 7 步：存盘
#   vectors.npy 只存矩阵，docs.json 存原文和元信息，
#   两者按行号一一对应：第 i 行向量 ↔ docs.json 第 i 条
# ============================================================

os.makedirs(OUT_DIR, exist_ok=True)
np.save(os.path.join(OUT_DIR, "vectors.npy"), vectors)
with open(os.path.join(OUT_DIR, "docs.json"), "w", encoding="utf-8") as f:
    json.dump(sample, f, ensure_ascii=False, indent=2)
print(f"\n已写入 {OUT_DIR}\\vectors.npy 与 docs.json")

# ============================================================
# 第 8 步：相似度矩阵
#   向量都归一化过，长度都是 1，
#   所以 A @ A.T 算出来的就是两两之间的余弦相似度
#   对角线恒为 1.0（自己和自己的相似度）
# ============================================================

sim = vectors @ vectors.T
print("\n10 × 10 余弦相似度矩阵：")
print(np.round(sim, 3))

# ============================================================
# 第 9 步：语义检索演示
#   用一句“问题”去和 10 份文档向量比相似度，看谁排前面
#   Qwen3-Embedding 建议查询句加指令前缀，这里先不加，直接看基础效果
# ============================================================

query = "数据看板什么时候能上线？"
q_vec = embed([query])[0]
scores = vectors @ q_vec
order = np.argsort(-scores)[:3]

print(f"\n查询：{query}")
for rank, idx in enumerate(order, 1):
    d = sample[idx]
    print(f"  Top{rank}  相似度={scores[idx]:.4f}  [{d['id']}] {d['title']}")

print("\n全部跑通。")
