# hud.ps1 —— 屏幕顶部的常驻状态条
#
#   pwsh -Sta -NoProfile -File lib\hud.ps1 -LiveFile D:\demo\agent-hub\state\live.json
#
# 设计要点：
#   * 用 WPF 无边框窗口贴在最上方，Topmost + ShowActivated=false，不抢焦点、不进任务栏。
#   * 状态来自 live.json（run-task.ps1 在每次状态变化时写），
#     「正在做什么」由 HUD 自己 tail 对应 worker 的 stdout.log（codex --json 的 JSONL 事件），
#     这样 run-task 阻塞等待 worker 时也能持续刷新，不需要额外的上报线程。
#   * task 结束（live.json 里 closed=true）后再显示 6 秒「已完成」然后自动退出。

param(
    [Parameter(Mandatory)][string]$LiveFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$conv = New-Object System.Windows.Media.BrushConverter
function B([string]$hex) { $conv.ConvertFromString($hex) }

$colBg      = B('#F214161B')   # 接近全黑的半透明底
$colFg      = B('#FFE8EAED')
$colDim     = B('#FF8A9099')
$colRun     = B('#FF4ADE80')   # 运行中
$colDone    = B('#FF60A5FA')   # 完成
$colFail    = B('#FFF87171')   # 失败
$colSkip    = B('#FF6B7280')   # 跳过
$colPend    = B('#FF9CA3AF')   # 排队

$window = New-Object System.Windows.Window
$window.WindowStyle          = 'None'
$window.AllowsTransparency   = $true
$window.Background           = [System.Windows.Media.Brushes]::Transparent
$window.Topmost              = $true
$window.ShowInTaskbar        = $false
$window.ShowActivated        = $false
$window.ResizeMode           = 'NoResize'
$window.WindowStartupLocation = 'Manual'
$window.Left                 = 0
$window.Top                  = 0
$window.Width                = [System.Windows.SystemParameters]::PrimaryScreenWidth
$window.Height               = 74

$border = New-Object System.Windows.Controls.Border
$border.Background      = $colBg
$border.CornerRadius    = New-Object System.Windows.CornerRadius(0, 0, 16, 16)
$border.Padding         = New-Object System.Windows.Thickness(20, 9, 20, 9)
$border.BorderBrush     = B('#22FFFFFF')
$border.BorderThickness = New-Object System.Windows.Thickness(0, 0, 0, 1)

$panel = New-Object System.Windows.Controls.StackPanel
$panel.Orientation = 'Horizontal'
$panel.VerticalAlignment = 'Center'

# 右上角的关闭按钮（窗口不抢焦点，所以给个能点的出口）
$closeBtn = New-Object System.Windows.Controls.Button
$closeBtn.Content = '×'
$closeBtn.FontSize = 16
$closeBtn.Width = 26
$closeBtn.Height = 26
$closeBtn.Background = [System.Windows.Media.Brushes]::Transparent
$closeBtn.Foreground = B('#FF8A9099')
$closeBtn.BorderThickness = New-Object System.Windows.Thickness(0)
$closeBtn.Cursor = 'Hand'
$closeBtn.VerticalAlignment = 'Center'
$closeBtn.ToolTip = '关闭状态条'

$grid = New-Object System.Windows.Controls.Grid
$c0 = New-Object System.Windows.Controls.ColumnDefinition
$c0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
$c1 = New-Object System.Windows.Controls.ColumnDefinition
$c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
[void]$grid.ColumnDefinitions.Add($c0)
[void]$grid.ColumnDefinitions.Add($c1)
[System.Windows.Controls.Grid]::SetColumn($panel, 0)
[System.Windows.Controls.Grid]::SetColumn($closeBtn, 1)
[void]$grid.Children.Add($panel)
[void]$grid.Children.Add($closeBtn)

$border.Child = $grid
$window.Content = $border

function Make-Text([string]$text, [double]$size, $brush, [switch]$Bold) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text
    $t.FontSize = $size
    $t.Foreground = $brush
    $t.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
    $t.TextTrimming = 'CharacterEllipsis'
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    $t.VerticalAlignment = 'Center'
    return $t
}

$sep = New-Object System.Windows.Controls.Border
$sep.Width = 1
$sep.Height = 34
$sep.Margin = New-Object System.Windows.Thickness(16, 0, 16, 0)
$sep.Background = B('#26FFFFFF')

# ---------- 读取活动：从 codex --json 的事件流里取最后一条「可读」事件 ----------
function Get-Activity([string]$LogPath) {
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return '等待启动…' }
    try {
        # 强制成数组：只有一行时 Get-Content 返回单个字符串，索引会取到字符
        $lines = @(Get-Content $LogPath -Tail 60 -ErrorAction Stop)
    } catch { return '读取中…' }

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if (-not $line) { continue }
        if (-not $line.StartsWith('{')) {
            # 非 JSONL（旧格式或纯文本输出）
            if ($line.Length -gt 2) { return $line }
            continue
        }
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        if (-not $ev.item) { continue }
        $it = $ev.item
        switch ($it.type) {
            'command_execution' {
                $c = [string]$it.command
                $c = $c -replace '^"[^"]*pwsh\.exe"\s+-Command\s+', ''
                $c = $c -replace '^"[^"]*powershell\.exe"\s+-Command\s+', ''
                $c = $c -replace '\s+', ' '
                $c = $c.Trim('"', ' ')
                if ($c.Length -gt 90) { $c = $c.Substring(0, 90) + '…' }
                $st = if ($ev.type -eq 'item.started') { '执行' } else { '已执行' }
                return "$st · $c"
            }
            'agent_message' {
                $t = ([string]$it.text) -replace '\s+', ' '
                if ($t.Length -gt 90) { $t = $t.Substring(0, 90) + '…' }
                return "输出 · $t"
            }
            'reasoning' { return '思考中…' }
            'file_change' {
                $paths = @($it.changes | ForEach-Object { $_.path })
                return ('改文件 · ' + (($paths | Select-Object -First 2) -join ', '))
            }
        }
    }
    return '工作中…'
}

