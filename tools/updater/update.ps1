# update.ps1: download the latest nightly build of DMGAssist and DMGAssist_Watchdog and install them.
# Run by DMGAssistUpdater.ahk (the tray icon); can also be run by hand:
#   powershell -ExecutionPolicy Bypass -File update.ps1 -AddOns "C:\...\Interface\AddOns" -Result "$env:TEMP\r.txt"
#
# The repository is private, so it needs a GitHub token with read access to zonearc/dmgassistwow
# (fine-grained token, repository access: only that repository, permission Contents: Read-only), saved in
# %APPDATA%\DMGAssistUpdater\token.txt by the tray icon's "Set GitHub token..." item.
#
# Safe order: both zips are downloaded and checked first; only then are the installed folders replaced.
# The result ("OK <release name>", "SAME <release name>" or "ERROR <message>") is written to -Result for the tray icon to show.

param(
  [Parameter(Mandatory = $true)][string]$AddOns,
  [Parameter(Mandatory = $true)][string]$Result,
  # The installed version ("0.1.0.15"); when the nightly release is the same build, nothing is downloaded and the
  # result is "SAME <release name>" (the tray icon's 10-minute check).
  [string]$Installed = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # the progress bar makes Invoke-WebRequest very slow on PowerShell 5
$repo = 'zonearc/dmgassistwow'
$addonNames = @('DMGAssist', 'DMGAssist_Watchdog')
$work = $null

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  if (-not (Test-Path -LiteralPath $AddOns)) {
    throw "The AddOns folder was not found: $AddOns"
  }
  # The repository is public: no token needed. A token saved earlier (private-repo days) is still sent if present.
  $headers = @{
    Accept       = 'application/vnd.github+json'
    'User-Agent' = 'DMGAssistUpdater'
  }
  $tokenFile = Join-Path $env:APPDATA 'DMGAssistUpdater\token.txt'
  if (Test-Path -LiteralPath $tokenFile) {
    $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    if ($token) { $headers.Authorization = "Bearer $token" }
  }
  $release = $null
  for ($try = 1; $try -le 3 -and -not $release; $try++) {
    try {
      $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/nightly" -Headers $headers
    } catch {
      $code = 0
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -eq 401 -or $code -eq 403) {
        throw "GitHub refused the saved token ($code). Delete it (right-click > Set GitHub token..., leave empty) or replace it."
      }
      if ($try -eq 3) {
        throw "The nightly build is not available right now ($code): a new one may be publishing. Trying again later."
      }
      Start-Sleep -Seconds 20 # a build being published, or a network blip
    }
  }

  if ($Installed -and $release.name -match '(\d+(\.\d+)+)' -and $Matches[1] -eq $Installed) {
    Set-Content -LiteralPath $Result -Value ("SAME " + $release.name)
    return
  }

  $work = Join-Path $env:TEMP ('dmgassist-update-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null

  # 1. Download and check everything first.
  foreach ($addon in $addonNames) {
    $asset = $release.assets | Where-Object { $_.name -eq "$addon.zip" }
    if (-not $asset) { throw "$addon.zip is not in the nightly release." }
    $zip = Join-Path $work "$addon.zip"
    $download = $headers.Clone()
    $download.Accept = 'application/octet-stream' # the API URL of an asset returns the file itself
    Invoke-WebRequest -Uri $asset.url -Headers $download -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work "unzipped-$addon") -Force
    $toc = Join-Path $work "unzipped-$addon\$addon\$addon.toc"
    if (-not (Test-Path -LiteralPath $toc)) { throw "$addon.zip does not contain $addon\$addon.toc." }
  }

  # 2. Replace the installed copies.
  foreach ($addon in $addonNames) {
    $dest = Join-Path $AddOns $addon
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $work "unzipped-$addon\$addon") -Destination $dest -Recurse
  }

  Set-Content -LiteralPath $Result -Value ("OK " + $release.name)
} catch {
  Set-Content -LiteralPath $Result -Value ("ERROR " + $_.Exception.Message)
} finally {
  if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
