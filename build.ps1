# UPlayer Release 构建脚本
# 直接执行此脚本即可：
#   1. 固定切换为 Release 签名
#   2. 使用 release 构建模式
#   3. 输出签名 .app 包

$ErrorActionPreference = "Stop"
$root = "D:\UPlayer"
$profile = Join-Path $root "build-profile.json5"
$node = "D:\DevEco Studio\tools\node\node.exe"
$hvigorw = "D:\DevEco Studio\tools\hvigor\bin\hvigorw.js"
$env:DEVECO_SDK_HOME = "D:\DevEco Studio\sdk"

# ---------- 1. 固定使用 Release 签名 ----------
$content = [System.IO.File]::ReadAllText($profile)
$new = $content -replace '"signingConfig":\s*"(?:debug|release)"', '"signingConfig": "release"'

if ($new -ne $content) {
  [System.IO.File]::WriteAllText($profile, $new, [System.Text.UTF8Encoding]::new($false))
  Write-Host "[sign] 已切换到 Release 签名 (发布Release.p7b)" -ForegroundColor Yellow
} else {
  Write-Host "[sign] 当前已使用 Release 签名" -ForegroundColor Yellow
}

# ---------- 2. 使用 Release 模式构建 APP ----------
Write-Host "`n[build] 开始构建 Release .app ..." -ForegroundColor Cyan
& $node $hvigorw -p product=default -p buildMode=release assembleApp --no-daemon

if ($LASTEXITCODE -ne 0) {
  throw "Release 构建失败，退出码：$LASTEXITCODE"
}

$out = Join-Path $root "build\outputs\default\UPlayer-default-signed.app"
Write-Host "`n[输出] Release .app: $out" -ForegroundColor Green
Read-Host "构建完成，按 Enter 键退出"
