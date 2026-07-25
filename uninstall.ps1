# claude-autoswitch uninstaller. Removes the task, statusline and PATH entry.
# Leaves ~/.claude/settings.json on whichever backend it is currently set to.
param(
  # Also delete %LOCALAPPDATA%\claude-autoswitch (config, state, logs, backups).
  [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'

$DataDir = Join-Path $env:LOCALAPPDATA 'claude-autoswitch'
$BinDir  = Join-Path $DataDir 'bin'
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

try { Unregister-ScheduledTask -TaskName 'ClaudeAutoswitch' -Confirm:$false -ErrorAction Stop; Write-Host 'Scheduled task removed.' } catch {}

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

# Remove PATH entry.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
  $newPath = ($userPath -split ';' | Where-Object { $_ -and ($_ -ne $BinDir) }) -join ';'
  if ($newPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host 'PATH entry removed.'
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
