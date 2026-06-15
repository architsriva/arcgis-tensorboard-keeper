<#
.SYNOPSIS
Interactively archives a live TensorBoard dashboard as a relaunchable local copy.

.DESCRIPTION
This script is designed for ArcGIS Pro deep learning workflows where the Train Deep Learning Model tool
emits a temporary TensorBoard URL. It reads the source TensorBoard data_location, copies the reported
training_log directory, verifies file hashes, relaunches the copied dashboard on a new port, and compares
source-vs-copy runs and enabled TensorBoard tabs before updating the archive index.

.PARAMETER Url
The live TensorBoard URL to archive. If omitted, the script asks for it interactively.

.PARAMETER ArchiveRoot
The folder where archives and generated index files are stored. Defaults to an ignored archives folder
beside this repository's tools folder.

.PARAMETER TrainingNote
A short note describing the training run. If omitted, the script asks for it interactively.

.PARAMETER FolderName
The archive folder name. If omitted, the script suggests names and asks you to choose one.

.PARAMETER Port
The local port for the copied dashboard. If omitted or 0, the script picks the next available port.

.PARAMETER NoOpenAfterSuccess
Skips the final prompt to open the copied dashboard in a browser.
#>

param(
  [string]$Url,
  [string]$ArchiveRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "archives"),
  [string]$TrainingNote,
  [string]$FolderName,
  [int]$Port = 0,
  [switch]$NoOpenAfterSuccess
)

$ErrorActionPreference = "Stop"

function Ask-Text {
  param(
    [string]$Question,
    [string]$Default = "",
    [switch]$Required
  )

  while ($true) {
    if ([string]::IsNullOrWhiteSpace($Default)) {
      $answer = Read-Host $Question
    } else {
      $answer = Read-Host "$Question [$Default]"
      if ([string]::IsNullOrWhiteSpace($answer)) {
        $answer = $Default
      }
    }

    if (!$Required -or ![string]::IsNullOrWhiteSpace($answer)) {
      return $answer.Trim()
    }

    Write-Host "Please enter a value." -ForegroundColor Yellow
  }
}

function Ask-YesNo {
  param(
    [string]$Question,
    [bool]$DefaultYes = $true
  )

  $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
  while ($true) {
    $answer = (Read-Host "$Question $suffix").Trim()
    if ([string]::IsNullOrWhiteSpace($answer)) {
      return $DefaultYes
    }
    if ($answer -match "^(y|yes)$") { return $true }
    if ($answer -match "^(n|no)$") { return $false }
    Write-Host "Please answer yes or no." -ForegroundColor Yellow
  }
}

function ConvertTo-SafeName {
  param([string]$Text)
  $name = $Text
  $name = $name -replace "Mask\s+R-CNN", "MaskRCNN"
  $name = $name -replace "Faster\s+R-CNN", "FasterRCNN"
  $name = $name -replace "TensorBoard", ""
  $name = $name -replace "^\s*Trains?\s+", ""
  $name = $name -replace "[^A-Za-z0-9]+", "_"
  $name = $name.Trim("_")
  $name = $name -replace "_+", "_"
  if ($name.Length -gt 95) {
    $name = $name.Substring(0, 95).Trim("_")
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = "TensorBoard_Archive"
  }
  return $name
}

function Get-FolderNameSuggestions {
  param(
    [string]$Note,
    [string]$SourceLogdir,
    [string]$SourceUrl
  )

  $suggestions = New-Object System.Collections.Generic.List[string]
  $baseFromNote = ConvertTo-SafeName -Text $Note
  $suggestions.Add("${baseFromNote}_TensorBoard") | Out-Null

  if (![string]::IsNullOrWhiteSpace($SourceLogdir)) {
    $parentName = Split-Path (Split-Path $SourceLogdir -Parent) -Leaf
    if (![string]::IsNullOrWhiteSpace($parentName)) {
      $suggestions.Add("$(ConvertTo-SafeName -Text $parentName)_TensorBoard") | Out-Null
    }
  }

  try {
    $uri = [Uri]$SourceUrl
    $portPart = if ($uri.Port -gt 0) { "_SourcePort$($uri.Port)" } else { "" }
    $datePart = Get-Date -Format "yyyyMMdd_HHmm"
    $suggestions.Add("${baseFromNote}${portPart}_Captured_$datePart`_TensorBoard") | Out-Null
  } catch {
    $datePart = Get-Date -Format "yyyyMMdd_HHmm"
    $suggestions.Add("${baseFromNote}_Captured_$datePart`_TensorBoard") | Out-Null
  }

  return @($suggestions | Select-Object -Unique)
}

