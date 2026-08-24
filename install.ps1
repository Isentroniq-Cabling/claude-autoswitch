# claude-autoswitch installer (per-user, no admin required).
# - copies scripts to ~\.claude-autoswitch\bin and puts it on PATH
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
  [switch]$NoTask,
  # Leave the user PATH untouched (unattended installs, and the test suite).
  [switch]$NoPath,
  # Overridden by the test suite so a test run can never touch the real task.
  [string]$TaskName = 'ClaudeAutoswitch'
)

$ErrorActionPreference = 'Stop'

# Deliberately NOT %LOCALAPPDATA%. Inside an MSIX/AppContainer app (e.g. a Claude
# Code shell hosted by the Claude desktop app) writes under %LOCALAPPDATA% are
# silently redirected into that package's LocalCache. The path still resolves in
# there, so the install looks fine - but Task Scheduler runs outside the container
# and cannot see it, so the monitor never runs at all.
$DataDir = Join-Path $env:USERPROFILE '.claude-autoswitch'
$BinDir  = Join-Path $DataDir 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

$redirected = (Get-Item $DataDir -Force).Target
if ($redirected) {
  throw ("$DataDir is redirected to $redirected, so the scheduled task could not reach it. " +
         'Run install.ps1 from a normal terminal, outside any packaged/containerized app.')
}

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

# Which region should a fresh config.json name? A hardcoded literal is wrong on
# most machines, and the wrong region used to mean a backend that 400s every
# call. Take whatever this machine already resolves to, and fall back to a
# literal only when nothing says otherwise.
function Get-InstallRegion([string]$Preferred, [string]$AwsProfileName) {
  if ($Preferred) { return $Preferred }
  # A region persisted in the user environment wins over settings.json at
  # runtime, so if one is set it is the region that will actually apply.
  foreach ($v in @($env:AWS_REGION, $env:AWS_DEFAULT_REGION)) {
    if ($v) { return [string]$v }
  }
  $awsConfig = Join-Path $env:USERPROFILE '.aws\config'
  if ($AwsProfileName -and (Test-Path $awsConfig)) {
    $section = ''
    foreach ($line in (Get-Content $awsConfig)) {
      $t = $line.Trim()
      $head = [regex]::Match($t, '^\[(.+)\]$')
      if ($head.Success) { $section = $head.Groups[1].Value.Trim(); continue }
      if ($section -ne ('profile ' + $AwsProfileName) -and $section -ne $AwsProfileName) { continue }
      $r = [regex]::Match($t, '^region\s*=\s*(\S+)')
      if ($r.Success) { return $r.Groups[1].Value }
    }
  }
  return 'us-east-1'
}

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
    $bedrockEnv['AWS_REGION'] = Get-InstallRegion -Preferred $Region -AwsProfileName $bedrockEnv['AWS_PROFILE']
    # `global.` inference profiles resolve in every region, so a seeded default
    # cannot contradict whatever region ends up applying. A us./eu./apac. id is
    # geography-scoped and answers 400 outside its own geography - that is what
    # took this machine's auto mode down for three days on 2026-08-21, and a
    # default has no business being able to reintroduce it. Ids verified ACTIVE
    # and invocable 2026-08-24; `claude-switch check` re-verifies per account.
    $bedrockEnv['ANTHROPIC_DEFAULT_SONNET_MODEL'] = 'global.anthropic.claude-sonnet-5[1m]'
    $bedrockEnv['ANTHROPIC_DEFAULT_OPUS_MODEL']   = 'global.anthropic.claude-opus-5'
    $bedrockEnv['ANTHROPIC_DEFAULT_HAIKU_MODEL']  = 'global.anthropic.claude-haiku-4-5-20251001-v1:0'
    $bedrockEnv['ANTHROPIC_DEFAULT_FABLE_MODEL']  = 'global.anthropic.claude-fable-5[1m]'
    Write-Warning 'No Bedrock env found in settings.json. Set AWS_PROFILE in the generated config.json, then run `claude-switch check`.'
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
  # Launch through `conhost --headless` so no console window is ever created.
  # A bare powershell.exe action flashes a console for ~0.5s on every run even
  # with -WindowStyle Hidden, because conhost creates the window before
  # PowerShell can apply the style. Running the task as S4U ("whether user is
  # logged on or not") would also avoid it, but that needs elevation and this
  # installer is deliberately admin-free.
  $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument (
    '--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $BinDir 'monitor.ps1'))
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
  # IgnoreNew: never run two monitors at once. -StartWhenAvailable fires every
  # missed run when the machine wakes, which otherwise arrives as a burst of
  # overlapping instances all writing the same state file.
  $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $taskSettings -Description 'claude-autoswitch: flips Claude Code between subscription and Bedrock' `
    -Force | Out-Null
  Write-Host ('Scheduled task {0} registered (every {1} min).' -f $TaskName, $IntervalMinutes)
}

# --- PATH --------------------------------------------------------------------
if (-not $NoPath) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($null -eq $userPath) { $userPath = '' }
  if (($userPath -split ';') -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $BinDir), 'User')
    Write-Host 'Added bin dir to user PATH (open a new terminal to pick it up).'
  }
}

Write-Host ''
Write-Host 'Installed. Try:  claude-switch status'
Write-Host 'To start subscription-first behavior:  claude-switch sub'
Write-Host 'To verify the Bedrock failover destination:  claude-switch check'
