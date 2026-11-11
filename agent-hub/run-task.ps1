# run-task.ps1 —— 任务编排器（demo 工作区版）
#
#   pwsh -File run-task.ps1 -TaskFile tasks\audit.json
#   pwsh -File run-task.ps1 -TaskFile tasks\audit.json -DryRun
#   pwsh -File run-task.ps1 -TaskFile tasks\x.json -StrictOwns   # 越界写入即判失败
#
# 相比旧版新增三条硬约束（让「同时操作同一个文件夹」变安全）：
#   1. owns：每个子任务声明自己可写的路径；同批任务 owns 冲突则不并行，自动顺延到下一批。
#   2. 写入边界会写进提示词，Agent 被明确告知「其他文件只读」。
#   3. 跑完做一次文件快照对比，列出越界写入，报告里逐条列出。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskFile,
    [switch]$DryRun,
    [int]$MaxParallel = 3,
    [int]$TimeoutSec = 900,
    [switch]$StrictOwns,
    [switch]$NoBackup,
    [switch]$NoHud
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\hub.ps1')

# ---------- 载入任务 ----------
if (-not (Test-Path $TaskFile)) { throw "任务文件不存在：$TaskFile" }
$task = Get-Content $TaskFile -Raw -Encoding utf8 | ConvertFrom-Json
$subs = @($task.subtasks)
if (-not $subs) { throw '任务文件里没有 subtasks' }

$ids = $subs | ForEach-Object { $_.id }
$dup = $ids | Group-Object | Where-Object Count -gt 1
if ($dup) { throw "子任务 id 重复：$($dup.Name -join ', ')" }

foreach ($s in $subs) {
    foreach ($d in @($s.dependsOn)) {
        if ($d -and $d -notin $ids) { throw "子任务 $($s.id) 依赖了不存在的 $d" }
        if ($d -eq $s.id) { throw "子任务 $($s.id) 依赖自己" }
    }
}

$state = @{}
foreach ($s in $subs) { $state[$s.id] = 'pending' }

$workDir = if ($task.workDir) { $task.workDir } else { Join-Path $script:HubRoot 'work' }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$runDir = New-HubRunDir -Label $task.name
$reportPath = Join-Path $runDir 'report.md'
$resultPath = Join-Path $runDir 'result.json'

# ---------- 顶部状态条（HUD）的数据源 ----------
$liveDir  = Join-Path $script:HubRoot 'state'
New-Item -ItemType Directory -Force -Path $liveDir | Out-Null
$livePath = Join-Path $liveDir 'live.json'

$script:runStarted = (Get-Date).ToString('o')
$script:startTimes = @{}

function Write-LiveState {
    param([switch]$Closed)
    $agents = @()
    foreach ($s in $subs) {
        $agents += [pscustomobject]@{
            id        = $s.id
            agent     = $s.agent
            status    = $state[$s.id]
            startedAt = $script:startTimes[$s.id]
            logPath   = (Join-Path $runDir "$($s.id)\stdout.log")
            owns      = @($s.owns)
        }
    }
    $obj = [pscustomobject]@{
        run       = (Split-Path $runDir -Leaf)
        task      = $task.name
        goal      = $task.goal
        startedAt = $script:runStarted
        pid       = $PID
        closed    = [bool]$Closed
        agents    = $agents
    }
    $tmp = "$livePath.tmp"
    $obj | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $livePath -Force
}

Write-Host ''
Write-Host "任务：$($task.name)" -ForegroundColor Cyan
Write-Host "目标：$($task.goal)" -ForegroundColor DarkGray
Write-Host "工作目录：$workDir" -ForegroundColor DarkGray
Write-Host "运行目录：$runDir" -ForegroundColor DarkGray
Write-Host ("计划：" + (($subs | ForEach-Object { "$($_.id)[$($_.agent)]" }) -join ' → ')) -ForegroundColor DarkGray
$noOwns = @($subs | Where-Object { -not $_.owns })
if ($noOwns) {
    Write-Host ("注意：这些子任务没声明 owns，越界检测对其无效：{0}" -f (($noOwns | ForEach-Object { $_.id }) -join ', ')) -ForegroundColor Yellow
}
Write-Host ''

if ($DryRun) {
    foreach ($s in $subs) {
        $dep = if ($s.dependsOn) { " ← $($s.dependsOn -join ',')" } else { '' }
        $own = if ($s.owns) { "  [写: " + ($s.owns -join ', ') + "]" } else { '' }
        Write-Host ("  {0,-12} {1,-10}{2}{3}" -f $s.id, $s.agent, $dep, $own)
    }
    Write-Host "`n(DryRun，未执行)" -ForegroundColor Yellow
    return
}

