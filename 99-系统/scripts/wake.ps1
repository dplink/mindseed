# ============================================================
# MindSeed 唤醒脚本 · wake.ps1（Windows 版，与 wake.sh 逻辑对齐）
# 用途：新会话开始时一条命令完成「定位 → 凭证预检 → 拉取 → 失败诊断 → 补推 → 新鲜度」
# 用法：powershell -File 99-系统\scripts\wake.ps1
# 凭证来源（按序）：$env:GH_TOKEN → $env:MINDSEED_TOKEN_FILE
#          → %USERPROFILE%\.mindseed\ghToken.txt → %USERPROFILE%\.mindseed-token.txt
# 仓库定位（按序）：$env:MINDSEED_DIR → 脚本自定位（<repo>/99-系统/scripts/）
#          → 当前目录下 mindseed → %USERPROFILE%\mindseed → %USERPROFILE%\workspace\mindseed
# 机器前置：http.sslBackend=openssl 与 http.proxy 按 99-系统/托管规范.md 5.2 配好
#          （本脚本只检测提示，不擅自改配置）
# 状态文件写在仓库内（.gitignore 已排除），避免工作区外写入被沙箱拒绝
# ============================================================
$ErrorActionPreference = 'Continue'

function Write-Warn([string]$m) { Write-Warning $m }

# ---------- ② 定位本地副本 ----------
$repoDir = $env:MINDSEED_DIR
if (-not $repoDir) {
    $selfRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if ($selfRoot -and (Test-Path (Join-Path $selfRoot '.git'))) { $repoDir = $selfRoot }
}
if (-not $repoDir) {
    foreach ($d in @((Join-Path (Get-Location) 'mindseed'),
                     (Join-Path $env:USERPROFILE 'mindseed'),
                     (Join-Path $env:USERPROFILE 'workspace\mindseed'))) {
        if (Test-Path (Join-Path $d '.git')) { $repoDir = $d; break }
    }
}
if (-not $repoDir) {
    Write-Warn '未找到心智库本地副本 —— 请先克隆：git clone <仓库地址> mindseed，再重跑本脚本'
    exit 2
}
Set-Location $repoDir
$Config = Join-Path $repoDir 'mind.config'

function Get-Cfg([string]$Key) {
    if (-not (Test-Path $Config)) { return '' }
    $line = Get-Content -Path $Config -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "^$Key\s*=" } |
            Select-Object -First 1
    if (-not $line) { return '' }
    return (($line -split '=', 2)[1]).Trim()
}

$RepoSlug     = Get-Cfg 'REPO_SLUG'
$PersonaName  = Get-Cfg 'PERSONA_NAME'
$PersonaRole  = Get-Cfg 'PERSONA_ROLE'
$UserName     = Get-Cfg 'USER_NAME'
$VisionOn     = Get-Cfg 'VISION_ENABLED'
$VisionSlug   = Get-Cfg 'VISION_REPO_SLUG'

$instantiated = $true
if (-not $PersonaName -or $PersonaName -match '__') { $instantiated = $false }
if (-not $PersonaRole -or $PersonaRole -match '__') { $instantiated = $false }
if (-not $UserName -or $UserName -match '__') { $instantiated = $false }
if (-not $RepoSlug -or $RepoSlug -match '__') { $instantiated = $false }

# ---------- ① 凭证注入（x-access-token + Basic，不落盘） ----------
function Add-Creds {
    if (-not $env:GH_TOKEN) {
        foreach ($f in @($env:MINDSEED_TOKEN_FILE,
                         (Join-Path $env:USERPROFILE '.mindseed\ghToken.txt'),
                         (Join-Path $env:USERPROFILE '.mindseed-token.txt'))) {
            if ($f -and (Test-Path $f)) { $env:GH_TOKEN = (Get-Content $f -Raw).Trim(); break }
        }
    }
    if (-not $env:GH_TOKEN) {
        Write-Warn 'GH_TOKEN 未设置且未找到 token 文件，跳过网络操作（将以本地副本降级运行）'
        return $false
    }
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = 'http.extraheader'
    $pair = "x-access-token:$env:GH_TOKEN"
    $env:GIT_CONFIG_VALUE_0 = 'Authorization: Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return $true
}

$hasCreds = $false
if ($instantiated) {
    $hasCreds = Add-Creds
} else {
    Write-Warn '尚未实例化（mind.config 仍为占位符），跳过网络操作'
}

