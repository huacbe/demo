import pathlib

import vector_db


def main():
    col = vector_db.get_collection()
    try:
        col.delete(where={"source": "配菜规则.md"})
        print("已删除旧规则片段")
    except Exception as e:
        print("删除旧规则失败（忽略）:", e)

    f = vector_db.config.KNOWLEDGE_DIR / "ai点菜基本规则" / "配菜规则.md"
    n = vector_db.ingest_file(pathlib.Path(f), "ai点菜基本规则")
    print("重新入库片段数:", n)
    print("stats:", vector_db.stats())


if __name__ == "__main__":
    main()
