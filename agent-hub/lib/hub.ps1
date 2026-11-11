# agent-hub 的调用层
# 用法：  . .\lib\hub.ps1
# 约定：所有适配器统一返回 [pscustomobject]，字段固定为
#        Agent, Ok, ExitCode, LastMessage, Stdout, Stderr, RunDir, Seconds, Error
#
# 为什么 Codex 要跑在 danger-full-access 下：
#   DSH 的 file sandbox 会连带限制 TLS 凭证（schannel SEC_E_NO_CREDENTIALS），
#   沙箱内所有 HTTPS 都失败，而 Codex 必须访问 api.deepseek.com。
#   同时 Codex 默认写 ~/.codex，沙箱也不允许，故改用工作区内的 CODEX_HOME。

$script:HubRoot         = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:RealCodexConfig = 'C:\Users\admin\.codex\config.toml'
$script:DefaultWorkDir  = Join-Path $script:HubRoot 'work'

# git 是 PortableGit 用户级安装：新开的终端有 PATH，但早已启动的 DSH 进程不会感知，
# 因此这里兜底把它的 cmd 目录补进当前进程 PATH。
$script:PortableGitBin = 'C:\Users\admin\Programs\PortableGit\cmd'
if (-not (Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path $script:PortableGitBin)) {
    $env:Path = $env:Path + ';' + $script:PortableGitBin
}
function Get-HubGitExe {
    $c = Get-Command git -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $script:PortableGitBin 'git.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Get-HubRoot { $script:HubRoot }

function Get-HubCodexExe {
    # bin 目录带哈希后缀，升级会变，动态查找最新的 codex.exe
    $base = 'C:\Users\admin\AppData\Local\OpenAI\Codex\bin'
    $hit = Get-ChildItem $base -Recurse -Filter 'codex.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $hit) { throw "找不到 codex.exe，检查 $base" }
    $hit.FullName
}

function Get-HubCodexKey {
    # 从 Codex 真实配置读 API Key，只在进程环境里传递，不落盘、不回显
    if (-not (Test-Path $script:RealCodexConfig)) { throw "找不到 $script:RealCodexConfig" }
    $m = [regex]::Match((Get-Content $script:RealCodexConfig -Raw), 'experimental_bearer_token\s*=\s*"([^"]+)"')
    if (-not $m.Success) { throw 'Codex 配置里没有 experimental_bearer_token' }
    $m.Groups[1].Value
}

function New-HubRunDir {
    param([string]$Label = 'run')
    $safe = ($Label -replace '[^\w\-]', '_')
    $dir = Join-Path $script:HubRoot ("runs\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safe)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

function Initialize-CodexHome {
    <#
      每个并发 worker 用独立的 CODEX_HOME，避免多个进程争抢同一个 sqlite。
      配置里用 env_key 从环境变量取密钥，不把明文写进工作区文件。
    #>
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $cfg = @'
model_provider = "custom"
model = "deepseek-v4-pro"
model_reasoning_effort = "high"

[model_providers.custom]
name = "deepseek"
base_url = "https://api.deepseek.com"
wire_api = "responses"
requires_openai_auth = false
env_key = "CODEX_API_KEY"

[windows]
sandbox = "unelevated"
'@
    Set-Content -Path (Join-Path $Path 'config.toml') -Value $cfg -Encoding utf8
    $Path
}

function Get-HubPwshExe {
    # 本机是 ZIP 用户级安装，不在 Program Files 下，按优先级探测
    foreach ($cand in @(
        [Environment]::ProcessPath,
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    )) {
        if ($cand -and (Test-Path $cand) -and ($cand -match 'pwsh\.exe$')) { return $cand }
    }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw '找不到 pwsh.exe'
}

function Start-CodexWorker {
    <#
      启动一个 Codex worker 进程（不等待）。返回句柄，供 Wait-CodexWorker 收尾。
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$WorkDir,
        [string]$Model = 'deepseek-v4-pro',
        [string]$Slot  = 'w1',
        [string]$RunDir
    )

    if (-not $WorkDir) { $WorkDir = $script:DefaultWorkDir }
    if (-not $RunDir)  { $RunDir  = New-HubRunDir -Label "codex-$Slot" }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    New-Item -ItemType Directory -Force -Path $RunDir  | Out-Null

    $promptFile = Join-Path $RunDir 'prompt.txt'
    $outFile    = Join-Path $RunDir 'stdout.log'
    $errFile    = Join-Path $RunDir 'stderr.log'
    $lastFile   = Join-Path $RunDir 'last-message.txt'
    Set-Content -Path $promptFile -Value $Prompt -Encoding utf8

    $homeDir = Initialize-CodexHome -Path (Join-Path $script:HubRoot "codex-home\$Slot")
    $env:CODEX_API_KEY = Get-HubCodexKey

    $worker = Join-Path $script:HubRoot 'lib\codex-worker.ps1'
    $argStr = '-NoProfile -File "{0}" -CodexHome "{1}" -WorkDir "{2}" -PromptFile "{3}" -Model "{4}" -LastFile "{5}" -OutFile "{6}" -ErrFile "{7}"' -f `
        $worker, $homeDir, $WorkDir, $promptFile, $Model, $lastFile, $outFile, $errFile

    $proc = Start-Process -FilePath (Get-HubPwshExe) `
        -ArgumentList $argStr -WindowStyle Hidden -PassThru -ErrorAction Stop

    [pscustomobject]@{
        Slot       = $Slot
        Process    = $proc
        RunDir     = $RunDir
        LastFile   = $lastFile
        OutFile    = $outFile
        ErrFile    = $errFile
        StartedAt  = Get-Date
        Prompt     = $Prompt
        WorkDir    = $WorkDir
    }
}

function Wait-CodexWorker {
    param(
        [Parameter(Mandatory)]$Worker,
        [int]$TimeoutSec = 600
    )

    $proc = $Worker.Process
    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit(5000) | Out-Null
    }

    $last = if (Test-Path $Worker.LastFile) { (Get-Content $Worker.LastFile -Raw).Trim() } else { $null }
    $stdout = if (Test-Path $Worker.OutFile) { Get-Content $Worker.OutFile -Raw } else { '' }
    $stderr = if (Test-Path $Worker.ErrFile) { Get-Content $Worker.ErrFile -Raw } else { '' }
    $code = if ($timedOut) { -2 } else { $proc.ExitCode }

    $err = $null
    if ($timedOut) { $err = "超时 ${TimeoutSec}s 后被终止" }
    elseif ($code -ne 0) {
        $err = (($stderr -split "`n") | Where-Object { $_ -match 'error|Error|ERROR' } | Select-Object -First 3) -join ' | '
        if (-not $err) { $err = ($stderr -split "`n" | Select-Object -Last 3) -join ' | ' }
    }

    [pscustomobject]@{
        Agent       = 'codex'
        Ok          = ($code -eq 0)
        ExitCode    = $code
        LastMessage = $last
        Stdout      = $stdout
        Stderr      = $stderr
        RunDir      = $Worker.RunDir
        Seconds     = [math]::Round(((Get-Date) - $Worker.StartedAt).TotalSeconds, 1)
        Error       = $err
    }
}

function Invoke-CodexAgent {
    <# 单次调用 Codex，等到结果返回。 #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$WorkDir,
        [int]$TimeoutSec = 600,
        [string]$Model = 'deepseek-v4-pro'
    )
    $w = Start-CodexWorker -Prompt $Prompt -WorkDir $WorkDir -Model $Model
    Wait-CodexWorker -Worker $w -TimeoutSec $TimeoutSec
}


