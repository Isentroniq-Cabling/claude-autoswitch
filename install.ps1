# claude-autoswitch installer (per-user, no admin required).
# - copies scripts to %LOCALAPPDATA%\claude-autoswitch\bin and puts it on PATH
# - seeds config.json from the Bedrock env already present in ~/.claude/settings.json
#   (or from -AwsProfile / -Region on a fresh machine)
# - registers a Task Scheduler job that runs monitor.ps1 every few minutes
# - adds a statusline to Claude Code unless one is already configured
# It does NOT change which backend you are currently on.
param(
  [string]$AwsProfile,
  [string]$Region,
  [int]$IntervalMinutes = 5,
  [switch]$NoStatusline,
  [switch]$NoTask
)

$ErrorActionPreference = 'Stop'

$DataDir = Join-Path $env:LOCALAPPDATA 'claude-autoswitch'
$BinDir  = Join-Path $DataDir 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'src\*') -Destination $BinDir -Force

# cmd shim so `claude-switch` works from any shell
$shim = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0claude-switch.ps1`" %*`r`n"
[System.IO.File]::WriteAllText((Join-Path $BinDir 'claude-switch.cmd'), $shim, [System.Text.Encoding]::ASCII)

. (Join-Path $BinDir 'common.ps1')

$settings = Read-JsonFile $SettingsPath
if ($null -eq $settings) { $settings = [pscustomobject]@{} }
$envBlock = Get-Prop $settings 'env'

# --- one-time backup of settings.json ---------------------------------------
$backupPath = Join-Path $DataDir ('settings.backup.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
if (Test-Path $SettingsPath) { Copy-Item $SettingsPath $backupPath }

# --- seed config.json from whatever Bedrock config is already in place ------
$knownBedrockKeys = @(
  'CLAUDE_CODE_USE_BEDROCK', 'AWS_PROFILE', 'AWS_REGION',
  'AWS_BEARER_TOKEN_BEDROCK', 'ANTHROPIC_BEDROCK_BASE_URL',
  'CLAUDE_CODE_SKIP_BEDROCK_AUTH',
  'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_FABLE_MODEL'
)
if (-not (Test-Path $ConfigPath)) {
  $bedrockEnv = [ordered]@{}
  foreach ($k in $knownBedrockKeys) {
    $v = Get-Prop $envBlock $k
    if ($null -ne $v) { $bedrockEnv[$k] = $v }
  }
  if ($bedrockEnv.Count -eq 0) {
    $bedrockEnv['CLAUDE_CODE_USE_BEDROCK'] = '1'
    if ($AwsProfile) { $bedrockEnv['AWS_PROFILE'] = $AwsProfile } else { $bedrockEnv['AWS_PROFILE'] = 'CHANGE-ME' }
    if ($Region)     { $bedrockEnv['AWS_REGION'] = $Region }      else { $bedrockEnv['AWS_REGION'] = 'eu-west-1' }
    Write-Warning 'No Bedrock env found in settings.json. Edit the generated config.json (profile, region, model IDs) before switching to bedrock mode.'
  }
  else {
    if ($AwsProfile) { $bedrockEnv['AWS_PROFILE'] = $AwsProfile }
    if ($Region)     { $bedrockEnv['AWS_REGION'] = $Region }
  }
  $config = [pscustomobject]@{
    bedrockEnv        = [pscustomobject]$bedrockEnv
    subscriptionEnv   = [pscustomobject]@{}
    subscriptionModel = (Get-Prop $settings 'model')
    bedrockModel      = (Get-Prop $settings 'model')
  }
  Write-JsonFile $ConfigPath $config
  Write-Host ('config.json created at ' + $ConfigPath)
}
else {
  Write-Host 'config.json already exists - keeping it.'
}

# --- initial state: adopt whatever backend is currently configured ----------
if (-not (Test-Path $StatePath)) {
  $mode = 'subscription'
  if ($null -ne (Get-Prop $envBlock 'CLAUDE_CODE_USE_BEDROCK')) { $mode = 'bedrock' }
  Write-JsonFile $StatePath ([pscustomobject]@{
    mode = $mode; resetAt = $null; lastScan = $null
    lastFlipBackAt = $null; lastSwitch = $null
    reason = 'install: adopted current settings'
  })
  Write-Host ('Initial mode: ' + $mode.ToUpper() + ' (adopted from settings.json, nothing changed)')
}

# --- statusline --------------------------------------------------------------
if (-not $NoStatusline) {
  $existing = Get-Prop $settings 'statusLine'
  if ($null -eq $existing) {
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $BinDir 'statusline.ps1') + '"'
    Set-Prop $settings 'statusLine' ([pscustomobject]@{ type = 'command'; command = $cmd })
    Write-JsonFile $SettingsPath $settings
    Write-Host 'Statusline added to settings.json.'
  }
  else {
    Write-Host 'A statusline is already configured - leaving it alone.'
  }
}

# --- scheduled task ----------------------------------------------------------
if (-not $NoTask) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $BinDir 'monitor.ps1'))
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
  $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName 'ClaudeAutoswitch' -Action $action -Trigger $trigger `
    -Settings $taskSettings -Description 'claude-autoswitch: flips Claude Code between subscription and Bedrock' `
    -Force | Out-Null
  Write-Host ('Scheduled task ClaudeAutoswitch registered (every {0} min).' -f $IntervalMinutes)
}

# --- PATH --------------------------------------------------------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $BinDir) {
  [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $BinDir), 'User')
  Write-Host 'Added bin dir to user PATH (open a new terminal to pick it up).'
}

Write-Host ''
Write-Host 'Installed. Try:  claude-switch status'
Write-Host 'To start subscription-first behavior:  claude-switch sub'