# ---------- 拉起顶部状态条 ----------
Write-LiveState
if (-not $NoHud) {
    try {
        $hudArgs = @('-Sta', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'lib\hud.ps1'), '-LiveFile', $livePath)
        $null = Start-Process -FilePath (Get-HubPwshExe) -ArgumentList $hudArgs -WindowStyle Hidden -PassThru
        Write-Host '状态条：已显示在屏幕顶部（Esc 或关掉窗口即可隐藏）' -ForegroundColor DarkGray
    } catch {
        Write-Host "状态条启动失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------- owns 冲突检测 ----------
function Get-OwnsKey { param($Pattern) ($Pattern -replace '/', '\').TrimEnd('\') }

function Test-OwnsOverlap {
    param([string[]]$A, [string[]]$B)
    foreach ($x in @($A)) {
        foreach ($y in @($B)) {
            if (-not $x -or -not $y) { continue }
            $nx = Get-OwnsKey $x; $ny = Get-OwnsKey $y
            if ($nx -eq $ny) { return $true }
            # 一方是另一方的父目录 → 视为重叠
            if ($nx -like "$ny\*" -or $ny -like "$nx\*") { return $true }
            # 通配符模式：比较通配符之前的字面前缀
            $px = ($nx -split '[*?]')[0].TrimEnd('\')
            $py = ($ny -split '[*?]')[0].TrimEnd('\')
            if ($px -and $py -and $px -eq $py) { return $true }
            if ($px -and $py -and ($px.StartsWith("$py\") -or $py.StartsWith("$px\"))) { return $true }
        }
    }
    return $false
}

# ---------- 文件快照（用于越界检测） ----------
function Get-TreeSnapshot {
    param([string]$Root)
    $h = @{}
    foreach ($f in Get-ChildItem $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $h[$f.FullName] = "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)"
    }
    return $h
}

function Backup-OwnedFiles {
    # 把 owns 范围内「已存在」的文件先复制一份，用于回滚（本机没有 git，这是替代方案）
    param([string]$Root, [string[]]$Owns, [string]$Dest)
    if (-not $Owns -or $Owns.Count -eq 0) { return 0 }
    $n = 0
    foreach ($f in Get-ChildItem $Root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $rel = [System.IO.Path]::GetRelativePath($Root, $f.FullName)
        $hit = $false
        foreach ($p in $Owns) {
            $pat = (Get-OwnsKey $p)
            if ($rel -like $pat -or $rel -like "$pat\*" -or $rel -eq $pat) { $hit = $true; break }
        }
        if (-not $hit) { continue }
        $target = Join-Path $Dest $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item $f.FullName $target -Force
        $n++
    }
    return $n
}

function Get-OutsideOwns {
    # 注意：同一批并发的兄弟任务窗口重叠，它们写的文件不能算到本任务头上，
    # 因此把兄弟任务的 owns 一并传入 -AlsoAllowed，只有「谁都没声明」的文件才算越界。
    param([hashtable]$Before, [hashtable]$After, [string]$Root, [string[]]$Owns, [string[]]$AlsoAllowed = @())
    if (-not $Owns -or $Owns.Count -eq 0) { return @() }
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($k in $After.Keys) {
        if ($Before.ContainsKey($k) -and $Before[$k] -eq $After[$k]) { continue }
        $rel = [System.IO.Path]::GetRelativePath($Root, $k)
        $ok = $false
        foreach ($p in (@($Owns) + @($AlsoAllowed))) {
            if (-not $p) { continue }
            $pat = (Get-OwnsKey $p)
            if ($rel -like $pat -or $rel -like "$pat\*" -or $rel -eq $pat) { $ok = $true; break }
        }
        if (-not $ok) { $bad.Add($rel) }
    }
    return $bad.ToArray()
}

# ---------- 执行 ----------
$results = @{}
$wave = 0

function Get-ReadySubs {
    foreach ($s in $subs) {
        if ($state[$s.id] -ne 'pending') { continue }
        $deps = @($s.dependsOn) | Where-Object { $_ }
        $blocked = @($deps | Where-Object { $state[$_] -notin @('done', 'skipped') })
        if ($blocked.Count -eq 0) { $s }
    }
}

function New-SubtaskPrompt {
    param($Sub)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("总目标：$($task.goal)")
    [void]$sb.AppendLine("你的角色：你是一次多 Agent 协作中的执行者，只负责下面这一块，不要越界做别人的部分。")
    [void]$sb.AppendLine("工作目录：$workDir（你的产物写在这里）")
    if ($Sub.owns) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## 写入边界（硬约束）')
        [void]$sb.AppendLine('同一时间可能有别的 Agent 在同一个目录里工作。你**只允许创建或修改**下列路径：')
        foreach ($o in @($Sub.owns)) { [void]$sb.AppendLine("- ``$o``") }
        [void]$sb.AppendLine('其他文件一律只读，不要新建临时文件、不要改写别人的产物。')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($Sub.prompt)
    $deps = @($Sub.dependsOn) | Where-Object { $_ }
    if ($deps) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## 上游产出')
        foreach ($d in $deps) {
            $msg = $results[$d].LastMessage
            if (-not $msg) { $msg = '(上游没有返回文本)' }
            if ($msg.Length -gt 3000) { $msg = $msg.Substring(0, 3000) + "`n…(截断)" }
            [void]$sb.AppendLine("### $d")
            [void]$sb.AppendLine($msg)
        }
    }
    $sb.ToString()
}

while ($state.Values -contains 'pending') {
    $ready = @(Get-ReadySubs)
    if (-not $ready) {
        foreach ($k in @($state.Keys)) { if ($state[$k] -eq 'pending') { $state[$k] = 'skipped' } }
        break
    }

    $wave++
    # 贪心挑选：既不超过 MaxParallel，也不让 owns 重叠的任务同批
    $batch = New-Object System.Collections.Generic.List[object]
    foreach ($s in $ready) {
        if ($batch.Count -ge $MaxParallel) { break }
        $clash = $false
        foreach ($b in $batch) {
            if (Test-OwnsOverlap -A @($s.owns) -B @($b.owns)) { $clash = $true; break }
        }
        if ($clash) {
            Write-Host ("  ⏸ {0} 与本批其它任务写入范围重叠，顺延到下一批" -f $s.id) -ForegroundColor DarkYellow
            continue
        }
        $batch.Add($s)
    }
    if ($batch.Count -eq 0) { $batch.Add($ready[0]) }

    foreach ($s in $batch) { $state[$s.id] = 'running' }
    Write-Host ("第 {0} 批：{1}" -f $wave, (($batch | ForEach-Object { $_.id }) -join ', ')) -ForegroundColor Cyan
    Write-LiveState

    $workers = @{}
    $snapshots = @{}
    foreach ($s in $batch) {
        if ($s.agent -eq 'codex') {
            $snapshots[$s.id] = Get-TreeSnapshot -Root $workDir
            if (-not $NoBackup) {
                $bdir = Join-Path $runDir "$($s.id)\backup"
                $bn = Backup-OwnedFiles -Root $workDir -Owns @($s.owns) -Dest $bdir
                if ($bn -gt 0) { Write-Host ("  ⛑ {0} 已备份 {1} 个文件到 runs\...\{0}\backup" -f $s.id, $bn) -ForegroundColor DarkGray }
            }
            $w = Start-CodexWorker -Prompt (New-SubtaskPrompt -Sub $s) -WorkDir $workDir -Slot $s.id -RunDir (Join-Path $runDir $s.id)
            $workers[$s.id] = $w
            $script:startTimes[$s.id] = (Get-Date).ToString('o')
            Write-Host ("  ▶ {0} 已启动（{1}）" -f $s.id, $w.Process.Id) -ForegroundColor DarkYellow
        } else {
            $state[$s.id] = 'skipped'
            $results[$s.id] = [pscustomobject]@{
                Agent = $s.agent; Ok = $null; ExitCode = $null; LastMessage = $null
                Stdout = ''; Stderr = ''; RunDir = $null; Seconds = 0; OutsideOwns = @()
                Error = "agent=$($s.agent) 不支持脚本拉起，需人工/会话内执行"
            }
            Write-Host ("  ⏭ {0} 跳过（{1} 不能脚本调用）" -f $s.id, $s.agent) -ForegroundColor DarkYellow
        }
    }

    Write-LiveState   # 本批 worker 都已拿到 PID 和启动时间，刷新一次状态条

    foreach ($id in $workers.Keys) {
        $r = Wait-CodexWorker -Worker $workers[$id] -TimeoutSec $TimeoutSec
        $sub = $subs | Where-Object { $_.id -eq $id }
        $siblingOwns = @()
        foreach ($b in $batch) { if ($b.id -ne $id) { $siblingOwns += @($b.owns) } }
        $after = Get-TreeSnapshot -Root $workDir
        $outside = Get-OutsideOwns -Before $snapshots[$id] -After $after -Root $workDir -Owns @($sub.owns) -AlsoAllowed $siblingOwns
        $r | Add-Member -NotePropertyName OutsideOwns -NotePropertyValue $outside -Force
        $results[$id] = $r

        if ($outside.Count -gt 0) {
            Write-Host ("  ⚠ {0} 越界写了 {1} 个文件：{2}" -f $id, $outside.Count, ($outside -join ', ')) -ForegroundColor Yellow
        }

        if ($r.Ok) {
            if ($StrictOwns -and $outside.Count -gt 0) {
                $state[$id] = 'failed'
                $r.Ok = $false
                $r.Error = "越界写入：$($outside -join ', ')"
                Write-Host ("  ✖ {0} 越界，按 -StrictOwns 判失败" -f $id) -ForegroundColor Red
            } else {
                $state[$id] = 'done'
                Write-Host ("  ✔ {0} 完成 {1}s" -f $id, $r.Seconds) -ForegroundColor Green
            }
        } else {
            $state[$id] = 'failed'
            Write-Host ("  ✖ {0} 失败 {1}s：{2}" -f $id, $r.Seconds, $r.Error) -ForegroundColor Red
        }
        Write-LiveState
    }
}

# ---------- 汇总 ----------
$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# 任务报告：$($task.name)")
[void]$md.AppendLine('')
[void]$md.AppendLine("- 目标：$($task.goal)")
[void]$md.AppendLine("- 工作目录：``$workDir``")
[void]$md.AppendLine("- 运行时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$md.AppendLine("- 总耗时：$([math]::Round(((Get-Date) - (Get-Item $runDir).CreationTime).TotalSeconds,1))s")
[void]$md.AppendLine('')
[void]$md.AppendLine('| 子任务 | Agent | 状态 | 耗时 | 越界写入 | 产出目录 |')
[void]$md.AppendLine('|---|---|---|---|---|---|')
foreach ($s in $subs) {
    $r = $results[$s.id]
    $icon = switch ($state[$s.id]) { 'done' { '✅' } 'failed' { '❌' } 'skipped' { '⏭' } default { '❔' } }
    $out = if ($r -and $r.OutsideOwns -and $r.OutsideOwns.Count -gt 0) { "$($r.OutsideOwns.Count) 个" } else { '无' }
    [void]$md.AppendLine("| $($s.id) | $($s.agent) | $icon $($state[$s.id]) | $(if($r){$r.Seconds}else{'-'})s | $out | $(if($r){'`'+$r.RunDir+'`'}else{'-'}) |")
}
[void]$md.AppendLine('')
foreach ($s in $subs) {
    $r = $results[$s.id]
    [void]$md.AppendLine("## $($s.id)")
    if ($r -and $r.OutsideOwns -and $r.OutsideOwns.Count -gt 0) {
        [void]$md.AppendLine('')
        [void]$md.AppendLine('> 越界写入（不在 owns 内）：')
        foreach ($o in $r.OutsideOwns) { [void]$md.AppendLine("- ``$o``") }
    }
    if ($r -and $r.LastMessage) { [void]$md.AppendLine(''); [void]$md.AppendLine($r.LastMessage) }
    elseif ($r -and $r.Error) { [void]$md.AppendLine(''); [void]$md.AppendLine("> 失败原因：$($r.Error)") }
    [void]$md.AppendLine('')
}
Set-Content -Path $reportPath -Value $md.ToString() -Encoding utf8

$results | ConvertTo-Json -Depth 6 | Set-Content -Path $resultPath -Encoding utf8

Write-Host ''
Write-Host '---- 汇总 ----' -ForegroundColor Cyan
foreach ($s in $subs) {
    $icon = switch ($state[$s.id]) { 'done' { '✔' } 'failed' { '✖' } 'skipped' { '·' } default { '?' } }
    Write-Host ("  {0} {1,-12} {2}" -f $icon, $s.id, $state[$s.id])
}
Write-Host "`n报告：$reportPath" -ForegroundColor Gray

Write-LiveState -Closed
Start-Sleep -Milliseconds 700

if ($state.Values -contains 'failed') { exit 1 } else { exit 0 }
