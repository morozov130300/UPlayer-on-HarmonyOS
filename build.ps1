# UPlayer 构建脚本：一键切换 Debug/Release 签名并编译
# 用法：
#   .\build.ps1 -Mode debug      # 切换到 Debug 签名，打 HAP（真机运行）
#   .\build.ps1 -Mode release    # 切换到 Release 签名，打 .app（上传 AGC）
# 不带参数默认 release

param(
  [ValidateSet("debug", "release")]
  [string]$Mode = "release"
)

$ErrorActionPreference = "Stop"
$root = "D:\UPlayer"
$profile = Join-Path $root "build-profile.json5"
$node = "D:\DevEco Studio\tools\node\node.exe"
$hvigorw = "D:\DevEco Studio\tools\hvigor\bin\hvigorw.js"
$env:DEVECO_SDK_HOME = "D:\DevEco Studio\sdk"

# ---------- 1. 切换 signingConfig ----------
$content = [System.IO.File]::ReadAllText($profile)
$enc = New-Object System.Text.UTF8Encoding($false)

if ($Mode -eq "release") {
  $new = $content -replace '"signingConfig": "debug"', '"signingConfig": "default"'
  Write-Host "[sign] 已切换到 Release 签名 (ACLtestRelease.p7b)"
} else {
  $new = $content -replace '"signingConfig": "default"', '"signingConfig": "debug"'
  Write-Host "[sign] 已切换到 Debug 签名 (自动生成)"
}

if ($new -ne $content) {
  [System.IO.File]::WriteAllText($profile, $new, $enc)
  Write-Host "[sign] build-profile.json5 已更新"
} else {
  Write-Host "[sign] 签名配置无需变更"
}

# ---------- 2. 编译 ----------
if ($Mode -eq "release") {
  Write-Host "[build] 开始构建 Release .app ..."
  & $node $hvigorw -p product=default -p buildMode=release assembleApp --no-daemon
  $out = Join-Path $root "build\outputs\default\UPlayer-default-signed.app"
  Write-Host "`n[输出] Release .app: $out" -ForegroundColor Green
} else {
  Write-Host "[build] 开始构建 Debug HAP ..."
  & $node $hvigorw --mode module -p product=default assembleHap --no-daemon
  $out = Join-Path $root "entry\build\default\outputs\default\entry-default-signed.hap"
  Write-Host "`n[输出] Debug HAP: $out" -ForegroundColor Green
}
