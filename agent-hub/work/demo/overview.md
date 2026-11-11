# D:\demo 项目概览

这是一个位于 `D:\demo` 的文档向量化与相似度检索示例：`main.py` 为主流程，执行“解析文档 → 抽样 → 向量化 → 存盘 → 相似度检索”。`download_model.py` 是前置步骤，先从 ModelScope 下载 `Qwen3-Embedding-0.6B` 模型到本地，供 `main.py` 通过 `transformers` 离线加载。目录内还包含 `restaurant-ai` 餐厅 AI 点菜应用与 `agent-hub` 多 Codex 协作调度中心。

## 目录 / 作用 / 是否要动

| 目录 | 作用 | 是否要动 |
| --- | --- | --- |
| `.git` | Git 版本库元数据 | 否 |
| `.idea` | JetBrains IDE 项目配置 | 否 |
| `.venv` | Python 虚拟环境 | 否 |
| `models` | 本地模型目录，存放下载的 `Qwen3-Embedding-0.6B` | 否 |
| `out` | 空目录，暂无内容 | 否 |
| `output` | 运行输出：`docs.json`、`vectors.npy` | 否（运行生成） |
| `agent-hub` | 多 Codex 协作调度中心（任务/日志/各 worker home） | 否 |
| `restaurant-ai` | 餐厅 AI 点菜项目（后端、前端、Chroma 向量库） | 否 |
| `main.py` | 文档向量化 + 相似度检索主流程 | 是（代码入口） |
| `download_model.py` | 下载模型的前置步骤 | 是（代码入口） |

## 需要人工确认

- 盘符不一致：`facts.md` 记为 `D:\demo\models`、`D:\demo\output`，而 `entry.md` 的 `MODEL_DIR`/`OUT_DIR` 为 `E:\demo\models\Qwen3-Embedding-0.6B`、`E:\demo\output`，需确认实际盘符。
- 源文档路径：`entry.md` 的 `DOC_PATH` 为 `E:\embedding_practice\company_docs.txt`，位于 `D:\demo` 之外，也需一并确认。