function ConvertTo-PSStringLiteral {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) { $Text = "" }
  return "'" + $Text.Replace("'", "''") + "'"
}

function Get-UrlParts {
  param([string]$InputUrl)
  $uri = [Uri]$InputUrl
  $prefix = ""
  if (![string]::IsNullOrWhiteSpace($uri.AbsolutePath) -and $uri.AbsolutePath -ne "/") {
    $prefix = $uri.AbsolutePath.TrimEnd("/")
  }
  $apiBase = "$($uri.Scheme)://$($uri.Authority)$prefix"
  $suffix = "$($uri.PathAndQuery)$($uri.Fragment)"
  if ([string]::IsNullOrWhiteSpace($suffix) -or $suffix -eq "/") {
    $suffix = "/#timeseries"
  }
  return [pscustomobject]@{
    ApiBase = $apiBase
    UrlSuffix = $suffix
  }
}

function Invoke-JsonEndpoint {
  param(
    [string]$Endpoint,
    [string]$Purpose
  )

  $lastError = $null
  foreach ($attempt in 1..5) {
    try {
      return Invoke-RestMethod -Uri $Endpoint -TimeoutSec 10
    } catch {
      $lastError = $_
      Start-Sleep -Seconds 2
    }
  }
  throw "Could not query $Purpose at $Endpoint. Last error: $($lastError.Exception.Message)"
}

function Get-EnabledPlugins {
  param([object]$PluginsListing)
  $enabled = New-Object System.Collections.Generic.List[string]
  foreach ($property in $PluginsListing.PSObject.Properties) {
    if ($property.Value.enabled -eq $true) {
      $enabled.Add([string]$property.Name) | Out-Null
    }
  }
  return @($enabled | Sort-Object)
}

function Get-TensorBoardSiteInfo {
  param([string]$SiteUrl)
  $parts = Get-UrlParts -InputUrl $SiteUrl
  $environment = Invoke-JsonEndpoint -Endpoint "$($parts.ApiBase)/data/environment" -Purpose "TensorBoard environment"
  $runs = Invoke-JsonEndpoint -Endpoint "$($parts.ApiBase)/data/runs" -Purpose "TensorBoard runs"
  $plugins = Invoke-JsonEndpoint -Endpoint "$($parts.ApiBase)/data/plugins_listing" -Purpose "TensorBoard plugins"

  $dataLocation = ""
  if ($environment.PSObject.Properties.Name -contains "data_location") {
    $dataLocation = [string]$environment.data_location
  }

  return [pscustomobject]@{
    Url = $SiteUrl
    ApiBase = $parts.ApiBase
    UrlSuffix = $parts.UrlSuffix
    DataLocation = $dataLocation
    Runs = @($runs | ForEach-Object { [string]$_ } | Sort-Object)
    EnabledPlugins = @(Get-EnabledPlugins -PluginsListing $plugins)
    Environment = $environment
    PluginsListing = $plugins
  }
}

