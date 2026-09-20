[CmdletBinding()]
param(
  [string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$requiredGameVersion = '1.2.7'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$patchRoot = Join-Path $scriptRoot 'patch'

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

  $fallbacks = @(
    'C:\Program Files (x86)\Steam\steamapps\common\Sudoku Mansion',
    'C:\Program Files\Steam\steamapps\common\Sudoku Mansion',
    'D:\SteamLibrary\steamapps\common\Sudoku Mansion'
  )
  foreach ($fallback in $fallbacks) {
    if (Test-Path -LiteralPath (Join-Path $fallback 'Sudoku Mansion.exe')) {
      return [System.IO.Path]::GetFullPath($fallback)
    }
  }

  throw '未找到《Sudoku Mansion》的安装目录。请在 PowerShell 中使用 -GameRoot 参数指定目录。'
}

function Get-TextHash([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-Utf8([string]$Path) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  return [System.IO.File]::ReadAllText($Path, $encoding)
}

$script:TranslatableFields = New-Object 'System.Collections.Generic.HashSet[string]'
@('name', 'title', 'description', 'text', 'rules', 'hint', 'label', 'canvasTutorial', 'roomCanvasTutorial', 'unlockPopupText') |
  ForEach-Object { [void]$script:TranslatableFields.Add($_) }
$script:Translations = @{}
$script:ReplacementCount = 0

function Update-Node($Node, [string]$Path) {
  if ($null -eq $Node) { return }

  if ($Node -is [System.Collections.IList] -and -not ($Node -is [string])) {
    for ($index = 0; $index -lt $Node.Count; $index++) {
      Update-Node $Node[$index] ($Path + '[' + $index + ']')
    }
    return
  }

  if ($Node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($property in @($Node.PSObject.Properties)) {
      $name = $property.Name
      $value = $property.Value
      $mediaName = $name -eq 'name' -and $Path -match '\.(?:images|audio)\[\d+\]$'
      if ($value -is [string] -and $script:TranslatableFields.Contains($name) -and -not $mediaName) {
        $hash = Get-TextHash $value
        if ($script:Translations.ContainsKey($hash)) {
          $property.Value = $script:Translations[$hash]
          $script:ReplacementCount++
        }
      } else {
        Update-Node $value ($Path + '.' + $name)
      }
    }
  }
}

function Convert-GameJson([string]$Path, [int]$ExpectedCount) {
  $data = Read-Utf8 $Path | ConvertFrom-Json
  $script:ReplacementCount = 0
  Update-Node $data '$'
  if ($script:ReplacementCount -ne $ExpectedCount) {
    throw "文本匹配数量异常：$Path；预期 $ExpectedCount，实际 $script:ReplacementCount。游戏文件可能已更新或被其他模组修改。"
  }
  return (($data | ConvertTo-Json -Depth 100) + "`r`n")
}

$GameRoot = Resolve-GameRoot $GameRoot
$exePath = Join-Path $GameRoot 'Sudoku Mansion.exe'
$gameVersion = (Get-Item -LiteralPath $exePath).VersionInfo.FileVersion
if ($gameVersion -ne $requiredGameVersion -and -not $gameVersion.StartsWith($requiredGameVersion + '.')) {
  throw "补丁仅支持游戏 $requiredGameVersion；当前检测到 $gameVersion。"
}

$resourcesRoot = Join-Path $GameRoot 'resources'
$browserRoot = Join-Path $resourcesRoot 'frontend\dist\browser'
$frontendJson = Join-Path $browserRoot 'assets\mansion.json'
$backendJson = Join-Path $resourcesRoot 'backend\data\mansions\mansion_default.json'
$indexPath = Join-Path $browserRoot 'index.html'
$manifest = Read-Utf8 (Join-Path $patchRoot 'manifest.json') | ConvertFrom-Json
$translationData = Read-Utf8 (Join-Path $patchRoot 'translations.json') | ConvertFrom-Json

foreach ($entry in $translationData.entries) {
  $script:Translations[$entry.hash] = $entry.target
}

$currentIndex = Get-Content -Raw -LiteralPath $indexPath
if ($currentIndex.Contains('zh-cn-patch.js')) {
  Write-Host '检测到汉化已经安装，无需重复操作。' -ForegroundColor Yellow
  exit 0
}

$sourceFiles = @{
  frontendJson = $frontendJson
  backendJson = $backendJson
  index = $indexPath
}
foreach ($name in $sourceFiles.Keys) {
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFiles[$name]).Hash.ToLowerInvariant()
  $expectedHash = [string]$manifest.originalHashes.$name
  if ($actualHash -ne $expectedHash) {
    throw "原文件校验失败：$($sourceFiles[$name])。请先在 Steam 中验证游戏文件，再重新安装汉化。"
  }
}

$expectedCount = [int]$manifest.expectedJsonReplacementsPerFile
$newFrontendJson = Convert-GameJson $frontendJson $expectedCount
$newBackendJson = Convert-GameJson $backendJson $expectedCount
$newIndex = $currentIndex.Replace('<html lang="en"', '<html lang="zh-CN"')
$newIndex = $newIndex.Replace('<title>Sudoku Mansion</title>', '<title>数独庄园</title>')
$newIndex = $newIndex.Replace(
  '<link rel="icon" type="image/x-icon" href="favicon.ico">',
  '<link rel="icon" type="image/x-icon" href="favicon.ico">' + "`r`n    " + '<link rel="stylesheet" href="zh-cn-patch.css">'
)
$newIndex = [regex]::Replace(
  $newIndex,
  '<script src="(polyfills-[^"]+\.js)" type="module"></script>',
  '<script src="zh-cn-patch.js"></script><script src="$1" type="module"></script>',
  1
)
if (-not $newIndex.Contains('zh-cn-patch.js') -or -not $newIndex.Contains('zh-cn-patch.css')) {
  throw '无法把汉化运行脚本加入游戏入口文件。'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $resourcesRoot ("zh-cn-backup-$requiredGameVersion-" + $stamp)
New-Item -ItemType Directory -Path (Join-Path $backupRoot 'frontend\dist\browser\assets') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $backupRoot 'backend\data\mansions') -Force | Out-Null
Copy-Item -LiteralPath $indexPath -Destination (Join-Path $backupRoot 'frontend\dist\browser\index.html')
Copy-Item -LiteralPath $frontendJson -Destination (Join-Path $backupRoot 'frontend\dist\browser\assets\mansion.json')
Copy-Item -LiteralPath $backendJson -Destination (Join-Path $backupRoot 'backend\data\mansions\mansion_default.json')

try {
  Write-Utf8NoBom $frontendJson $newFrontendJson
  Write-Utf8NoBom $backendJson $newBackendJson
  Write-Utf8NoBom $indexPath $newIndex
  Copy-Item -LiteralPath (Join-Path $patchRoot 'zh-cn-patch.js') -Destination (Join-Path $browserRoot 'zh-cn-patch.js') -Force
  Copy-Item -LiteralPath (Join-Path $patchRoot 'zh-cn-patch.css') -Destination (Join-Path $browserRoot 'zh-cn-patch.css') -Force
} catch {
  Copy-Item -LiteralPath (Join-Path $backupRoot 'frontend\dist\browser\index.html') -Destination $indexPath -Force
  Copy-Item -LiteralPath (Join-Path $backupRoot 'frontend\dist\browser\assets\mansion.json') -Destination $frontendJson -Force
  Copy-Item -LiteralPath (Join-Path $backupRoot 'backend\data\mansions\mansion_default.json') -Destination $backendJson -Force
  Remove-Item -LiteralPath (Join-Path $browserRoot 'zh-cn-patch.js') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $browserRoot 'zh-cn-patch.css') -Force -ErrorAction SilentlyContinue
  throw
}

Write-Host '《Sudoku Mansion》简体中文汉化安装完成。' -ForegroundColor Green
Write-Host "适用游戏版本：$requiredGameVersion"
Write-Host "原文件备份：$backupRoot"
Write-Host '请从 Steam 正常启动游戏。'
