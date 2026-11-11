# 项目入口说明

## 入口
- 主入口：`D:\demo\main.py`，运行即执行完整流程（解析文档 → 抽样 → 向量化 → 存盘 → 相似度检索）。
- 前置步骤：`D:\demo\download_model.py`，先从 ModelScope 下载模型到本地，需在跑 `main.py` 前执行一次。

## 启动参数
- 两个脚本都不接收命令行参数，配置全部硬编码在 `main.py` 顶部：
  - `DOC_PATH`：源文档 `E:\embedding_practice\company_docs.txt`
  - `MODEL_DIR`：本地模型目录 `E:\demo\models\Qwen3-Embedding-0.6B`
  - `OUT_DIR`：输出目录 `E:\demo\output`
  - `SEED`：随机种子 `42`

## 依赖的模型文件
- 模型：`Qwen3-Embedding-0.6B`（ModelScope 仓库 `Qwen/Qwen3-Embedding-0.6B`）。
- 下载位置：`E:\demo\models\Qwen3-Embedding-0.6B`，`main.py` 用 `transformers` 从该本地目录离线加载。
- Python 依赖：`torch`、`numpy`、`transformers`、`modelscope`。