# ---------- ②' 环境体检（只提示，不擅改） ----------
$sslBackend = (git config --get http.sslBackend) 2>$null
if ("$sslBackend" -ne 'openssl') {
    Write-Warn "TLS 后端非 openssl（当前：'$sslBackend'），Windows 受限沙箱可能报 SEC_E_NO_CREDENTIALS —— 见托管规范 5.2"
}
$proxy = (git config --get http.proxy) 2>$null
if (-not "$proxy") {
    Write-Warn 'git 未配置 http.proxy，直连 github.com:443 可能不稳 —— 见托管规范 5.2'
}

# ---------- ②'' 凭证预检：先证明 token 能到达仓库，再动网络 ----------
function Test-RepoReach {
    param([string]$Slug)
    $err = @(git ls-remote --exit-code -q "https://github.com/$Slug.git" HEAD 2>&1 |
             ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $reason = 'ok'
    if ($code -ne 0) {
        $joined = $err -join ' '
        $reason = switch -Regex ($joined) {
            'Bad credentials|401|Authentication failed|Invalid username or token|could not read Username' { 'credential'; break }
            '403|Write access to repository not granted|404|Repository not found|not found' { 'scope'; break }
            'Could not (connect|resolve)|Failed to connect|unable to access|proxy|Timed out|Timeout' { 'network'; break }
            default { 'unknown' }
        }
    }
    [pscustomobject]@{ Ok = ($code -eq 0); Reason = $reason; Err = $err }
}

$tokenOk = $false
$visionOk = $false
if ($hasCreds) {
    $mind = Test-RepoReach $RepoSlug
    $tokenOk = $mind.Ok
    if (-not $tokenOk) {
        Write-Warn "凭证预检未通过：token 到不了心智库 $RepoSlug —— 本次跳过全部网络操作，以本地副本降级运行"
        switch ($mind.Reason) {
            'credential' { Write-Host '   ↳ 原因：token 本身无效 / 已过期 / 被吊销 —— 换掉 token 文件内容（见托管规范 5.1）' }
            'scope'      { Write-Host '   ↳ 原因：token 权限范围不含该私密库。细粒度 PAT 的 Repository access 默认是「Public Repositories」，必须显式勾选私密库并给 Contents: Read and write（见托管规范 5.1）' }
            'network'    { Write-Host '   ↳ 原因：网络 / 代理不通，先确认代理已启动（见托管规范 5.2）' }
            default      { Write-Host '   ↳ 原因未识别，原始输出如下：'
                           $mind.Err | Select-Object -First 3 | ForEach-Object { Write-Host "     $_" } }
        }
    } elseif ($VisionOn -eq '1' -and $VisionSlug -and $VisionSlug -notmatch '__') {
        $vision = Test-RepoReach $VisionSlug
        $visionOk = $vision.Ok
        if (-not $visionOk) {
            Write-Warn "凭证预检提醒：token 到不了图库 $VisionSlug —— 唤醒不受影响，但 vision.sh 取图/存图会失败（多半是授权范围问题）"
        }
    }
}

# ---------- ③ 同步远端（pull --rebase，自动 stash 容错 + 失败原因分类） ----------
$hasUpstream = $false
$null = git rev-parse --abbrev-ref '@{u}' 2>$null
if ($LASTEXITCODE -eq 0) { $hasUpstream = $true }

$pulled = 'skipped'
if ($tokenOk -and $hasUpstream) {
    $stashed = $false
    if (git status --porcelain) {
        git stash push -q -m 'wake-autostash'
        if ($LASTEXITCODE -eq 0) { $stashed = $true }
        else { Write-Warn '本地改动暂存失败（stash push 出错），pull 可能被脏工作区挡住' }
    }

    $pullErr = @(git pull --rebase -q 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) {
        $pulled = 'yes'
    } else {
        $joined = $pullErr -join ' '
        $reason = switch -Regex ($joined) {
            'Could not (connect|resolve)|Failed to connect|unable to access|proxy|Timed out|Timeout' { 'network'; break }
            'unstaged changes|cannot pull with rebase|Your local changes|would be overwritten' { 'dirty'; break }
            'CONFLICT|could not apply|Resolve all conflicts' { 'conflict'; break }
            default { 'unknown' }
        }
        Write-Warn 'pull --rebase 失败，以本地副本降级运行（改动不会丢失，下次补同步）'
        switch ($reason) {
            'network'  { Write-Host '   ↳ 原因：网络 / 代理不通，拉不到 github.com —— 检查代理与 http.proxy（见托管规范 5.2）' }
            'dirty'    { Write-Host '   ↳ 原因：工作区有未提交改动挡住了 rebase —— 先 git status 看清，视情况 commit 或 git stash' }
            'conflict' { Write-Host '   ↳ 原因：出现真冲突，rebase 可能停在中途 —— 处理完 git rebase --continue，或 git rebase --abort 回到原状' }
            default    { Write-Host '   ↳ 原因未识别（可能是本地化报错），原始输出如下：'
                         $pullErr | Select-Object -First 5 | ForEach-Object { Write-Host "     $_" } }
        }
        $behind = @(git rev-list --count 'HEAD..@{u}' 2>$null)
        if ($behind.Count -gt 0 -and "$($behind[0])" -match '^\d+$' -and [int]$behind[0] -gt 0) {
            Write-Host "   ↳ 按上次成功同步的记录，本地至少落后远端 $($behind[0]) 条提交"
        }
    }

    if ($stashed) {
        git stash pop -q 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn '自动暂存的改动未能放回！它们安全地留在 stash 里 —— 用 git stash list 查看、git stash pop 手动恢复'
        }
    }
}

