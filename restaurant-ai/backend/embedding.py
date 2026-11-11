# ============================================================
# embedding.py —— 把「千问 0.6B 向量化模型」封装成 Chroma 可用的 EmbeddingFunction
#
# 核心思路：
#   Chroma 本身不带模型，它通过一个「EmbeddingFunction」接口
#   调用外部模型来生成向量。这里我们实现这个接口，
#   在内部用 transformers 加载你本机的 Qwen3-Embedding-0.6B。
#
# 参考：Chroma 官方 cookbook「Bring your own embeddings」，
#       以及 Qwen3-Embedding 官方 README 的 transformers 用法。
# ============================================================

import torch
import torch.nn.functional as F
from transformers import AutoTokenizer, AutoModel

from chromadb import Documents, EmbeddingFunction, Embeddings

import config


# ------------------------------------------------------------
# 官方推荐的「取最后一个 token」池化函数
# Qwen3-Embedding 是解码器式模型，标准做法是取每个样本
# 最后一个有效 token 的隐向量，而不是做 mean pooling。
# 这段代码直接来自 Qwen3-Embedding 官方 README。
# ------------------------------------------------------------
def last_token_pool(last_hidden_states, attention_mask):
    # left_padding：判断是否做了左填充（我们下面 padding_side="left"）
    left_padding = (attention_mask[:, -1].sum() == attention_mask.shape[0])
    if left_padding:
        # 左填充时，最后一个 token 就是序列末尾 token
        return last_hidden_states[:, -1]
    else:
        # 右填充时，需要根据 attention_mask 找到每个样本真正的最后一个 token
        sequence_lengths = attention_mask.sum(dim=1) - 1
        batch_size = last_hidden_states.shape[0]
        return last_hidden_states[
            torch.arange(batch_size, device=last_hidden_states.device),
            sequence_lengths,
        ]


# ------------------------------------------------------------
# 为「查询句」加指令前缀
# 官方说明：检索类任务给查询句加 instruct 前缀，效果可提升 1%~5%
# ------------------------------------------------------------
def get_query_instruct(query: str) -> str:
    task = "Given a restaurant-related question, retrieve relevant passages that answer the question"
    return f"Instruct: {task}\nQuery: {query}"


# ------------------------------------------------------------
# 自定义 EmbeddingFunction
# 继承 Chroma 的 EmbeddingFunction，实现 __call__ 即可
# ------------------------------------------------------------
class QwenEmbeddingFunction(EmbeddingFunction[Documents]):
    def __init__(self, model_dir: str = None):
        """
        model_dir: 千问模型在本机的目录路径
        """
        model_dir = model_dir or config.QWEN_EMBEDDING_MODEL_DIR

        # 用 transformers 从本地目录离线加载（不联网）
        # padding_side="left" 是官方对 Qwen3-Embedding 的要求
        self._tokenizer = AutoTokenizer.from_pretrained(model_dir, padding_side="left")
        self._model = AutoModel.from_pretrained(model_dir)
        self._model.eval()

        # 记录向量维度（0.6B 是 1024 维），供外部查询用
        self.dim = self._model.config.hidden_size

        # 决定在 CPU 还是 GPU 上跑
        self._device = "cuda" if torch.cuda.is_available() else "cpu"
        self._model.to(self._device)

    def _embed(self, texts):
        """把一批文本变成归一化后的向量（numpy 二维数组）"""
        enc = self._tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=2048,
            return_tensors="pt",
        )
        # 把输入搬到和模型一致的设备上
        enc = {k: v.to(self._device) for k, v in enc.items()}

        with torch.no_grad():
            out = self._model(**enc)

        # 取最后一个 token 的隐向量
        last = last_token_pool(out.last_hidden_state, enc["attention_mask"])
        # L2 归一化成单位向量（余弦相似度 = 点积）
        last = F.normalize(last, p=2, dim=1)

        # 转成 float32 再转 numpy（CPU 上模型可能输出 BFloat16，Chroma 只接受 float32）
        return last.cpu().float().numpy()

    def __call__(self, input: Documents) -> Embeddings:
        """
        Chroma 调用这个方法获取向量。
        注意：入库的「文档」不加指令前缀；查询时会单独走 query 方法。
        Chroma 在 query 时会用同一个 embedding_function 处理查询文本，
        所以这里对文档直接向量化即可。
        """
        vectors = self._embed(list(input))
        # Chroma 要求返回 list[list[float]]
        return [v.tolist() for v in vectors]

    # 提供一个额外方法，供检索时对「查询句」加指令前缀再向量化
    def embed_query(self, query: str):
        return self._embed([get_query_instruct(query)])[0]