function Get-Elapsed([string]$iso) {
    if (-not $iso) { return '' }
    try {
        $t = [datetime]::Parse($iso)
        $s = ((Get-Date) - $t).TotalSeconds
        if ($s -lt 0) { $s = 0 }
        if ($s -lt 60) { return "$([math]::Round($s,0))s" }
        return "$([math]::Floor($s/60))m$([math]::Round($s%60,0))s"
    } catch { return '' }
}

$script:closed = $false
$script:closedAt = $null

function Update-Hud {
    try {
        $raw = Get-Content $LiveFile -Raw -ErrorAction Stop
        $live = $raw | ConvertFrom-Json
    } catch {
        return
    }

    $panel.Children.Clear()
    $agents = @($live.agents)
    $running = @($agents | Where-Object { $_.status -eq 'running' }).Count
    $failed  = @($agents | Where-Object { $_.status -eq 'failed' }).Count
    $done    = @($agents | Where-Object { $_.status -eq 'done' }).Count
    $total   = $agents.Count

    $brand = Make-Text '多 AI 协作' 15 $colFg -Bold
    $brand.Margin = New-Object System.Windows.Thickness(0, 0, 14, 0)
    [void]$panel.Children.Add($brand)

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 9; $dot.Height = 9; $dot.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $dot.VerticalAlignment = 'Center'
    $dot.Fill = if ($live.closed) { $colDone } elseif ($failed -gt 0) { $colFail } else { $colRun }
    [void]$panel.Children.Add($dot)

    $head = if ($live.closed) {
        if ($failed -gt 0) { "已结束 · $done/$total 完成 · $failed 失败" } else { "已结束 · $done/$total 全部完成" }
    } else {
        "共 $total 个 Agent · 运行中 $running · 完成 $done$(if($failed -gt 0){" · 失败 $failed"})"
    }
    [void]$panel.Children.Add((Make-Text $head 14 $colFg -Bold))
    [void]$panel.Children.Add($sep)

    # 每个 Agent 一格：● 名称  状态/耗时  ⏎ 正在做什么
    $i = 0
    foreach ($a in $agents) {
        if ($i -ge 6) { break }   # 屏幕上最多显示 6 个，避免溢出
        $i++
        $cell = New-Object System.Windows.Controls.StackPanel
        $cell.Margin = New-Object System.Windows.Thickness(0, 0, 20, 0)
        $cell.Width = 250

        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'

        $d = New-Object System.Windows.Shapes.Ellipse
        $d.Width = 8; $d.Height = 8
        $d.Margin = New-Object System.Windows.Thickness(0, 0, 7, 0)
        $d.VerticalAlignment = 'Center'
        $d.Fill = switch ($a.status) {
            'running' { $colRun }
            'done'    { $colDone }
            'failed'  { $colFail }
            'skipped' { $colSkip }
            default   { $colPend }
        }
        [void]$row.Children.Add($d)

        $name = Make-Text ([string]$a.id) 12 $colFg -Bold
        [void]$row.Children.Add($name)

        $meta = if ($a.status -eq 'running') { Get-Elapsed $a.startedAt } else { [string]$a.status }
        $mt = Make-Text ("  " + $meta) 11 $colDim
        [void]$row.Children.Add($mt)

        [void]$cell.Children.Add($row)

        $act = if ($a.status -eq 'running') { Get-Activity $a.logPath }
               elseif ($a.status -eq 'done') { "✔ 完成 · $(Get-Elapsed $a.startedAt)" }
               elseif ($a.status -eq 'failed') { "✖ 失败" }
               else { '排队中' }
        $at = Make-Text $act 11 $colDim
        $at.Margin = New-Object System.Windows.Thickness(15, 1, 0, 0)
        $at.MaxWidth = 235
        [void]$cell.Children.Add($at)

        [void]$panel.Children.Add($cell)
    }

    if ($live.closed -and -not $script:closed) {
        $script:closed = $true
        $script:closedAt = Get-Date
    }
    if ($script:closed -and ((Get-Date) - $script:closedAt).TotalSeconds -gt 6) {
        $window.Close()
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)
$timer.Add_Tick({ Update-Hud })
$timer.Start()

# 同时只允许一个状态条存在（重复启动任务时不叠窗）
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\agent-hub-hud')
if (-not $script:mutex.WaitOne(0)) { exit 0 }

$closeBtn.Add_Click({ $window.Close() })
$window.Add_Closed({ try { $script:mutex.ReleaseMutex() } catch { } })
$window.Add_Loaded({ Update-Hud })
$window.Show()

$app = New-Object System.Windows.Application
[void]$app.Run($window)
