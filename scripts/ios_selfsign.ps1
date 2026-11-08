#Requires -Version 5.1
<#
.SYNOPSIS
  在 Windows 上取到未签名的 iOS 包，并用你自己的 Apple ID 自签安装。

.DESCRIPTION
  iOS 的包只能在 macOS 上编出来，所以这条链路是：
    1. 触发 GitHub Actions 的 ios-unsigned.yml（macOS runner）
    2. 等它跑完，把 fqapp_ios_unsigned.ipa 下到本地
    3. 校验收到的确实是一个合法 IPA（Payload/Runner.app/Info.plist）
    4. 打开目录并提示用 Sideloadly 自签 —— 签名必须你自己做，
       因为它要你的 Apple ID 和手机，脚本不碰这两样东西。

  没有 gh CLI 时不报错，只打印手动步骤并打开 Actions 页面。

.EXAMPLE
  .\scripts\ios_selfsign.ps1 -Repo yourname/fqapp
.EXAMPLE
  .\scripts\ios_selfsign.ps1 -Repo yourname/fqapp -SkipBuild   # 只下载最近一次成功的包
#>
[CmdletBinding()]
param(
  [string]$Repo = "",
  [string]$Workflow = "ios-unsigned.yml",
  [string]$OutDir = "build\ios-ipa",
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$text) {
  Write-Host ""
  Write-Host "== $text" -ForegroundColor Cyan
}

function Resolve-Repo {
  if ($Repo) { return $Repo }
  $remote = git config --get remote.origin.url 2>$null
  if (-not $remote) { return "" }
  $remote = "$remote".Trim()
  if ($remote -match 'github\.com[:/]([^/]+)/([^/.]+)') {
    return "$($Matches[1])/$($Matches[2])"
  }
  return ""
}

function Get-Gh {
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Wait-Run([string]$gh, [string]$repo, [int]$runId) {
  Write-Host "等待构建完成（首次要编 Rust + Pod，通常 15-25 分钟）..."
  & $gh run watch $runId --repo $repo --interval 30 | Out-Null
  $status = & $gh run view $runId --repo $repo --json conclusion --jq '.conclusion'
  return "$status".Trim()
}

function Get-Ipa([string]$gh, [string]$repo, [int]$runId, [string]$out) {
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Path $out -Force | Out-Null
  & $gh run download $runId --repo $repo -D $out
  return Get-ChildItem -Path $out -Recurse -Filter *.ipa | Select-Object -First 1
}

function Test-Ipa([System.IO.FileInfo]$ipa) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ipa.FullName)
  try {
    $names = $zip.Entries | ForEach-Object { $_.FullName }
    $hasPayload = @($names | Where-Object { $_ -eq 'Payload/Runner.app/Info.plist' }).Count -gt 0
    $hasBinary = @($names | Where-Object { $_ -eq 'Payload/Runner.app/Runner' }).Count -gt 0
    $count = $names.Count
  } finally {
    $zip.Dispose()
  }
  return [pscustomobject]@{
    PayloadOk = $hasPayload
    BinaryOk  = $hasBinary
    Entries   = $count
  }
}

function Show-SignSteps([string]$ipaPath) {
  Write-Step "下一步：用你自己的 Apple ID 自签"
  Write-Host -ForegroundColor Gray @"
  1. 装 Sideloadly（https://sideloadly.io），iPhone 用数据线连电脑并「信任此电脑」。
  2. Sideloadly 的 IPA 框里选这个文件：
       $ipaPath
  3. Apple ID 填你的账号，免费账号也能签（有效期 7 天）。
  4. 点 Start，按提示输入密码。装完第一次打开前，在手机上：
       设置 - 通用 - VPN与设备管理 - 开发者App - 信任你的账号
  5. 若闪退或提示未受信任，重跑第 4 步；7 天后失效，重签即可。
"@
}

# ---------------------------------------------------------------------------

