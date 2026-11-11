# 单个 Codex worker：被 run-task.ps1 / hub.ps1 以独立进程拉起，跑完就退出。
# 独立进程的好处是环境变量（CODEX_HOME / CODEX_API_KEY）互不干扰，天然支持并发。
param(
    [Parameter(Mandatory)][string]$CodexHome,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$PromptFile,
    [string]$Model = 'deepseek-v4-pro',
    [Parameter(Mandatory)][string]$LastFile,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string]$ErrFile
)

$ErrorActionPreference = 'Continue'

$exe = Get-ChildItem 'C:\Users\admin\AppData\Local\OpenAI\Codex\bin' -Recurse -Filter 'codex.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $exe) { "找不到 codex.exe" | Set-Content $ErrFile -Encoding utf8; exit 90 }

$env:CODEX_HOME = $CodexHome
$prompt = Get-Content $PromptFile -Raw

$codexArgs = @(
    'exec', '--skip-git-repo-check',
    '--cd', $WorkDir,
    '--sandbox', 'danger-full-access',
    '--json',
    '--output-last-message', $LastFile,
    '-c', "model=`"$Model`"",
    '-'
)

try {
    $prompt | & $exe.FullName @codexArgs 1> $OutFile 2> $ErrFile
    $code = $LASTEXITCODE
} catch {
    $_ | Out-String | Set-Content $ErrFile -Encoding utf8
    $code = 91
}
exit $code
