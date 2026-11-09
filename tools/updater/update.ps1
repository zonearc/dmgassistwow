# update.ps1: install the latest nightly build of DMGAssist and DMGAssist_Watchdog into one or more AddOns folders.
# Run by the tray updater (DMGAssistUpdater); can also be run by hand:
#   powershell -ExecutionPolicy Bypass -File update.ps1 -AddOns "C:\...\_retail_\Interface\AddOns|D:\...\Interface\AddOns" -Result "$env:TEMP\r.txt"
#
# The repository may be private: then a read-only GitHub key is needed, in github-token.txt next to this script or in
# %APPDATA%\DMGAssist\github-token.txt (one line; never put it in the repository). Without one a public repository
# still works. Folders already on the nightly version are left alone; when every folder is, nothing is downloaded and
# the result is "SAME <release name>".
# Safe order: both zips are downloaded and checked first; only then are the installed folders replaced.
# The result ("OK <release name>", "SAME <release name>" or "ERROR <message>") is written to -Result.

param(
  [Parameter(Mandatory = $true)][string]$AddOns,   # one or more AddOns folders, separated by |
  [Parameter(Mandatory = $true)][string]$Result,
  [string]$Installed = '',                         # unused (older updaters passed it); versions are read per folder
  [switch]$Force,                                  # manual click: also re-check the updater's own files now
  [string]$Status = ''                             # progress for the tray app's window: "<percent>|<text>"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # the progress bar makes Invoke-WebRequest very slow on PowerShell 5
$repo = 'zonearc/dmgassistwow'
$addonNames = @('DMGAssist', 'DMGAssist_Watchdog')
$work = $null

# The GitHub key, if there is one (for a private repository).
function Get-Token {
  foreach ($f in @((Join-Path $PSScriptRoot 'github-token.txt'), (Join-Path $env:APPDATA 'DMGAssist\github-token.txt'))) {
    if ($f -and (Test-Path -LiteralPath $f)) {
      $t = (Get-Content -LiteralPath $f -Raw).Trim()
      if ($t) { return $t }
    }
  }
  return ''
}
$token = Get-Token

# Download a release file: through the API with the key (works for private repositories), else the public link.
function Get-Asset($asset, [string]$out) {
  if ($token) {
    $h = @{ Accept = 'application/octet-stream'; 'User-Agent' = 'DMGAssistUpdater'; Authorization = "Bearer $token" }
    Invoke-WebRequest -Uri $asset.url -Headers $h -OutFile $out -UseBasicParsing
  } else {
    Invoke-WebRequest -Uri $asset.browser_download_url -Headers @{ 'User-Agent' = 'DMGAssistUpdater' } -OutFile $out -UseBasicParsing
  }
}

function Step([int]$pct, [string]$text) {
  if ($Status) { try { Set-Content -LiteralPath $Status -Value ("$pct|$text") } catch { } }
}

function Get-InstalledVersion([string]$folder) {
  $toc = Join-Path $folder 'DMGAssist\DMGAssist.toc'
  if (-not (Test-Path -LiteralPath $toc)) { return '' }
  foreach ($line in Get-Content -LiteralPath $toc) {
    if ($line -match '^## Version:\s*(.+)$') { return $Matches[1].Trim() }
  }
  return ''
}

# Keep this script current: when DMGAssist_Updater.zip on the nightly release changes, take its update.ps1.
# (An updater installed before a change in how builds are packaged would otherwise keep looking for old files.)
function Update-Self($release) {
  try {
    $asset = $release.assets | Where-Object { $_.name -eq 'DMGAssist_Updater.zip' }
    if (-not $asset -or -not $PSCommandPath) { return }
    $stamp = Join-Path $PSScriptRoot 'updater.stamp'
    $seen = ''
    if (Test-Path -LiteralPath $stamp) { $seen = (Get-Content -LiteralPath $stamp -Raw).Trim() }
    if (-not $Force -and $seen -eq [string]$asset.updated_at) { return }
    $tmp = Join-Path $env:TEMP ('dmgassist-updater-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
      $zip = Join-Path $tmp 'u.zip'
      Get-Asset $asset $zip
      Step 65 'Downloaded. Checking the package...'
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
      # The updater's own files: this script, the tray app (it restarts itself when its file changes), the icon
      # and the uninstaller. Only files that differ are written.
      foreach ($name in @('update.ps1', 'DMGAssistUpdater.ahk', 'dmgassist.ico', 'Uninstall-DMGAssistUpdater.ahk')) {
        $new = Join-Path $tmp ('updater\' + $name)
        $dest = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $new)) { continue }
        if ($name -eq 'update.ps1' -and (Get-Content -LiteralPath $new -Raw) -notmatch 'param\(') { continue }
        $same = (Test-Path -LiteralPath $dest) -and
          ((Get-FileHash -LiteralPath $new).Hash -eq (Get-FileHash -LiteralPath $dest).Hash)
        if (-not $same) { Copy-Item -LiteralPath $new -Destination $dest -Force }
      }
      Set-Content -LiteralPath $stamp -Value ([string]$asset.updated_at)
    } finally {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch { } # never let this get in the way of the addon update
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $folders = @($AddOns -split '\|' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
  if ($folders.Count -eq 0) { throw 'No AddOns folder given.' }

  Step 10 'Checking GitHub for the newest build...'
  $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'DMGAssistUpdater' }
  if ($token) { $headers.Authorization = "Bearer $token" }
  $release = $null
  for ($try = 1; $try -le 3 -and -not $release; $try++) {
    try {
      $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/nightly" -Headers $headers
    } catch {
      $code = 0
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($try -eq 3) {
        if (($code -eq 404 -or $code -eq 401) -and -not $token) {
          throw 'GitHub did not show the build: the repository is private now. Put your GitHub key in github-token.txt next to update.ps1 (see the updater README).'
        }
        if ($code -eq 401) { throw 'GitHub refused the key in github-token.txt (expired or wrong): make a new one (see the updater README).' }
        if ($code -eq 404) {
          Step 100 'No update right now: a new build is being published. It will be picked up on the next check.'
          Set-Content -LiteralPath $Result -Value 'BUSY'
          return
        }
        throw "GitHub could not be reached ($code): $($_.Exception.Message)"
      }
      Step 10 "GitHub didn't answer; trying again (attempt $($try + 1) of 3)..."
      Start-Sleep -Seconds 20 # a build being published, or a network blip
    }
  }
  $latest = ''
  if ($release.name -match '(\d+(\.\d+)+)') { $latest = $Matches[1] }

  $todo = @($folders | Where-Object { -not $latest -or (Get-InstalledVersion $_) -ne $latest })
  Step 25 'Checking the updater itself...'
  Update-Self $release
  if ($todo.Count -eq 0) {
    Step 100 "Already up to date: $latest"
    Set-Content -LiteralPath $Result -Value ("SAME " + $release.name)
    return
  }

  $have = @($todo | ForEach-Object { $v = Get-InstalledVersion $_; if ($v) { $v } else { 'not installed' } } | Select-Object -Unique) -join ', '
  Step 35 "New build found: $latest (you have $have). Downloading..."
  $work = Join-Path $env:TEMP ('dmgassist-update-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null

  # 1. Download and check everything first: DMGAssist.zip holds both addon folders.
  # While a new build is being published its files are swapped one by one: wait for it instead of failing.
  $asset = $release.assets | Where-Object { $_.name -eq 'DMGAssist.zip' }
  for ($wait = 1; $wait -le 4 -and -not $asset; $wait++) {
    Step 35 "A new build is being published right now. Waiting for it ($wait of 4)..."
    Start-Sleep -Seconds 15
    try {
      $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/nightly" -Headers $headers
      $asset = $release.assets | Where-Object { $_.name -eq 'DMGAssist.zip' }
      if ($release.name -match '(\d+(\.\d+)+)') { $latest = $Matches[1] }
    } catch { }
  }
  if (-not $asset) {
    Step 100 'No update right now: a new build is still being published. It will be picked up on the next check.'
    Set-Content -LiteralPath $Result -Value ('BUSY ' + $release.name)
    return
  }
  $zip = Join-Path $work 'DMGAssist.zip'
  Get-Asset $asset $zip
  Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'unzipped') -Force
  foreach ($addon in $addonNames) {
    $toc = Join-Path $work "unzipped\$addon\$addon.toc"
    if (-not (Test-Path -LiteralPath $toc)) { throw "DMGAssist.zip does not contain $addon\$addon.toc." }
  }

  # 2. Replace the installed copies in every folder that needs it (the AddOns folder is created if missing).
  $n = 0
  foreach ($folder in $todo) {
    $n++
    Step (75 + [int](20 * ($n - 1) / $todo.Count)) "Installing into $folder ($n of $($todo.Count))..."
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    foreach ($addon in $addonNames) {
      $dest = Join-Path $folder $addon
      if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
      Copy-Item -LiteralPath (Join-Path $work "unzipped\$addon") -Destination $dest -Recurse
    }
  }

  Step 100 "Installed $latest. In game: /reload"
  Set-Content -LiteralPath $Result -Value ("OK " + $release.name)
} catch {
  Step 100 ("Failed: " + $_.Exception.Message)
  Set-Content -LiteralPath $Result -Value ("ERROR " + $_.Exception.Message)
} finally {
  if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
