# claude-autoswitch uninstaller. Removes the task, statusline and PATH entry.
# Leaves ~/.claude/settings.json on whichever backend it is currently set to.
param(
  # Also delete ~\.claude-autoswitch (config, state, logs, backups).
  [switch]$PurgeData,
  # Leave the user PATH untouched (unattended removal, and the test suite).
  [switch]$NoPath,
  # Where install.ps1 put the desktop shortcuts. Defaults to the user's
  # Desktop; overridden by the test suite.
  [string]$ShortcutDir,
  # Overridden by the test suite so a test run can never touch the real task.
  [string]$TaskName = 'ClaudeAutoswitch'
)

$ErrorActionPreference = 'Stop'

$DataDir = Join-Path $env:USERPROFILE '.claude-autoswitch'
$BinDir  = Join-Path $DataDir 'bin'
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
# Installs before 2026-07-27 lived under %LOCALAPPDATA%; tidy those leftovers too.
$LegacyBinDir = Join-Path $env:LOCALAPPDATA 'claude-autoswitch\bin'

try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Host 'Scheduled task removed.' } catch {}

# Remove our statusline (only if it is ours).
if (Test-Path $SettingsPath) {
  $raw = [System.IO.File]::ReadAllText($SettingsPath)
  $settings = $raw | ConvertFrom-Json
  $sl = $null
  if ($settings.PSObject.Properties['statusLine']) { $sl = $settings.statusLine }
  if ($null -ne $sl -and $sl.PSObject.Properties['command'] -and ([string]$sl.command) -like '*claude-autoswitch*') {
    $settings.PSObject.Properties.Remove('statusLine')
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 32), $enc)
    Write-Host 'Statusline removed from settings.json.'
  }
}

# Remove our desktop shortcuts - only if they are ours, judged the same way
# as the statusline above: the shortcut's arguments must point into our bin
# dir. A same-named shortcut someone made themselves is left alone.
if (-not $ShortcutDir) { $ShortcutDir = [Environment]::GetFolderPath('Desktop') }
foreach ($name in @('Claude - Subscription.lnk', 'Claude - Bedrock.lnk')) {
  $p = Join-Path $ShortcutDir $name
  if (-not (Test-Path $p)) { continue }
  try {
    $wsh = New-Object -ComObject WScript.Shell
    try {
      $lnkArgs = [string]$wsh.CreateShortcut($p).Arguments
      if ($lnkArgs -like ('*' + $BinDir + '*') -or $lnkArgs -like ('*' + $LegacyBinDir + '*')) {
        Remove-Item $p -Force
        Write-Host ('Shortcut removed: ' + $name)
      }
    }
    finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
  } catch {}
}

# Remove PATH entry.
if (-not $NoPath) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath) {
    $newPath = ($userPath -split ';' | Where-Object { $_ -and ($_ -ne $BinDir) -and ($_ -ne $LegacyBinDir) }) -join ';'
    if ($newPath -ne $userPath) {
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      Write-Host 'PATH entry removed.'
    }
  }
}

if ($PurgeData) {
  Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue
  Write-Host 'Data directory deleted.'
}
else {
  Write-Host ('Config/state/backups kept at ' + $DataDir + ' (use -PurgeData to delete).')
}

Write-Host 'Done. settings.json stays on its current backend - adjust it manually if needed.'
