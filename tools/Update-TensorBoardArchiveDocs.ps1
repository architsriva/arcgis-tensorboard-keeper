<#
.SYNOPSIS
Refreshes the HTML, CSV, and Markdown index files for a TensorBoard archive root.

.DESCRIPTION
Scans archive folders that contain interactive TensorBoard manifests and launchers, then rebuilds
dashboard.html, dashboard.csv, and archive-index.md.
This script does not copy new TensorBoard data.

.PARAMETER ArchiveRoot
The archive root to scan. Defaults to an ignored archives folder beside this repository's tools folder.
#>

param(
  [string]$ArchiveRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "archives")
)

$ErrorActionPreference = "Stop"

function ConvertTo-HtmlText {
  param([AllowNull()][object]$Value)
  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Read-JsonFile {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path)) {
    return $null
  }
  $text = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  return $text | ConvertFrom-Json
}

function Get-FileStats {
  param([string]$Path)
  $stats = [ordered]@{
    TotalFiles = 0
    EventFiles = 0
    Bytes = [int64]0
    RunDirectories = 0
  }

  if (!(Test-Path -LiteralPath $Path)) {
    return [pscustomobject]$stats
  }

  $runDirs = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue
  $stats.RunDirectories = @($runDirs).Count

  $files = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue
  $stats.TotalFiles = @($files).Count
  $stats.EventFiles = @($files | Where-Object { $_.Name -like "events.out.tfevents*" }).Count
  $stats.Bytes = [int64](($files | Measure-Object Length -Sum).Sum)
  return [pscustomobject]$stats
}

function Format-ByteSize {
  param([int64]$Bytes)
  if ($Bytes -lt 1024) { return "$Bytes B" }
  if ($Bytes -lt 1048576) { return ("{0:N2} KB" -f ($Bytes / 1024)) }
  if ($Bytes -lt 1073741824) { return ("{0:N2} MB" -f ($Bytes / 1048576)) }
  return ("{0:N2} GB" -f ($Bytes / 1073741824))
}

function Join-Values {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return "" }
  if ($Value -is [array]) { return (($Value | ForEach-Object { [string]$_ }) -join ", ") }
  return [string]$Value
}

$ArchiveRoot = [System.IO.Path]::GetFullPath($ArchiveRoot)
if (!(Test-Path -LiteralPath $ArchiveRoot)) {
  throw "Archive root does not exist: $ArchiveRoot"
}

$rows = New-Object System.Collections.Generic.List[object]
$folders = Get-ChildItem -LiteralPath $ArchiveRoot -Directory | Where-Object { $_.Name -ne "tools" } | Sort-Object Name

