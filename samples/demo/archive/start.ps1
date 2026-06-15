param(
  [int]$Port = 6015,
  [string]$HostName = "localhost",
  [string]$UrlSuffix = "/?darkMode=true#timeseries",
  [switch]$Foreground,
  [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$realLogdir = Join-Path $root "training_log"
$stdoutLog = Join-Path $root "tensorboard_server.stdout.log"
$stderrLog = Join-Path $root "tensorboard_server.stderr.log"
$junctionName = "tb_demo_6015"
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
  throw "Could not find tensorboard.exe. Put TensorBoard on PATH or install ArcGIS Pro deep learning dependencies."
}

$args = @("--logdir", $logdir, "--host", $HostName, "--port", $Port.ToString())
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

if (!$NoOpen) {
  Start-Process $url
}
