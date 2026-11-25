<#
.SYNOPSIS
  构建打进桌面端「本机」插槽包的网关镜像 knowwork-gateway-cowork:v0.1.2（可重复跑）。

.DESCRIPTION
  插槽包（@knowwork/desktop-web）在 cowork 仓库，网关镜像却从 knowwork 仓库的 web/ 构建：
  1. 把 cowork 仓库的 desktop/web-extension 整个拷到 knowwork 的 web/.extensions/desktop-web（gitignore 掉的临时目录）；
  2. 用 docker-compose.yml + docker-compose.cowork.yml 构建 gateway（KNOWWORK_WEB_EXTENSIONS 由 compose 的 build args 传）；
  3. 断言镜像里的前端产物带插槽包（能 grep 到 knowwork-desktop-web）——没带上就是构建接线坏了，直接失败。

  普通浏览器里插槽包不登记任何来源（没有 window.knowwork 桥），「本机」入口只在 Electron 桌面应用内出现。
  只构建镜像、不重启部署：替换正在跑的 gateway 由发布步骤（docker compose up -d gateway）负责。

.PARAMETER CoworkRepo
  cowork 仓库路径。缺省用环境变量 KNOWWORK_COWORK_REPO，再缺省 C:\Users\cheng\.cowork。

.PARAMETER Image
  目标镜像标签，默认与 docker-compose.cowork.yml 里 gateway 的 image 一致。

.EXAMPLE
  pwsh -File deploy\build-gateway-cowork.ps1
  pwsh -File deploy\build-gateway-cowork.ps1 -CoworkRepo D:\src\cowork -SkipVerify
#>
[CmdletBinding()]
param(
  [string]$CoworkRepo = $(if ($env:KNOWWORK_COWORK_REPO) { $env:KNOWWORK_COWORK_REPO } else { 'C:\Users\cheng\.cowork' }),
  [string]$Image = 'knowwork-gateway-cowork:v0.1.2',
  [switch]$SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$deployDir = Join-Path $repoRoot 'deploy'
$source = Join-Path $CoworkRepo 'desktop\web-extension'
$target = Join-Path $repoRoot 'web\.extensions\desktop-web'
$marker = 'knowwork-desktop-web'

if (-not (Test-Path (Join-Path $source 'src\index.ts'))) {
  throw "找不到插槽包：$source（用 -CoworkRepo 指定 cowork 仓库路径）"
}
if (-not (Test-Path (Join-Path $repoRoot 'web\.extensions'))) {
  throw "找不到 web\.extensions（缺 .gitkeep 占位？）"
}

# 1. 拷插槽包：先删再拷，重复跑结果一样（不累积旧文件）
Write-Host "[1/3] 拷插槽包 $source -> $target"
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
Copy-Item -Recurse -Force $source $target
if (-not (Test-Path (Join-Path $target 'src\index.ts'))) {
  throw "拷贝后仍找不到 $target\src\index.ts"
}

# 2. 构建 gateway（build args 见 docker-compose.cowork.yml；--project-directory 让相对路径按 deploy/ 解析）
Write-Host "[2/3] docker compose build gateway"
Push-Location $deployDir
try {
  & docker compose -f docker-compose.yml -f docker-compose.cowork.yml build gateway
  if ($LASTEXITCODE -ne 0) { throw "docker compose build gateway 失败（退出码 $LASTEXITCODE）" }
  & docker image inspect $Image --format '{{.Id}}' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "构建后找不到镜像 $Image" }
} finally {
  Pop-Location
}

# 3. 断言插槽包确实进了前端产物（vite 经 @knowwork/extensions 打了它）
if ($SkipVerify) {
  Write-Host "[3/3] 跳过产物断言"
} else {
  Write-Host "[3/3] 断言镜像前端产物带插槽包（grep $marker）"
  $hit = & docker run --rm --entrypoint sh $Image -c "grep -rl $marker /usr/share/nginx/html/assets | head -n 3"
  if ($LASTEXITCODE -ne 0 -or -not $hit) {
    throw "镜像 $Image 的前端产物里没有插槽包（grep $marker 无结果）：KNOWWORK_WEB_EXTENSIONS 接线没生效"
  }
  $hit | ForEach-Object { Write-Host "  $_" }
}

Write-Host "完成：$Image"