foreach ($folder in $folders) {
  $manifestPath = Join-Path $folder.FullName "manifest.json"
  if (!(Test-Path -LiteralPath $manifestPath)) {
    $manifestPath = Join-Path $folder.FullName "interactive_manifest.json"
  }
  $manifest = Read-JsonFile -Path $manifestPath
  $trainingLog = Join-Path $folder.FullName "training_log"
  $stats = Get-FileStats -Path $trainingLog
  $zipPath = Join-Path $ArchiveRoot "$($folder.Name).zip"
  $shaPathTxt = "$zipPath.sha256.txt"
  $shaPath = "$zipPath.sha256"
  $sha = ""

  if (Test-Path -LiteralPath $shaPathTxt) {
    $sha = ((Get-Content -LiteralPath $shaPathTxt -Raw) -split "\s+")[0]
  } elseif (Test-Path -LiteralPath $shaPath) {
    $sha = ((Get-Content -LiteralPath $shaPath -Raw) -split "\s+")[0]
  }

  $port = ""
  if ($manifest -and $manifest.default_port) {
    $port = $manifest.default_port
  } else {
    $launcher = Join-Path $folder.FullName "start.ps1"
    if (!(Test-Path -LiteralPath $launcher)) {
      $launcher = Join-Path $folder.FullName "Start-InteractiveTensorBoard.ps1"
    }
    if (Test-Path -LiteralPath $launcher) {
      $text = Get-Content -LiteralPath $launcher -Raw
      $match = [regex]::Match($text, "\[int\]\`$Port\s*=\s*(\d+)")
      if ($match.Success) { $port = [int]$match.Groups[1].Value }
    }
  }

  $dashboardUrl = ""
  if ($manifest -and $manifest.default_url) {
    $dashboardUrl = $manifest.default_url
  } elseif ($port) {
    $dashboardUrl = "http://localhost:$port/#timeseries"
  }

  $launcherPath = Join-Path $folder.FullName "start.ps1"
  if (!(Test-Path -LiteralPath $launcherPath)) {
    $launcherPath = Join-Path $folder.FullName "Start-InteractiveTensorBoard.ps1"
  }

  $batchLauncherPath = Join-Path $folder.FullName "open.bat"
  if (!(Test-Path -LiteralPath $batchLauncherPath)) {
    $batchLauncherPath = Join-Path $folder.FullName "Open-InteractiveTensorBoard.bat"
  }

  $row = [ordered]@{
    "Folder name" = $folder.Name
    "Training note" = if ($manifest) { $manifest.training_note } else { "" }
    "Source URL" = if ($manifest) { $manifest.source_url } else { "" }
    "Captured at" = if ($manifest) { $manifest.captured_at } else { "" }
    "Port" = $port
    "Dashboard URL" = $dashboardUrl
    "Command to run" = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`""
    "Double-click launcher" = $batchLauncherPath
    "Original logdir" = if ($manifest) { $manifest.original_logdir } else { "" }
    "Saved logdir" = $trainingLog
    "Runs" = $stats.RunDirectories
    "Event files" = $stats.EventFiles
    "Archive size" = Format-ByteSize -Bytes $stats.Bytes
    "Source tabs" = if ($manifest) { Join-Values $manifest.source_enabled_plugins } else { "" }
    "Copied tabs verified" = if ($manifest) { Join-Values $manifest.copied_enabled_plugins } else { "" }
    "Verification status" = if ($manifest) { $manifest.verification_status } else { "" }
    "Zip backup" = if (Test-Path -LiteralPath $zipPath) { $zipPath } else { "" }
    "Zip SHA-256" = $sha
    "Copy method" = "Copied the source TensorBoard training_log and recreated the dashboard locally from the copied event files."
    "Tech stack used" = "TensorBoard; ArcGIS Pro Python; PowerShell; TensorBoard event files; localhost ports; ZIP + SHA-256."
  }

  $rows.Add([pscustomobject]$row) | Out-Null
}

$csvPath = Join-Path $ArchiveRoot "dashboard.csv"
$htmlPath = Join-Path $ArchiveRoot "dashboard.html"
$indexPath = Join-Path $ArchiveRoot "archive-index.md"

$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$headers = @(
  "Folder name", "Training note", "Source URL", "Captured at", "Port", "Dashboard URL",
  "Command to run", "Double-click launcher", "Original logdir", "Saved logdir",
  "Runs", "Event files", "Archive size", "Source tabs", "Copied tabs verified",
  "Verification status", "Zip backup", "Zip SHA-256", "Copy method", "Tech stack used"
)

$htmlRows = foreach ($row in $rows) {
  $cells = foreach ($header in $headers) {
    $value = $row.$header
    if ($header -in @("Command to run", "Double-click launcher", "Original logdir", "Saved logdir", "Zip backup", "Zip SHA-256", "Copy method", "Tech stack used")) {
      "<td><code>$(ConvertTo-HtmlText $value)</code></td>"
    } elseif ($header -in @("Source URL", "Dashboard URL") -and $value) {
      "<td><a href=""$(ConvertTo-HtmlText $value)"">$(ConvertTo-HtmlText $value)</a></td>"
    } else {
      "<td>$(ConvertTo-HtmlText $value)</td>"
    }
  }
  "<tr>$($cells -join '')</tr>"
}

$updatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
$archiveRootHtml = ConvertTo-HtmlText $ArchiveRoot
$updatedAtHtml = ConvertTo-HtmlText $updatedAt
$headerHtml = ($headers | ForEach-Object { "<th>$(ConvertTo-HtmlText $_)</th>" }) -join ""
$bodyHtml = $htmlRows -join "`r`n"
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>TensorBoard Archive Dashboard</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2933; background: #ffffff; }
    h1 { font-size: 22px; margin: 0 0 8px; }
    h2 { font-size: 17px; margin: 24px 0 8px; }
    p { color: #52606d; margin: 0 0 16px; }
    .table-wrap { overflow-x: auto; border: 1px solid #cbd5e1; }
    table { border-collapse: collapse; width: 100%; min-width: 2600px; table-layout: fixed; }
    th, td { border: 1px solid #cbd5e1; padding: 8px; vertical-align: top; font-size: 12px; word-break: break-word; }
    th { background: #d9eaf7; text-align: left; position: sticky; top: 0; z-index: 1; }
    tr:nth-child(even) td { background: #f8fafc; }
    code { white-space: pre-wrap; font-family: Consolas, monospace; font-size: 11px; color: #111827; }
    a { color: #0f62fe; }
    .notes { max-width: 980px; }
    .notes table { min-width: 0; }
  </style>
</head>
<body>
  <h1>TensorBoard Archive Dashboard</h1>
  <p>Archive root: <code>$archiveRootHtml</code></p>
  <p>Last updated: $updatedAtHtml</p>
  <div class="table-wrap">
    <table>
      <thead><tr>$headerHtml</tr></thead>
      <tbody>$bodyHtml</tbody>
    </table>
  </div>
  <section class="notes">
    <h2>How each archive is created</h2>
    <table>
      <thead><tr><th>Step</th><th>What the tool does</th></tr></thead>
      <tbody>
        <tr><td>1</td><td>Asks for the live TensorBoard URL, archive root, training note, and approved folder name.</td></tr>
        <tr><td>2</td><td>Reads TensorBoard's <code>/data/environment</code>, <code>/data/runs</code>, and <code>/data/plugins_listing</code> endpoints.</td></tr>
        <tr><td>3</td><td>Copies only the source <code>training_log</code> reported by that TensorBoard site.</td></tr>
        <tr><td>4</td><td>Creates launchers that serve the copied logs through a short temporary junction to avoid missing tabs on long Windows paths.</td></tr>
        <tr><td>5</td><td>Starts the copied dashboard on a new local port and compares tabs/runs against the source site.</td></tr>
        <tr><td>6</td><td>Creates ZIP and SHA-256 backups, then refreshes this HTML/CSV documentation.</td></tr>
      </tbody>
    </table>
  </section>
</body>
</html>
"@

Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

$md = @()
$md += "# TensorBoard Archive Dashboard"
$md += ""
$md += "Archive root: ``$ArchiveRoot``"
$md += ""
$md += "Last updated: $updatedAt"
$md += ""
$md += "| Folder name | Port | Dashboard URL | Training note | Verification |"
$md += "|---|---:|---|---|---|"
foreach ($row in $rows) {
  $md += "| $($row.'Folder name') | $($row.Port) | $($row.'Dashboard URL') | $($row.'Training note') | $($row.'Verification status') |"
}
$md += ""
$md += "Use the HTML or CSV table for the full command/path details."
Set-Content -LiteralPath $indexPath -Value ($md -join "`r`n") -Encoding UTF8

Write-Host "Updated documentation:"
Write-Host "  $csvPath"
Write-Host "  $htmlPath"
Write-Host "  $indexPath"