function Test-PortInUse {
  param([int]$PortToCheck)
  try {
    $listeners = Get-NetTCPConnection -LocalPort $PortToCheck -State Listen -ErrorAction SilentlyContinue
    if (@($listeners).Count -gt 0) { return $true }
  } catch {}

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", $PortToCheck, $null, $null)
    $connected = $iar.AsyncWaitHandle.WaitOne(300, $false)
    if ($connected) {
      $client.EndConnect($iar)
      return $true
    }
    return $false
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Get-ExistingArchivePorts {
  param([string]$Root)
  $ports = New-Object System.Collections.Generic.List[int]
  if (!(Test-Path -LiteralPath $Root)) { return @() }

  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $manifestPath = Join-Path $_.FullName "manifest.json"
    if (!(Test-Path -LiteralPath $manifestPath)) {
      $manifestPath = Join-Path $_.FullName "interactive_manifest.json"
    }
    if (Test-Path -LiteralPath $manifestPath) {
      try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.default_port) {
          $ports.Add([int]$manifest.default_port) | Out-Null
        }
      } catch {}
    }

    $launcher = Join-Path $_.FullName "start.ps1"
    if (!(Test-Path -LiteralPath $launcher)) {
      $launcher = Join-Path $_.FullName "Start-InteractiveTensorBoard.ps1"
    }
    if (Test-Path -LiteralPath $launcher) {
      $text = Get-Content -LiteralPath $launcher -Raw
      $match = [regex]::Match($text, "\[int\]\`$Port\s*=\s*(\d+)")
      if ($match.Success) {
        $ports.Add([int]$match.Groups[1].Value) | Out-Null
      }
    }
  }

  return @($ports | Sort-Object -Unique)
}

function Get-NextArchivePort {
  param([string]$Root)
  $existing = @(Get-ExistingArchivePorts -Root $Root)
  $candidate = 6006
  if ($existing.Count -gt 0) {
    $candidate = ([int](($existing | Measure-Object -Maximum).Maximum)) + 1
  }
  while (Test-PortInUse -PortToCheck $candidate) {
    $candidate += 1
  }
  return $candidate
}

function Assert-ChildPath {
  param(
    [string]$Parent,
    [string]$Child
  )
  $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\") + "\"
  $childFull = [System.IO.Path]::GetFullPath($Child)
  if (!$childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to operate outside archive root. Parent: $parentFull Child: $childFull"
  }
}

function Copy-Logdir {
  param(
    [string]$Source,
    [string]$Destination
  )

  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  & robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NFL /NDL /NP
  $code = $LASTEXITCODE
  if ($code -ge 8) {
    throw "robocopy failed with exit code $code"
  }
}

function Get-FileInventory {
  param([string]$Root)
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\")
  $items = New-Object System.Collections.Generic.List[object]
  if (!(Test-Path -LiteralPath $Root)) {
    return @()
  }

  $files = Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($rootFull.Length).TrimStart("\")
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    $items.Add([pscustomobject]@{
      RelativePath = $relative
      Length = [int64]$file.Length
      SHA256 = $hash.Hash
    }) | Out-Null
  }
  return @($items)
}

function Compare-Inventory {
  param(
    [object[]]$SourceInventory,
    [object[]]$CopiedInventory
  )

  $sourceMap = @{}
  foreach ($item in $SourceInventory) { $sourceMap[$item.RelativePath] = $item }
  $copiedMap = @{}
  foreach ($item in $CopiedInventory) { $copiedMap[$item.RelativePath] = $item }

  $mismatches = New-Object System.Collections.Generic.List[object]
  foreach ($key in $sourceMap.Keys) {
    if (!$copiedMap.ContainsKey($key)) {
      $mismatches.Add([pscustomobject]@{ RelativePath = $key; Status = "MissingInCopy" }) | Out-Null
      continue
    }
    if ($sourceMap[$key].SHA256 -ne $copiedMap[$key].SHA256 -or $sourceMap[$key].Length -ne $copiedMap[$key].Length) {
      $mismatches.Add([pscustomobject]@{
        RelativePath = $key
        Status = "Different"
        SourceLength = $sourceMap[$key].Length
        CopiedLength = $copiedMap[$key].Length
        SourceSHA256 = $sourceMap[$key].SHA256
        CopiedSHA256 = $copiedMap[$key].SHA256
      }) | Out-Null
    }
  }
  foreach ($key in $copiedMap.Keys) {
    if (!$sourceMap.ContainsKey($key)) {
      $mismatches.Add([pscustomobject]@{ RelativePath = $key; Status = "ExtraInCopy" }) | Out-Null
    }
  }

  return [pscustomobject]@{
    SourceFiles = @($SourceInventory).Count
    CopiedFiles = @($CopiedInventory).Count
    MismatchCount = @($mismatches).Count
    Mismatches = @($mismatches)
  }
}

