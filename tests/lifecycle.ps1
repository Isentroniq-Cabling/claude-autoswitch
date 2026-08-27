# claude-autoswitch installer/uninstaller lifecycle tests.
#
# Runs install.ps1 and uninstall.ps1 against a sandboxed USERPROFILE under
# %TEMP%, with -NoPath and a test-only -TaskName, so a test run can never
# touch the real user PATH, the real ~/.claude/settings.json, or the real
# ClaudeAutoswitch monitor task.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$Sandbox  = Join-Path $env:TEMP 'claude-autoswitch-lifecycle'
$TestTask = 'ClaudeAutoswitchTest'

$script:fails = 0
function Assert($Condition, [string]$Label) {
  if ($Condition) { Write-Host ('  PASS  ' + $Label) }
  else { Write-Host ('  FAIL  ' + $Label) -ForegroundColor Red; $script:fails++ }
}

function Invoke-Installer {
  param([string]$Script, [string[]]$Arguments = @())
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot $Script)) + $Arguments
  $out = & powershell.exe @all 2>&1
  return ($out | Out-String)
}

function Read-Json([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

$realProfile = $env:USERPROFILE
try {
  # --- clean slate ----------------------------------------------------------
  try { Unregister-ScheduledTask -TaskName $TestTask -Confirm:$false -ErrorAction Stop } catch {}
  if (Test-Path $Sandbox) { Remove-Item -Recurse -Force $Sandbox }
  New-Item -ItemType Directory -Force -Path (Join-Path $Sandbox '.claude') | Out-Null

  # %TEMP% can be an 8.3 short path (C:\Users\TIAGOG~1\...) while $PSScriptRoot
  # inside the installed scripts always resolves to the long form. Normalize so
  # path comparisons below hold on any machine.
  $Sandbox = (Get-Item $Sandbox).FullName

  $SettingsPath = Join-Path $Sandbox '.claude\settings.json'
  $DataDir      = Join-Path $Sandbox '.claude-autoswitch'
  $BinDir       = Join-Path $DataDir 'bin'
  # Shortcuts go to a sandbox dir - passing -ShortcutDir on every install and
  # uninstall call below is what keeps a test run off the real Desktop.
  $ShortcutDir  = Join-Path $Sandbox 'Desktop'
  $SubLnk       = Join-Path $ShortcutDir 'Claude - Subscription.lnk'
  $BedLnk       = Join-Path $ShortcutDir 'Claude - Bedrock.lnk'

  # A settings.json that already runs on Bedrock, plus unrelated keys the
  # installer must preserve untouched.
  @'
{
  "awsAuthRefresh": "aws sso login --profile isentroniq",
  "env": {
    "CLAUDE_CODE_USE_POWERSHELL_TOOL": "1",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "eu-west-1",
    "AWS_PROFILE": "isentroniq",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "global.anthropic.claude-fable-5[1m]",
    "API_TIMEOUT_MS": "1800000"
  },
  "model": "fable",
  "effortLevel": "xhigh",
  "theme": "dark"
}
'@ | Set-Content -Path $SettingsPath -Encoding UTF8

  $env:USERPROFILE = $Sandbox

  # --- install --------------------------------------------------------------
  Write-Host ''
  Write-Host '-- install --'
  $out = Invoke-Installer 'install.ps1' @('-NoPath', '-TaskName', $TestTask, '-ShortcutDir', $ShortcutDir)
  Assert ($LASTEXITCODE -eq 0) 'installer exit code 0'
  Assert ($out -match 'config\.json created') 'installer reported config creation'

  foreach ($f in @('common.ps1', 'monitor.ps1', 'claude-switch.ps1', 'statusline.ps1', 'claude-switch.cmd')) {
    Assert (Test-Path (Join-Path $BinDir $f)) ('bin contains ' + $f)
  }

  $config = Read-Json (Join-Path $DataDir 'config.json')
  Assert ($config.bedrockEnv.AWS_PROFILE -eq 'isentroniq') 'config seeded AWS profile from settings.json'
  Assert ($config.bedrockEnv.CLAUDE_CODE_USE_BEDROCK -eq '1') 'config seeded bedrock flag'
  Assert ($config.bedrockEnv.ANTHROPIC_DEFAULT_FABLE_MODEL -like 'global.anthropic*') 'config seeded model id'
  Assert ($null -eq $config.bedrockEnv.PSObject.Properties['API_TIMEOUT_MS']) 'config did NOT capture unrelated env key'
  Assert ($config.subscriptionModel -eq 'fable') 'config captured model'

  $state = Read-Json (Join-Path $DataDir 'state.json')
  Assert ($state.mode -eq 'bedrock') 'state adopted current backend (bedrock)'
  Assert ($null -eq $state.resetAt) 'adopted bedrock has no auto-return (treated as manual)'

  $settings = Read-Json $SettingsPath
  Assert ($settings.statusLine.command -like ('*' + $BinDir + '*')) 'statusline points into installed bin dir'
  Assert ($settings.env.CLAUDE_CODE_USE_BEDROCK -eq '1') 'install did not change current backend'
  Assert ($settings.env.API_TIMEOUT_MS -eq '1800000') 'unrelated env key preserved'
  Assert ($settings.effortLevel -eq 'xhigh') 'unrelated top-level setting preserved'
  Assert ($settings.awsAuthRefresh -like '*isentroniq*') 'awsAuthRefresh preserved'

  $backups = Get-ChildItem -Path $DataDir -Filter 'settings.backup.*.json' -ErrorAction SilentlyContinue
  Assert ($backups.Count -ge 1) 'settings.json backed up'

  # --- desktop shortcuts -----------------------------------------------------
  Write-Host ''
  Write-Host '-- desktop shortcuts --'
  Assert (Test-Path $SubLnk) 'subscription shortcut created'
  Assert (Test-Path $BedLnk) 'bedrock shortcut created'
  $wsh = New-Object -ComObject WScript.Shell
  $lnk = $wsh.CreateShortcut($SubLnk)
  Assert ($lnk.TargetPath -like '*powershell.exe') 'shortcut launches powershell'
  Assert ($lnk.Arguments -like ('*' + $BinDir + '*')) 'shortcut points into installed bin dir'
  Assert ($lnk.Arguments -like '* sub -Pause*') 'subscription shortcut passes sub -Pause'
  Assert (($wsh.CreateShortcut($BedLnk)).Arguments -like '* bedrock -Pause*') 'bedrock shortcut passes bedrock -Pause'
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)

  # --- scheduled task ------------------------------------------------------
  Write-Host ''
  Write-Host '-- scheduled task --'
  $task = Get-ScheduledTask -TaskName $TestTask -ErrorAction SilentlyContinue
  Assert ($null -ne $task) 'task registered'
  if ($task) {
    $action = $task.Actions[0]
    Assert ($action.Execute -like '*conhost.exe') 'task launches via conhost (no console flash)'
    Assert ($action.Arguments -like '*--headless*') 'task uses --headless'
    Assert ($task.Settings.MultipleInstances -eq 'IgnoreNew') 'task never runs overlapping instances'

    # The MSIX regression: whatever path is baked into the task must be
    # resolvable from outside the installing process. A path that only exists
    # inside an MSIX container silently never runs.
    $m = [regex]::Match($action.Arguments, '-File\s+"([^"]+)"')
    Assert ($m.Success) 'task action carries a -File path'
    if ($m.Success) {
      $monitorPath = $m.Groups[1].Value
      Assert (Test-Path $monitorPath) 'monitor path in task action actually exists'
      Assert ($monitorPath -notlike '*\LocalCache\*') 'monitor path is not MSIX-redirected'
      Assert ($monitorPath -notlike '*\Packages\*') 'monitor path is not inside an MSIX package'
    }
  }

  # --- idempotency ---------------------------------------------------------
  Write-Host ''
  Write-Host '-- second install (idempotent) --'
  $configBefore = [System.IO.File]::ReadAllText((Join-Path $DataDir 'config.json'))
  $stateBefore  = [System.IO.File]::ReadAllText((Join-Path $DataDir 'state.json'))
  $out = Invoke-Installer 'install.ps1' @('-NoPath', '-TaskName', $TestTask, '-ShortcutDir', $ShortcutDir)
  Assert ($LASTEXITCODE -eq 0) 'second install exit code 0'
  Assert ($out -match 'config\.json already exists') 'second install kept existing config'
  Assert ($out -match 'statusline is already configured') 'second install kept existing statusline'
  Assert ([System.IO.File]::ReadAllText((Join-Path $DataDir 'config.json')) -eq $configBefore) 'config.json unchanged'
  Assert ([System.IO.File]::ReadAllText((Join-Path $DataDir 'state.json')) -eq $stateBefore) 'state.json unchanged'

  # --- CLI -----------------------------------------------------------------
  Write-Host ''
  Write-Host '-- claude-switch CLI --'
  $status = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'claude-switch.ps1') status 2>&1 | Out-String
  Assert ($status -match 'mode\s+:\s+BEDROCK') 'status reports BEDROCK mode'
  Assert ($status -match 'settings\.json backend:\s+BEDROCK') 'status reads backend from settings.json'

  $help = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'claude-switch.ps1') help 2>&1 | Out-String
  Assert ($help -match 'claude-switch status') 'help lists commands'

  # A manual switch to subscription must strip the Bedrock keys.
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'claude-switch.ps1') sub 2>&1 | Out-Null
  $settings = Read-Json $SettingsPath
  Assert ($null -eq $settings.env.PSObject.Properties['CLAUDE_CODE_USE_BEDROCK']) 'CLI sub removed bedrock flag'
  Assert ($settings.env.API_TIMEOUT_MS -eq '1800000') 'CLI sub preserved unrelated env key'
  Assert ((Read-Json (Join-Path $DataDir 'state.json')).mode -eq 'subscription') 'CLI sub updated state'

  # --- uninstall -----------------------------------------------------------
  Write-Host ''
  Write-Host '-- uninstall (keep data) --'
  # Replace the subscription shortcut with a same-named one that is NOT ours;
  # the uninstaller must judge ownership by the target, not the name.
  $wsh = New-Object -ComObject WScript.Shell
  $foreign = $wsh.CreateShortcut($SubLnk)
  $foreign.TargetPath = (Join-Path $env:SystemRoot 'System32\notepad.exe')
  $foreign.Arguments = ''
  $foreign.Save()
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)

  $out = Invoke-Installer 'uninstall.ps1' @('-NoPath', '-TaskName', $TestTask, '-ShortcutDir', $ShortcutDir)
  Assert ($LASTEXITCODE -eq 0) 'uninstaller exit code 0'
  Assert ($null -eq (Get-ScheduledTask -TaskName $TestTask -ErrorAction SilentlyContinue)) 'task unregistered'
  $settings = Read-Json $SettingsPath
  Assert ($null -eq $settings.PSObject.Properties['statusLine']) 'statusline removed'
  Assert ($settings.effortLevel -eq 'xhigh') 'uninstall preserved unrelated settings'
  Assert (Test-Path $DataDir) 'data dir kept without -PurgeData'
  Assert (-not (Test-Path $BedLnk)) 'our shortcut removed'
  Assert (Test-Path $SubLnk) 'foreign same-named shortcut left alone'
  Remove-Item $SubLnk -Force

  Write-Host ''
  Write-Host '-- uninstall -PurgeData --'
  $out = Invoke-Installer 'uninstall.ps1' @('-NoPath', '-PurgeData', '-TaskName', $TestTask, '-ShortcutDir', $ShortcutDir)
  Assert ($LASTEXITCODE -eq 0) 'purge exit code 0'
  Assert (-not (Test-Path $DataDir)) 'data dir removed with -PurgeData'
  Assert (Test-Path $SettingsPath) 'settings.json left in place'

  # --- install -NoShortcuts --------------------------------------------------
  Write-Host ''
  Write-Host '-- install -NoShortcuts --'
  $out = Invoke-Installer 'install.ps1' @('-NoPath', '-TaskName', $TestTask, '-NoShortcuts', '-ShortcutDir', $ShortcutDir)
  Assert ($LASTEXITCODE -eq 0) '-NoShortcuts install exit code 0'
  Assert (-not (Test-Path $SubLnk)) '-NoShortcuts skipped shortcut creation'
  $out = Invoke-Installer 'uninstall.ps1' @('-NoPath', '-PurgeData', '-TaskName', $TestTask, '-ShortcutDir', $ShortcutDir)
}
finally {
  $env:USERPROFILE = $realProfile
  try { Unregister-ScheduledTask -TaskName $TestTask -Confirm:$false -ErrorAction Stop } catch {}
  if (Test-Path $Sandbox) { Remove-Item -Recurse -Force $Sandbox -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'ALL LIFECYCLE TESTS PASSED' -ForegroundColor Green }
else { Write-Host ($script:fails.ToString() + ' LIFECYCLE TEST(S) FAILED') -ForegroundColor Red }
exit $script:fails
