# agent-hub（D:\demo 工作区）

把 DSH 与 Codex 组织成一条能**在同一个文件夹里同时干活**的流水线。

```
DSH 会话（拆活 + 验收）
  └→ run-task.ps1   校验 owns → 分批 → 备份 → 并发拉起 → 收结果 → 查越界
       └→ Codex #1 / #2 / #3（独立进程 + 独立 CODEX_HOME）
            └→ runs/<时间戳>-<任务>/<子任务>/  prompt、stdout、stderr、last-message、backup
```

## 先自检

```powershell
cd D:\demo\agent-hub
pwsh -File .\Test-HubPrereqs.ps1          # 8 项条件逐条体检
pwsh -File .\Test-HubPrereqs.ps1 -Full    # 额外做一次双路并发实测（消耗 token）
```

当前结果：**PASS 8 / WARN 0 / FAIL 0**。

## 跑任务

```powershell
pwsh -File .\run-task.ps1 -TaskFile .\tasks\demo-two-workers.json -DryRun
pwsh -File .\run-task.ps1 -TaskFile .\tasks\demo-two-workers.json -MaxParallel 3 -StrictOwns
```

- `-StrictOwns`：越界写入直接判失败（默认只告警）。
- `-NoBackup`：跳过备份（默认会把 `owns` 范围内已存在的文件复制到 `runs\<run>\<id>\backup`）。

## 任务文件新增字段 `owns`

```json
{
  "name": "demo-two-workers",
  "workDir": "D:\\demo\\agent-hub\\work\\demo",
  "subtasks": [
    { "id": "facts", "agent": "codex", "dependsOn": [], "owns": ["facts.md"], "prompt": "…" },
    { "id": "entry", "agent": "codex", "dependsOn": [], "owns": ["entry.md"], "prompt": "…" },
    { "id": "merge", "agent": "codex", "dependsOn": ["facts","entry"], "owns": ["overview.md"], "prompt": "…" }
  ]
}
```

`owns` 干三件事：

1. **同批互斥**：两个子任务写入范围重叠（含父目录/通配符前缀）→ 不并行，自动顺延到下一批。
2. **写进提示词**：Agent 会收到「你只允许写这些路径，其他只读」的硬约束。
3. **跑完对账**：对该子任务时间窗内的文件快照做 diff，列出不在 `owns` 内、也没有被同批兄弟任务声明的写入。

## 与 DSH 并行时的规矩

- DSH 的 `pwsh` 调用是串行的，要和 Codex 真并行，必须把 Codex 放 `run_in_background`。
- 同一文件同时只能有一个写入者；合并统一交给最后一棒（如 `merge`）。
- 判定完成看**退出码 + last-message.txt**，不要看文件大小。
- 回滚有两条路：`git`（PortableGit 2.56.0 已装到 `C:\Users\admin\Programs\PortableGit`，仓库在 `D:\demo`，基线提交 `3a6d75c`）和 `runs\<run>\<id>\backup` 里的定向副本。

## 已知局限

- 越界检测只能发现「谁都没声明」的写入；两个 Agent 互相写对方 `owns` 里的文件无法归因（窗口重叠，文件系统不提供 per-process 记录）。
- Codex 每个进程约 9.4k tokens 起跳，两路并行 ≈ 双倍。
- `codex exec` 偶发静默挂起（stdout/stderr 全空），判断方法：`runs\<run>\<id>\stdout.log` 为 0 字节即重跑。

## 屏幕顶部状态条（HUD）

任务一启动，屏幕最上方会出现一条黑色状态条，实时显示**一共几个 Agent、每个在干什么**：

```
多 AI 协作  ● 共 3 个 Agent · 运行中 2 · 完成 0
             ● facts 46s   执行 · Get-ChildItem -Recurse
             ● entry 46s   输出 · 已完成，已创建 entry.md
             ● merge       排队中
```

- 数据源：`state\live.json`（`run-task.ps1` 每阶段写入一次，临时文件 + 原子替换）。
- 「正在干什么」：HUD 自己 tail 各 worker 的 `runs\<run>\<id>\stdout.log`，解析 Codex `--json` 的 JSONL 事件——`command_execution` → 执行某命令，`agent_message` → 输出的结论，`reasoning` → 思考中，`file_change` → 改文件。
- 颜色：绿=运行中，蓝=完成，红=失败，灰=排队中/跳过。
- 关闭：Esc 或右上角 `×`；`run-task.ps1 -NoHud` 可整场不弹。
- 任务结束后状态条显示「已结束」，6 秒后自动消失；全局互斥体保证同一时刻只有一个窗口。
- 想单独开着看（没在跑任务时）：`.\Start-Hud.ps1`，会显示「共 0 个 Agent」的空闲态。

### 相关文件

| 文件 | 作用 |
| --- | --- |
| `lib\hud.ps1` | 状态条本体（WPF 无边框置顶窗口，600ms 刷新） |
| `Start-Hud.ps1` | 手动打开状态条 |
| `state\live.json` | 运行时状态（自动生成，可删） |