function Compare-StringSet {
  param(
    [string[]]$Source,
    [string[]]$Copied
  )
  $sourceSorted = @($Source | Sort-Object)
  $copiedSorted = @($Copied | Sort-Object)
  $missing = @($sourceSorted | Where-Object { $_ -notin $copiedSorted })
  $extra = @($copiedSorted | Where-Object { $_ -notin $sourceSorted })
  return [pscustomobject]@{
    Match = ($missing.Count -eq 0 -and $extra.Count -eq 0)
    MissingInCopy = $missing
    ExtraInCopy = $extra
  }
}

function New-LauncherScripts {
  param(
    [string]$Folder,
    [int]$DefaultPort,
    [string]$UrlSuffix,
    [string]$JunctionName
  )

  $startScript = Join-Path $Folder "start.ps1"
  $batScript = Join-Path $Folder "open.bat"
  $urlSuffixLiteral = ConvertTo-PSStringLiteral -Text $UrlSuffix
  $junctionNameLiteral = ConvertTo-PSStringLiteral -Text $JunctionName

  $template = @'
param(
  [int]$Port = __PORT__,
  [string]$HostName = "localhost",
  [string]$UrlSuffix = __URL_SUFFIX__,
  [switch]$Foreground,
  [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$realLogdir = Join-Path $root "training_log"
$stdoutLog = Join-Path $root "tensorboard_server.stdout.log"
$stderrLog = Join-Path $root "tensorboard_server.stderr.log"
$junctionName = __JUNCTION_NAME__
$tensorboardCandidates = @(
  "C:\Program Files\ArcGIS\Pro\bin\Python\envs\arcgispro-py3\Scripts\tensorboard.exe",
  "D:\Program Files\ArcGIS\Pro\bin\Python\envs\arcgispro-py3\Scripts\tensorboard.exe",
  "tensorboard.exe",
  "tensorboard"
)

function Get-ShortLogdirJunction {
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $tempRoot = [System.IO.Path]::GetTempPath().TrimEnd("\")
  $candidate = Join-Path $tempRoot $Name

  if (Test-Path -LiteralPath $candidate) {
    $item = Get-Item -LiteralPath $candidate -Force
    $isReparsePoint = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    $existingTarget = ""
    try {
      $existingTarget = ($item.Target -join "")
    } catch {}

    if ($isReparsePoint -and $existingTarget -eq $Target) {
      return $candidate
    }

    if ($isReparsePoint) {
      Remove-Item -LiteralPath $candidate -Force
    } else {
      $candidate = Join-Path $tempRoot ("{0}_{1}" -f $Name, $PID)
    }
  }

  New-Item -ItemType Junction -Path $candidate -Target $Target | Out-Null
  return $candidate
}

if (!(Test-Path -LiteralPath $realLogdir)) {
  throw "Missing saved TensorBoard log directory: $realLogdir"
}

$logdir = Get-ShortLogdirJunction -Target $realLogdir -Name $junctionName

$tensorboard = $null
foreach ($candidate in $tensorboardCandidates) {
  if (Test-Path -LiteralPath $candidate) {
    $tensorboard = $candidate
    break
  }
  $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
  if ($cmd) {
    $tensorboard = $cmd.Source
    break
  }
}

if (!$tensorboard) {
  throw "Could not find tensorboard.exe. Install TensorBoard, then run: tensorboard --logdir `"$logdir`" --host $HostName --port $Port"
}

$args = @(
  "--logdir", $logdir,
  "--host", $HostName,
  "--port", $Port.ToString()
)

$url = "http://$HostName`:$Port$UrlSuffix"

Write-Host "TensorBoard executable: $tensorboard"
Write-Host "Saved log directory: $realLogdir"
Write-Host "TensorBoard log directory used: $logdir"
Write-Host "URL: $url"

if ($Foreground) {
  & $tensorboard @args
  exit $LASTEXITCODE
}

$process = Start-Process `
  -FilePath $tensorboard `
  -ArgumentList $args `
  -WorkingDirectory $root `
  -RedirectStandardOutput $stdoutLog `
  -RedirectStandardError $stderrLog `
  -PassThru `
  -WindowStyle Hidden

Start-Sleep -Seconds 4

Write-Host "Started TensorBoard process id $($process.Id)."
Write-Host "Open $url in a browser."
Write-Host "Server stdout log: $stdoutLog"
Write-Host "Server stderr log: $stderrLog"

if (!$NoOpen) {
  Start-Process $url
}
'@

  $content = $template.Replace("__PORT__", [string]$DefaultPort)
  $content = $content.Replace("__URL_SUFFIX__", $urlSuffixLiteral)
  $content = $content.Replace("__JUNCTION_NAME__", $junctionNameLiteral)
  Set-Content -LiteralPath $startScript -Value $content -Encoding UTF8

  $defaultUrl = "http://localhost:$DefaultPort$UrlSuffix"
  $bat = @"
@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%start.ps1" %*
echo.
echo If the browser did not open, go to $defaultUrl
pause
"@
  Set-Content -LiteralPath $batScript -Value $bat -Encoding ASCII

  return [pscustomobject]@{
    StartScript = $startScript
    BatchScript = $batScript
    DefaultUrl = $defaultUrl
  }
}

function Wait-ForTensorBoard {
  param(
    [string]$LocalUrl,
    [int]$TimeoutSeconds = 45
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastError = $null
  while ((Get-Date) -lt $deadline) {
    try {
      $null = Get-TensorBoardSiteInfo -SiteUrl $LocalUrl
      return
    } catch {
      $lastError = $_
      Start-Sleep -Seconds 2
    }
  }
  throw "Copied TensorBoard did not become ready at $LocalUrl. Last error: $($lastError.Exception.Message)"
}

function Write-Json {
  param(
    [string]$Path,
    [object]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 20
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function New-ZipBackup {
  param(
    [string]$ArchiveRoot,
    [string]$FolderPath,
    [string]$FolderName
  )

  $zipPath = Join-Path $ArchiveRoot "$FolderName.zip"
  $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("tb_archive_zip_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
  $stageFolder = Join-Path $stageRoot $FolderName
  try {
    & robocopy $FolderPath $stageFolder /E /XF tensorboard_server.stdout.log tensorboard_server.stderr.log /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
      throw "robocopy staging for ZIP failed with exit code $LASTEXITCODE"
    }
    Compress-Archive -LiteralPath $stageFolder -DestinationPath $zipPath -Force
  } finally {
    if (Test-Path -LiteralPath $stageRoot) {
      Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
  }

  $hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
  $line = "$($hash.Hash)  $FolderName.zip"
  Set-Content -LiteralPath "$zipPath.sha256" -Value $line -Encoding ASCII
  Set-Content -LiteralPath "$zipPath.sha256.txt" -Value $line -Encoding ASCII
  return [pscustomobject]@{
    ZipPath = $zipPath
    SHA256 = $hash.Hash
  }
}

Write-Host ""
Write-Host "TensorBoard interactive archive tool" -ForegroundColor Cyan
Write-Host "This tool copies one live TensorBoard site into a local, relaunchable archive."
Write-Host ""

$Url = Ask-Text -Question "Live TensorBoard URL" -Default $Url -Required
$ArchiveRoot = Ask-Text -Question "Archive root" -Default $ArchiveRoot -Required
$ArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot)

if (!(Test-Path -LiteralPath $ArchiveRoot)) {
  if (Ask-YesNo -Question "Archive root does not exist. Create it?" -DefaultYes $true) {
    New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null
  } else {
    throw "Archive root was not created: $ArchiveRoot"
  }
}

Write-Host ""
Write-Host "Reading source TensorBoard site..." -ForegroundColor Cyan
$sourceInfo = Get-TensorBoardSiteInfo -SiteUrl $Url
if ([string]::IsNullOrWhiteSpace($sourceInfo.DataLocation)) {
  throw "The source TensorBoard site did not report a data_location through /data/environment."
}
if (!(Test-Path -LiteralPath $sourceInfo.DataLocation)) {
  throw "The source TensorBoard data_location is not readable from this machine: $($sourceInfo.DataLocation)"
}
Write-Host "Source logdir: $($sourceInfo.DataLocation)"
Write-Host "Source runs: $(@($sourceInfo.Runs).Count)"
Write-Host "Source enabled tabs: $($sourceInfo.EnabledPlugins -join ', ')"

$TrainingNote = Ask-Text -Question "Training note for this archive" -Default $TrainingNote -Required

$suggestions = @(Get-FolderNameSuggestions -Note $TrainingNote -SourceLogdir $sourceInfo.DataLocation -SourceUrl $Url)
Write-Host ""
Write-Host "Folder name suggestions:" -ForegroundColor Cyan
for ($i = 0; $i -lt $suggestions.Count; $i++) {
  Write-Host "  [$($i + 1)] $($suggestions[$i])"
}

if ([string]::IsNullOrWhiteSpace($FolderName)) {
  while ($true) {
    $choice = Read-Host "Choose 1-$($suggestions.Count), or type a custom folder name"
    if ($choice -match "^\d+$") {
      $index = [int]$choice - 1
      if ($index -ge 0 -and $index -lt $suggestions.Count) {
        $FolderName = $suggestions[$index]
        break
      }
    } elseif (![string]::IsNullOrWhiteSpace($choice)) {
      $FolderName = $choice.Trim()
      break
    }
    Write-Host "Please choose a listed number or type a folder name." -ForegroundColor Yellow
  }
}

$FolderName = ConvertTo-SafeName -Text $FolderName
if ($FolderName -notmatch "_TensorBoard$") {
  $FolderName = "${FolderName}_TensorBoard"
}

$targetFolder = Join-Path $ArchiveRoot $FolderName
while (Test-Path -LiteralPath $targetFolder) {
  Write-Host ""
  Write-Host "Folder already exists: $targetFolder" -ForegroundColor Yellow
  $choice = Read-Host "Type A to abort, N for a new folder name, or O to overwrite"
  if ($choice -match "^(a|abort)$") {
    throw "Stopped before changing existing folder."
  } elseif ($choice -match "^(n|new)$") {
    $FolderName = Ask-Text -Question "New folder name" -Required
    $FolderName = ConvertTo-SafeName -Text $FolderName
    if ($FolderName -notmatch "_TensorBoard$") {
      $FolderName = "${FolderName}_TensorBoard"
    }
    $targetFolder = Join-Path $ArchiveRoot $FolderName
  } elseif ($choice -match "^(o|overwrite)$") {
    if (!(Ask-YesNo -Question "Overwrite this existing archive folder now?" -DefaultYes $false)) {
      continue
    }
    Assert-ChildPath -Parent $ArchiveRoot -Child $targetFolder
    Remove-Item -LiteralPath $targetFolder -Recurse -Force
    break
  } else {
    Write-Host "Please type A, N, or O." -ForegroundColor Yellow
  }
}

if ($Port -le 0) {
  $Port = Get-NextArchivePort -Root $ArchiveRoot
} elseif (Test-PortInUse -PortToCheck $Port) {
  throw "Requested port is already in use: $Port"
}

$junctionSafe = ($FolderName -replace "[^A-Za-z0-9]+", "_")
if ($junctionSafe.Length -gt 40) { $junctionSafe = $junctionSafe.Substring(0, 40).Trim("_") }
$junctionName = "tb_${Port}_$junctionSafe"

Write-Host ""
Write-Host "Archive summary before copy" -ForegroundColor Cyan
Write-Host "  Source URL:   $Url"
Write-Host "  Source log:   $($sourceInfo.DataLocation)"
Write-Host "  Archive root: $ArchiveRoot"
Write-Host "  Folder name:  $FolderName"
Write-Host "  New port:     $Port"
Write-Host "  Local URL:    http://localhost:$Port$($sourceInfo.UrlSuffix)"
Write-Host ""

if (!(Ask-YesNo -Question "Proceed with this archive copy?" -DefaultYes $true)) {
  throw "Stopped before copying."
}

New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
$targetLogdir = Join-Path $targetFolder "training_log"

Write-Host ""
Write-Host "Copying source training_log..." -ForegroundColor Cyan
Copy-Logdir -Source $sourceInfo.DataLocation -Destination $targetLogdir

Write-Host "Hashing source and copied files for exactness check..."
$sourceInventory = @(Get-FileInventory -Root $sourceInfo.DataLocation)
$copiedInventory = @(Get-FileInventory -Root $targetLogdir)
$inventoryComparison = Compare-Inventory -SourceInventory $sourceInventory -CopiedInventory $copiedInventory

if ($inventoryComparison.MismatchCount -gt 0) {
  Write-Host "First exactness check found differences. Copying once more and rechecking..." -ForegroundColor Yellow
  Copy-Logdir -Source $sourceInfo.DataLocation -Destination $targetLogdir
  $sourceInventory = @(Get-FileInventory -Root $sourceInfo.DataLocation)
  $copiedInventory = @(Get-FileInventory -Root $targetLogdir)
  $inventoryComparison = Compare-Inventory -SourceInventory $sourceInventory -CopiedInventory $copiedInventory
}

Write-Json -Path (Join-Path $targetFolder "source_file_inventory.json") -Value $sourceInventory
Write-Json -Path (Join-Path $targetFolder "copied_file_inventory.json") -Value $copiedInventory

if ($inventoryComparison.MismatchCount -gt 0) {
  Write-Json -Path (Join-Path $targetFolder "file_inventory_mismatch.json") -Value $inventoryComparison
  throw "Copied files do not exactly match source files. See file_inventory_mismatch.json in the archive folder."
}

Write-Host "File exactness check passed: $($inventoryComparison.CopiedFiles) copied files match source hashes."

$launcherInfo = New-LauncherScripts -Folder $targetFolder -DefaultPort $Port -UrlSuffix $sourceInfo.UrlSuffix -JunctionName $junctionName

$manifestPath = Join-Path $targetFolder "manifest.json"
$manifest = [ordered]@{
  captured_at = (Get-Date).ToString("o")
  purpose = "Interactive TensorBoard relaunch archive"
  training_note = $TrainingNote
  source_url = $Url
  source_api_base = $sourceInfo.ApiBase
  source_url_suffix = $sourceInfo.UrlSuffix
  original_logdir = $sourceInfo.DataLocation
  saved_logdir = $targetLogdir
  file_count = @($copiedInventory | Where-Object { $_.RelativePath -like "*events.out.tfevents*" }).Count
  total_file_count = @($copiedInventory).Count
  byte_count = [int64](($copiedInventory | Measure-Object Length -Sum).Sum)
  source_run_count = @($sourceInfo.Runs).Count
  source_runs = @($sourceInfo.Runs)
  source_enabled_plugins = @($sourceInfo.EnabledPlugins)
  default_port = $Port
  default_url = $launcherInfo.DefaultUrl
  launcher_script = $launcherInfo.StartScript
  batch_launcher = $launcherInfo.BatchScript
  short_junction_name = $junctionName
  copy_method = "Copied only the source TensorBoard data_location reported by /data/environment, then relaunched from copied event files."
  exact_file_hash_match = $true
  verification_status = "Pending"
}
Write-Json -Path $manifestPath -Value $manifest

Write-Host ""
Write-Host "Starting copied TensorBoard for verification..." -ForegroundColor Cyan
& $launcherInfo.StartScript -Port $Port -NoOpen
$localUrl = $launcherInfo.DefaultUrl
Wait-ForTensorBoard -LocalUrl $localUrl

Write-Host "Comparing source site and copied site..."
$sourceAfter = Get-TensorBoardSiteInfo -SiteUrl $Url
$copiedInfo = Get-TensorBoardSiteInfo -SiteUrl $localUrl
$pluginComparison = Compare-StringSet -Source $sourceAfter.EnabledPlugins -Copied $copiedInfo.EnabledPlugins
$runComparison = Compare-StringSet -Source $sourceAfter.Runs -Copied $copiedInfo.Runs

$verification = [ordered]@{
  compared_at = (Get-Date).ToString("o")
  source_url = $Url
  copied_url = $localUrl
  source_data_location = $sourceAfter.DataLocation
  copied_data_location = $copiedInfo.DataLocation
  source_run_count = @($sourceAfter.Runs).Count
  copied_run_count = @($copiedInfo.Runs).Count
  source_enabled_plugins = @($sourceAfter.EnabledPlugins)
  copied_enabled_plugins = @($copiedInfo.EnabledPlugins)
  plugins_match = $pluginComparison.Match
  runs_match = $runComparison.Match
  missing_plugins_in_copy = @($pluginComparison.MissingInCopy)
  extra_plugins_in_copy = @($pluginComparison.ExtraInCopy)
  missing_runs_in_copy = @($runComparison.MissingInCopy)
  extra_runs_in_copy = @($runComparison.ExtraInCopy)
}

$verificationPassed = ($pluginComparison.Match -and $runComparison.Match)
$verification.verification_status = if ($verificationPassed) { "Passed" } else { "Failed" }
Write-Json -Path (Join-Path $targetFolder "verification.json") -Value $verification

if (!$verificationPassed) {
  $manifest.verification_status = "Failed"
  $manifest.copied_enabled_plugins = @($copiedInfo.EnabledPlugins)
  $manifest.copied_run_count = @($copiedInfo.Runs).Count
  Write-Json -Path $manifestPath -Value $manifest
  throw "Source-vs-copy verification failed. See verification.json in the archive folder."
}

Write-Host "Source-vs-copy verification passed."
Write-Host "  Source tabs: $($sourceAfter.EnabledPlugins -join ', ')"
Write-Host "  Copied tabs: $($copiedInfo.EnabledPlugins -join ', ')"
Write-Host "  Runs compared: $(@($copiedInfo.Runs).Count)"

$zipInfo = New-ZipBackup -ArchiveRoot $ArchiveRoot -FolderPath $targetFolder -FolderName $FolderName

$manifest.verification_status = "Passed"
$manifest.verified_at = $verification.compared_at
$manifest.copied_enabled_plugins = @($copiedInfo.EnabledPlugins)
$manifest.copied_run_count = @($copiedInfo.Runs).Count
$manifest.zip_backup = $zipInfo.ZipPath
$manifest.zip_sha256 = $zipInfo.SHA256
Write-Json -Path $manifestPath -Value $manifest

$docsScript = Join-Path $PSScriptRoot "Update-TensorBoardArchiveDocs.ps1"
& $docsScript -ArchiveRoot $ArchiveRoot

Write-Host ""
Write-Host "Archive completed successfully." -ForegroundColor Green
Write-Host "I compared the source TensorBoard site against the copied site:"
Write-Host "  Tabs/plugins matched."
Write-Host "  Run list matched."
Write-Host "  File hashes matched."
Write-Host ""
Write-Host "Important: please manually open the copied dashboard once and visually confirm it while the source site is still available."
Write-Host "Copied dashboard: $localUrl"
Write-Host "Archive folder: $targetFolder"
Write-Host "HTML index: $(Join-Path $ArchiveRoot 'dashboard.html')"

if (!$NoOpenAfterSuccess) {
  if (Ask-YesNo -Question "Open the copied dashboard now for manual review?" -DefaultYes $true) {
    Start-Process $localUrl
  }
}
