<#
.SYNOPSIS
    单独打开屏幕顶部的 Agent 状态条（run-task.ps1 会自动拉起，这里用于手动查看）。
.DESCRIPTION
    读取 state\live.json 并显示。若文件不存在（还没跑过任务），会生成一份「空闲」状态，
    状态条显示「共 0 个 Agent · 空闲」。同一时刻只会有一个状态条窗口（全局互斥体）。
    Esc 或右上角 × 关闭。
.EXAMPLE
    .\Start-Hud.ps1
#>
[CmdletBinding()]
param(
    [string]$LiveFile = (Join-Path $PSScriptRoot 'state\live.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\hub.ps1')

if (-not (Test-Path $LiveFile)) {
    $dir = Split-Path $LiveFile -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $idle = [ordered]@{
        run       = ''
        task      = '空闲'
        goal      = '暂无正在执行的任务'
        startedAt = (Get-Date).ToString('o')
        pid       = $PID
        closed    = $false
        agents    = @()
    }
    $idle | ConvertTo-Json -Depth 6 | Set-Content -Path $LiveFile -Encoding utf8
    Write-Host "已生成空闲状态：$LiveFile" -ForegroundColor DarkGray
}

$hud = Join-Path $PSScriptRoot 'lib\hud.ps1'
Start-Process -FilePath (Get-HubPwshExe) `
    -ArgumentList @('-Sta', '-NoProfile', '-File', $hud, '-LiveFile', $LiveFile) `
    -WindowStyle Hidden | Out-Null

Write-Host '状态条已显示在屏幕顶部（Esc 或右上角 × 关闭）' -ForegroundColor Green
