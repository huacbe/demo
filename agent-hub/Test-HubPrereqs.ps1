# Test-HubPrereqs.ps1 —— 逐条检查「两个 Agent 同时操作同一个文件夹」的 8 个条件
#
#   pwsh -File Test-HubPrereqs.ps1            # 只检查
#   pwsh -File Test-HubPrereqs.ps1 -Fix       # 检查并修复可自动修复的项
#   pwsh -File Test-HubPrereqs.ps1 -Full      # 额外跑一次双路并发实测（会消耗 token）
#
# 退出码：0 = 全部 PASS/WARN，1 = 有 FAIL

[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$hub = $PSScriptRoot
$ws = Split-Path $hub -Parent
. (Join-Path $hub 'lib\hub.ps1')

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row($no, $name, $status, $detail) {
    $rows.Add([pscustomobject]@{ 序号 = $no; 条件 = $name; 结果 = $status; 说明 = $detail })
}

# 1. 目录归属与可写性
$probe = Join-Path $hub '.write-probe'
try {
    Set-Content $probe 'ok' -Encoding utf8
    Remove-Item $probe -Force
    $writable = $true
} catch { $writable = $false }
if ($writable -and (Test-Path $ws)) {
    Add-Row 1 '目标目录在工作区内且可写' 'PASS' "工作区 $ws，hub $hub"
} else {
    Add-Row 1 '目标目录在工作区内且可写' 'FAIL' "不可写或工作区不存在：$ws"
}

# 2. 后台并行能力（能否不阻塞地拉起进程）
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath (Get-HubPwshExe) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 3' -PassThru -WindowStyle Hidden
$launchMs = $sw.ElapsedMilliseconds
if ($p -and -not $p.HasExited -and $launchMs -lt 1500) {
    Add-Row 2 '进程可后台并行拉起' 'PASS' "启动耗时 ${launchMs}ms，子进程未阻塞（PID $($p.Id)）"
} else {
    Add-Row 2 '进程可后台并行拉起' 'FAIL' "启动耗时 ${launchMs}ms"
}
try { $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue } catch {}

# 3. 每个子任务都声明了 owns（写入边界）
$bad = @()
foreach ($tf in Get-ChildItem (Join-Path $hub 'tasks') -Filter *.json -ErrorAction SilentlyContinue) {
    try { $j = Get-Content $tf.FullName -Raw -Encoding utf8 | ConvertFrom-Json } catch { continue }
    foreach ($s in @($j.subtasks)) {
        if (-not $s.owns) { $bad += "$($tf.BaseName):$($s.id)" }
    }
}
if ($bad.Count -eq 0) {
    Add-Row 3 '子任务声明写入边界 owns' 'PASS' '全部任务文件都已声明'
} elseif ($Fix) {
    Add-Row 3 '子任务声明写入边界 owns' 'WARN' "有 $($bad.Count) 个未声明，需手工补：$($bad -join ', ')"
} else {
    Add-Row 3 '子任务声明写入边界 owns' 'WARN' "有 $($bad.Count) 个未声明：$($bad -join ', ')"
}

# 4. 每个 Codex 进程独立 CODEX_HOME
$s1 = Initialize-CodexHome -Path (Join-Path $hub 'codex-home\probe-a')
$s2 = Initialize-CodexHome -Path (Join-Path $hub 'codex-home\probe-b')
if ($s1 -ne $s2 -and (Test-Path $s1) -and (Test-Path $s2)) {
    Add-Row 4 'Codex 之间 CODEX_HOME 隔离' 'PASS' "$(Split-Path $s1 -Leaf) / $(Split-Path $s2 -Leaf)"
} else {
    Add-Row 4 'Codex 之间 CODEX_HOME 隔离' 'FAIL' "两个 slot 指向同一目录：$s1"
}

# 5. 完成信号基于退出码 + 最终答复文件
$hubSrc = (Get-Content (Join-Path $hub 'lib\hub.ps1') -Raw) + (Get-Content (Join-Path $hub 'lib\codex-worker.ps1') -Raw)
$hasLast = $hubSrc -match 'output-last-message' -and $hubSrc -match 'ExitCode'
if ($hasLast) {
    Add-Row 5 '以退出码/最终答复判定完成' 'PASS' 'Wait-CodexWorker 返回 ExitCode + LastMessage，不看文件大小'
} else {
    Add-Row 5 '以退出码/最终答复判定完成' 'FAIL' 'hub.ps1 缺少 last-message/ExitCode 逻辑'
}

# 6. 扫描排除 runs/ 与 codex-home/
$cfgPath = Join-Path $hub 'hub.config.json'
$excOk = $false
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json
    $exc = @($cfg.scanExclude)
    $excOk = (@($exc | Where-Object { $_ -match 'runs' }).Count -gt 0) -and (@($exc | Where-Object { $_ -match 'codex-home' }).Count -gt 0)
}
if ($excOk) {
    Add-Row 6 '扫描/清理排除 runs 与 codex-home' 'PASS' ($exc -join ', ')
} else {
    Add-Row 6 '扫描/清理排除 runs 与 codex-home' 'FAIL' 'hub.config.json 缺失或不含排除项'
}

# 7. 回滚能力（本机无 git，用定向备份代替）
$rt = Get-Content (Join-Path $hub 'run-task.ps1') -Raw
$hasBackup = $rt -match 'Backup-OwnedFiles'
$gitExe = Get-HubGitExe
if ($hasBackup) {
    if ($gitExe) {
        $ver = (& $gitExe --version)
        $repo = Test-Path (Join-Path $ws '.git')
        $detail = "$ver；仓库：$(if ($repo) { '已 git init' } else { '未初始化' })；另有定向备份"
        Add-Row 7 '改坏可回滚' 'PASS' $detail
    } else {
        Add-Row 7 '改坏可回滚' 'PASS' '定向备份（runs\<run>\<id>\backup）；未找到 git'
    }
} else {
    Add-Row 7 '改坏可回滚' 'FAIL' 'run-task.ps1 缺少 Backup-OwnedFiles'
}

# 8. API 并发
$key = Get-HubCodexKey
if (-not $key) {
    Add-Row 8 'Codex API 可用且支持并发' 'FAIL' '未从 ~/.codex/config.toml 读到 token'
} elseif ($Full) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $jobs = 1..2 | ForEach-Object {
        Invoke-CodexAgent -Prompt "只回复一个数字：$PSItem" -WorkDir $ws -TimeoutSec 180
    }
    $ok = @($jobs | Where-Object Ok).Count
    Add-Row 8 'Codex API 可用且支持并发' ($(if ($ok -eq 2) { 'PASS' } else { 'FAIL' })) "双路并发 $([math]::Round($sw.Elapsed.TotalSeconds,1))s，成功 $ok/2"
} else {
    Add-Row 8 'Codex API 可用且支持并发' 'PASS' '已读到 token；双路并发实测需加 -Full'
}

# ---------- 输出 ----------
Write-Host ''
Write-Host "工作区：$ws" -ForegroundColor Cyan
Write-Host "Hub   ：$hub" -ForegroundColor Cyan
Write-Host ''
$rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host

$fails = @($rows | Where-Object 结果 -eq 'FAIL')
$warns = @($rows | Where-Object 结果 -eq 'WARN')
Write-Host ("汇总：PASS {0} / WARN {1} / FAIL {2}" -f @($rows | Where-Object 结果 -eq 'PASS').Count, $warns.Count, $fails.Count) -ForegroundColor $(if ($fails.Count) { 'Red' } elseif ($warns.Count) { 'Yellow' } else { 'Green' })

if ($fails.Count) { exit 1 } else { exit 0 }
