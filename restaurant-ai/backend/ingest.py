# ============================================================
# ingest.py —— 一键把知识目录里的文档灌入向量库
#
# 用法：
#   python ingest.py
#
# 之后你随时往 knowledge/ 下新增文件，重新运行本脚本即可增量更新
# （同名文件会覆盖，新文件会追加）。
# ============================================================

import vector_db


def main():
    print("=" * 50)
    print("开始构建向量知识库……")
    print(f"知识目录：{vector_db.config.KNOWLEDGE_DIR}")
    print("=" * 50)

    total = vector_db.ingest_directory()

    print("=" * 50)
    print(f"完成！共入库 {total} 个知识片段")
    st = vector_db.stats()
    print(f"当前向量库总计：{st['count']} 个片段")
    print("=" * 50)


if __name__ == "__main__":
    main()