$repo = Resolve-Repo
$gh = Get-Gh

if (-not $repo) {
  Write-Warning "没认出 GitHub 仓库。用 -Repo owner/name 指定。"
}

if (-not $gh) {
  Write-Step "没装 gh CLI，改走手动路径"
  Write-Host "  1. 打开 Actions 页面：" -NoNewline
  if ($repo) {
    $url = "https://github.com/$repo/actions/workflows/$Workflow"
    Write-Host $url
    Start-Process $url
  } else {
    Write-Host "(仓库未识别)"
  }
  Write-Host "  2. Run workflow，等绿灯，下载 Artifacts 里的 fqapp-ios-unsigned-*.zip"
  Write-Host "  3. 解压得到 fqapp_ios_unsigned.ipa，再用 Sideloadly 自签。"
  Show-SignSteps "<你下载到的 fqapp_ios_unsigned.ipa>"
  exit 0
}

if (-not $repo) { throw "已装 gh，但没有仓库名；用 -Repo owner/name 指定。" }

$runId = $null
if (-not $SkipBuild) {
  Write-Step "触发构建 $Workflow @ $repo"
  & $gh workflow run $Workflow --repo $repo
  if ($LASTEXITCODE -ne 0) { throw "触发失败（仓库里还没有这个 workflow？先 push 一次）" }
  Start-Sleep -Seconds 8
  $runs = & $gh run list --repo $repo --workflow $Workflow --limit 5 --json databaseId,createdAt | ConvertFrom-Json
  $runId = ($runs | Sort-Object createdAt -Descending | Select-Object -First 1).databaseId
  if (-not $runId) { throw "没找到刚触发的运行记录，去 Actions 页面确认。" }

  $conclusion = Wait-Run $gh $repo $runId
  if ($conclusion -ne 'success') {
    throw "构建没成功（$conclusion）。日志：gh run view $runId --repo $repo --log-failed"
  }
} else {
  Write-Step "取最近一次成功的构建"
  $runs = & $gh run list --repo $repo --workflow $Workflow --limit 10 --json databaseId,conclusion,createdAt | ConvertFrom-Json
  $run = $runs | Where-Object { $_.conclusion -eq 'success' } |
    Sort-Object createdAt -Descending | Select-Object -First 1
  if (-not $run) { throw "还没有成功过的构建，去掉 -SkipBuild 先跑一次。" }
  $runId = $run.databaseId
}

$ipa = Get-Ipa $gh $repo $runId $OutDir
if (-not $ipa) { throw "artifact 里没有 .ipa。" }

$check = Test-Ipa $ipa
if (-not ($check.PayloadOk -and $check.BinaryOk)) {
  throw "IPA 结构不对（PayloadOk=$($check.PayloadOk) BinaryOk=$($check.BinaryOk)）"
}

$hash = (Get-FileHash $ipa.FullName -Algorithm SHA256).Hash
Write-Step "拿到包了"
Write-Host ("  文件: {0}" -f $ipa.FullName)
Write-Host ("  大小: {0:N1} MB / {1} 个条目" -f ($ipa.Length / 1MB), $check.Entries)
Write-Host ("  SHA256: {0}" -f $hash)

$sideloadly = @(
  "$env:LOCALAPPDATA\Programs\Sideloadly\sideloadly.exe",
  "$env:ProgramFiles\Sideloadly\sideloadly.exe",
  "${env:ProgramFiles(x86)}\Sideloadly\sideloadly.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

Show-SignSteps $ipa.FullName

if ($sideloadly) {
  Write-Host ""
  Write-Host "  检测到 Sideloadly，正在打开..." -ForegroundColor Green
  Start-Process $sideloadly
} else {
  Write-Host ""
  Write-Host "  没检测到 Sideloadly：https://sideloadly.io" -ForegroundColor Yellow
}

Invoke-Item $ipa.DirectoryName