# ---------- ④ 补推上次未推送的本地 commit ----------
if ($tokenOk -and $hasUpstream) {
    $pending = @(git log --oneline '@{u}..HEAD' 2>$null)
    if ($pending.Count -gt 0) {
        Write-Host "📤 发现 $($pending.Count) 条未推送的本地记忆，补推中…"
        git push -q 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host '✅ 补推完成' }
        else { Write-Warn '补推失败，commit 仍安全在本地，下次再试' }
    }
}

# ---------- ⑤ 新鲜度报告 ----------
$headHash = git rev-parse --short HEAD 2>$null
if (-not $headHash) { $headHash = 'no-commit' }
$headDate = git log -1 --format=%cd --date=short 2>$null
if (-not $headDate) { $headDate = '-' }

Write-Host ''
Write-Host "📂 心智库：$repoDir"
if ($instantiated) { Write-Host "👤 人格：$PersonaName" }
Write-Host "🧠 记忆新鲜度：截至 $headHash（$headDate）"
if ($pulled -ne 'yes') { Write-Host '⚠️  本次未成功同步远端 —— 上面这个新鲜度只是本地副本状态，未必等于远端最新' }
if ($hasCreds -and -not $tokenOk) { Write-Host '   ↳ 根因：凭证预检未通过（见上方告警），网络操作已整体跳过' }
if ($tokenOk -and $VisionOn -eq '1' -and -not $visionOk) { Write-Host '   ↳ 提醒：图库 token 不可达，vision.sh 本次不可用' }

$StateFile = if ($env:MINDSEED_WAKE_STATE) { $env:MINDSEED_WAKE_STATE } else { Join-Path $repoDir '.mindseed-wake-state.txt' }
if (Test-Path $StateFile) {
    $last = (Get-Content $StateFile -Raw -ErrorAction SilentlyContinue)
    if ($last) { $last = $last.Trim() }
    if ($last -and $last -ne $headHash) {
        git cat-file -e $last 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '📜 自上次唤醒以来的变化：'
            git log --format='  %h %s' "$last..HEAD" | Select-Object -First 10
        }
    }
} else {
    Write-Host '📜 最近 3 条记忆动态：'
    git log --format='  %h %s' -3 2>$null
}
Set-Content -Path $StateFile -Value $headHash -NoNewline -ErrorAction SilentlyContinue

# ---------- ⑥ 隐私防呆 ----------
if (git ls-files | Select-String -Pattern 'user-profile' -Quiet) {
    Write-Warn '隐私文件 user-profile 被跟踪！立即停止写入并排查！'
}

# ---------- ⑦ 唤醒指引 ----------
Write-Host ''
if (-not $instantiated) {
    Write-Host '🌱 当前是模板态（mind.config 仍为占位符）'
    Write-Host '📖 请读 START-HERE.md，按 99-系统/首次唤醒引导.md 完成首次构建；构建完成前不要写入记忆。'
} else {
    Write-Host '📖 请按顺序读取：SOUL.md → HOME.md → 按话题按需检索（禁止全文通读）'
    Write-Host '   线程类型 → 读取范围见 99-系统/唤醒协议.md'
    Write-Host '✨ 心智库已就绪。'
}
