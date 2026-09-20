[CmdletBinding()]
param(
  [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$requiredGameVersion = '1.2.7'

function Resolve-GameRoot([string]$RequestedPath) {
  if ($RequestedPath) {
    $resolved = [System.IO.Path]::GetFullPath($RequestedPath)
    if (Test-Path -LiteralPath (Join-Path $resolved 'Sudoku Mansion.exe')) { return $resolved }
  }
  $registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 5005590',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 5005590',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 5005590'
  )
  foreach ($registryPath in $registryPaths) {
    $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
    if ($item.InstallLocation -and (Test-Path -LiteralPath (Join-Path $item.InstallLocation 'Sudoku Mansion.exe'))) {
      return [System.IO.Path]::GetFullPath($item.InstallLocation)
    }
  }
  foreach ($fallback in @(
    'C:\Program Files (x86)\Steam\steamapps\common\Sudoku Mansion',
    'C:\Program Files\Steam\steamapps\common\Sudoku Mansion',
    'D:\SteamLibrary\steamapps\common\Sudoku Mansion'
  )) {
    if (Test-Path -LiteralPath (Join-Path $fallback 'Sudoku Mansion.exe')) {
      return [System.IO.Path]::GetFullPath($fallback)
    }
  }
  throw '未找到《Sudoku Mansion》的安装目录。'
}

$GameRoot = Resolve-GameRoot $GameRoot
$gameVersion = (Get-Item -LiteralPath (Join-Path $GameRoot 'Sudoku Mansion.exe')).VersionInfo.FileVersion
if ($gameVersion -ne $requiredGameVersion -and -not $gameVersion.StartsWith($requiredGameVersion + '.')) {
  throw "还原程序仅支持游戏 $requiredGameVersion；当前检测到 $gameVersion。请使用对应版本的还原程序。"
}
$resourcesRoot = Join-Path $GameRoot 'resources'
$browserRoot = Join-Path $resourcesRoot 'frontend\dist\browser'
$backup = Get-ChildItem -LiteralPath $resourcesRoot -Directory -Filter "zh-cn-backup-$requiredGameVersion-*" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $backup) {
  throw "没有找到游戏 $requiredGameVersion 的英文原版备份。"
}

Copy-Item -LiteralPath (Join-Path $backup.FullName 'frontend\dist\browser\index.html') -Destination (Join-Path $browserRoot 'index.html') -Force
Copy-Item -LiteralPath (Join-Path $backup.FullName 'frontend\dist\browser\assets\mansion.json') -Destination (Join-Path $browserRoot 'assets\mansion.json') -Force
Copy-Item -LiteralPath (Join-Path $backup.FullName 'backend\data\mansions\mansion_default.json') -Destination (Join-Path $resourcesRoot 'backend\data\mansions\mansion_default.json') -Force
Remove-Item -LiteralPath (Join-Path $browserRoot 'zh-cn-patch.js') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $browserRoot 'zh-cn-patch.css') -Force -ErrorAction SilentlyContinue

Write-Host '已恢复英文原版文件。' -ForegroundColor Green
Write-Host "使用的备份：$($backup.FullName)"
