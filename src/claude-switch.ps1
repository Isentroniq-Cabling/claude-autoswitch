# claude-autoswitch CLI. Installed on PATH as `claude-switch`.
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'sub', 'subscription', 'bedrock', 'check', 'enable', 'disable', 'log', 'help')]
  [string]$Command = 'status',

  # For `bedrock`: when to automatically return to subscription.
  [string]$ResetAt,
  [double]$Hours,

  # Show the result and wait for Enter before exiting. The desktop shortcuts
  # pass this so their console window stays readable instead of vanishing.
  [switch]$Pause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$TaskName = 'ClaudeAutoswitch'

function Show-Usage {
  Write-Host @'

claude-switch - route Claude Code to your Teams subscription or AWS Bedrock

  claude-switch status            mode, timers, subscription usage, monitor state
  claude-switch sub               switch to SUBSCRIPTION (claude.ai login)
  claude-switch bedrock           switch to BEDROCK (stays until switched back)
  claude-switch bedrock -Hours 5  switch to BEDROCK, auto-return to sub in 5h
  claude-switch bedrock -ResetAt "2026-07-25 18:00"   auto-return at a time
  claude-switch check             live-test every Bedrock model in config.json
  claude-switch enable|disable    turn the background monitor task on/off
  claude-switch log               show the last 30 log lines

Switches apply to NEW sessions. A session that is already running keeps the
backend it started with - start a new chat (or `claude --continue`) after a switch.
'@
}

function Show-Status {
  $state = Get-State
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  $taskState = 'NOT INSTALLED'
  if ($task) { $taskState = [string]$task.State }

  $resetTxt = '-'
  $resetRaw = Get-Prop $state 'resetAt'
  if ($resetRaw) {
    $reset = ConvertFrom-IsoDate $resetRaw
    $mins = [int]($reset - (Get-Date)).TotalMinutes
    $resetTxt = '{0:ddd HH:mm} (in {1}h{2:d2}m)' -f $reset, [int][Math]::Floor($mins / 60), ($mins % 60)
  }

  $lastSwitchTxt = '-'
  $lastSwitchRaw = Get-Prop $state 'lastSwitch'
  if ($lastSwitchRaw) { $lastSwitchTxt = (ConvertFrom-IsoDate $lastSwitchRaw).ToString('ddd HH:mm') }

  # Subscription utilization, as last captured from the statusline feed - the
  # only place Claude Code exposes the real 5h/7d numbers. Passive: refreshes
  # only while some session is rendering a statusline.
  $usageTxt = '- (populates after a session renders its statusline)'
  $usage = Read-JsonFile $UsagePath
  if ($usage) {
    $parts = @()
    foreach ($w in @(@('5h', 'five_hour'), @('7d', 'seven_day'))) {
      $win = Get-Prop $usage $w[1]
      if ($null -eq $win) { continue }
      $txt = '{0} {1}%' -f $w[0], [Math]::Round([double](Get-Prop $win 'used_percentage' 0))
      $t = ConvertFrom-ResetStamp (Get-Prop $win 'resets_at')
      if ($t) { $txt += (' (resets {0:ddd HH:mm})' -f $t) }
      $parts += $txt
    }
    if ($parts.Count -gt 0) {
      $usageTxt = $parts -join ' | '
      try {
        $age = [int]((Get-Date) - (ConvertFrom-IsoDate (Get-Prop $usage 'capturedAt'))).TotalMinutes
        $usageTxt += ('  [as of {0}m ago]' -f $age)
      } catch {}
    }
  }

  Write-Host ''
  Write-Host ('  mode                 : {0}' -f (Get-Prop $state 'mode' '?').ToUpper())
  Write-Host ('  settings.json backend: {0}' -f (Get-SettingsBackend).ToUpper())
  Write-Host ('  auto-return to sub   : {0}' -f $resetTxt)
  Write-Host ('  last switch          : {0} ({1})' -f $lastSwitchTxt, (Get-Prop $state 'reason' '-'))
  Write-Host ('  subscription usage   : {0}' -f $usageTxt)
  $ccRaw = Get-Prop $state 'lastCreditCap'
  if ($ccRaw) {
    Write-Host ('  last credit-cap error: {0} (usage credits, e.g. Fable 5 - informational, never switches)' -f (ConvertFrom-IsoDate $ccRaw).ToString('ddd HH:mm'))
  }
  # Say whether the failover destination is even usable. Set-ClaudeBackend
  # refuses a fatal config, so the reason has to be visible somewhere other
  # than the failed switch - and a warning here is the only notice that auto
  # mode would break on Bedrock.
  $cfg = Read-JsonFile $ConfigPath
  $problems = @(Get-BedrockEnvIssue (Get-Prop $cfg 'bedrockEnv' ([pscustomobject]@{})))
  $fatal   = @($problems | Where-Object { $_.Severity -eq 'fatal' })
  $warn    = @($problems | Where-Object { $_.Severity -ne 'fatal' })
  $cfgTxt  = 'consistent (not live-tested - run: claude-switch check)'
  if ($fatal.Count -gt 0)     { $cfgTxt = 'UNUSABLE - failover is blocked' }
  elseif ($warn.Count -gt 0)  { $cfgTxt = 'usable, with warnings' }

  Write-Host ('  monitor task         : {0}' -f $taskState)
  Write-Host ('  bedrock config       : {0}' -f $cfgTxt)
  if ($fatal.Count -gt 0) {
    Write-Host ''
    foreach ($p in $fatal) { Write-Host ('    FATAL   ' + $p.Message) -ForegroundColor Red }
  }
  if ($warn.Count -gt 0) {
    Write-Host ''
    foreach ($p in $warn) { Write-Host ('    warning ' + $p.Message) -ForegroundColor Yellow }
  }
  if ($problems.Count -gt 0) {
    Write-Host ('            fix bedrockEnv in {0}' -f $ConfigPath)
  }
  Write-Host ''
  Write-Host '  Switches apply to NEW sessions; running sessions keep their backend.'
  Write-Host ''
}

try {
  switch ($Command) {
    { $_ -eq 'sub' -or $_ -eq 'subscription' } {
      Set-ClaudeBackend -Mode subscription -Reason 'manual'
      Write-Host 'Switched to SUBSCRIPTION. New sessions use your claude.ai login.'
      Write-Host 'The monitor will flip to Bedrock automatically when you hit the usage limit.'
      break
    }
    'bedrock' {
      if ($ResetAt) {
        $when = [datetime]::Parse($ResetAt)
        Set-ClaudeBackend -Mode bedrock -ResetAt $when -Reason 'manual'
        Write-Host ('Switched to BEDROCK. Auto-return to subscription at {0:ddd HH:mm}.' -f $when)
      }
      elseif ($Hours -gt 0) {
        $when = (Get-Date).AddHours($Hours)
        Set-ClaudeBackend -Mode bedrock -ResetAt $when -Reason 'manual'
        Write-Host ('Switched to BEDROCK. Auto-return to subscription at {0:ddd HH:mm}.' -f $when)
      }
      else {
        Set-ClaudeBackend -Mode bedrock -Reason 'manual'
        Write-Host 'Switched to BEDROCK (no auto-return - run `claude-switch sub` to go back).'
      }
      break
    }
    'check' {
      # Prove the Bedrock destination actually answers BEFORE the monitor ever
      # sends anyone there: one 1-token converse call per configured model.
      # Catches a mistyped profile, a region that lacks these models, and a
      # model the account has no access grant for - the failure classes that
      # made the first real failover (2026-08-21) land on a backend that
      # answered every request with 400 "invalid model identifier".
      $config = Read-JsonFile $ConfigPath
      if ($null -eq $config) { throw "config.json not found at $ConfigPath - run install.ps1 first." }
      $bedrockEnv = Get-Prop $config 'bedrockEnv' ([pscustomobject]@{})
      $models = @($bedrockEnv.PSObject.Properties | Where-Object { $_.Name -like 'ANTHROPIC_DEFAULT_*_MODEL' })
      if ($models.Count -eq 0) {
        Write-Host 'No ANTHROPIC_DEFAULT_*_MODEL entries in bedrockEnv - nothing to check.'
        break
      }
      # Static pass first. The live call below reports the symptom ("invalid
      # model identifier"); this names the cause, and it still runs when the
      # aws CLI is missing entirely.
      foreach ($p in @(Get-BedrockEnvIssue $bedrockEnv)) {
        if ($p.Severity -eq 'fatal') { Write-Host ('  CONFIG  ' + $p.Message) -ForegroundColor Red }
        else { Write-Host ('  CONFIG  ' + $p.Message) -ForegroundColor Yellow }
      }
      if ($null -eq (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Host 'aws CLI not found on PATH - install it to verify the Bedrock config.' -ForegroundColor Red
        exit 1
      }
      $region     = Get-Prop $bedrockEnv 'AWS_REGION'
      $awsProfile = Get-Prop $bedrockEnv 'AWS_PROFILE'
      Write-Host ''
      Write-Host ('  Testing Bedrock as profile "{0}" in {1} (one 1-token call per model)' -f $awsProfile, $region)
      $failed = 0
      $tmp = Join-Path $env:TEMP ('claude-switch-check.' + $PID + '.json')
      try {
        foreach ($m in $models) {
          # Strip Claude Code's [1m]-style context suffix; Bedrock wants the bare id.
          $id = $m.Value -replace '\[[^\]]*\]$', ''
          Write-JsonFile $tmp ([pscustomobject]@{
            modelId         = $id
            messages        = @([pscustomobject]@{ role = 'user'; content = @([pscustomobject]@{ text = 'hi' }) })
            inferenceConfig = [pscustomobject]@{ maxTokens = 1 }
          })
          # 2>&1 on a native command throws under EAP=Stop in PowerShell 5.1;
          # relax it around the call and judge by exit code instead.
          $eap = $ErrorActionPreference
          $ErrorActionPreference = 'Continue'
          $out = & aws bedrock-runtime converse --cli-input-json ('file://' + $tmp) --region $region --profile $awsProfile --output json 2>&1
          $code = $LASTEXITCODE
          $ErrorActionPreference = $eap
          if ($code -eq 0) {
            Write-Host ('  OK    {0}  ({1})' -f $id, $m.Name)
          }
          else {
            $failed++
            # Native stderr arrives as ErrorRecord objects under 2>&1. Read
            # their messages rather than piping to Out-String, which renders
            # them at host width and so cuts the reason in half; then keep just
            # the part that says what is actually wrong, because the AWS
            # preamble ("An error occurred (X) when calling the Y operation:")
            # is long enough on its own to push the reason off the line.
            $msgs = @($out | ForEach-Object {
              if ($_ -is [System.Management.Automation.ErrorRecord]) { [string]$_.Exception.Message } else { [string]$_ }
            }) | Where-Object { $_.Trim() }
            $flat = (($msgs -join ' ') -replace '\s+', ' ').Trim()
            $why = $flat
            $mm = [regex]::Match($flat, '\(([A-Za-z]+(?:Exception|Error))\).*?:\s*(.+)$')
            if ($mm.Success) { $why = '{0}: {1}' -f $mm.Groups[1].Value, $mm.Groups[2].Value.Trim() }
            elseif ($why.Length -gt 160) { $why = $why.Substring(0, 160) + '...' }
            Write-Host ('  FAIL  {0}  ({1})' -f $id, $m.Name) -ForegroundColor Red
            Write-Host ('        {0}' -f $why)
          }
        }
      }
      finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
      Write-Host ''
      if ($failed -gt 0) {
        Write-Host ('  {0} of {1} model(s) FAILED - fix bedrockEnv in {2} before trusting the failover.' -f $failed, $models.Count, $ConfigPath) -ForegroundColor Red
        exit 1
      }
      Write-Host '  All models answered. Failover destination verified.'
      break
    }
    'enable' {
      Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
      Write-Host 'Monitor task enabled.'
      break
    }
    'disable' {
      Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
      Write-Host 'Monitor task disabled. Automatic switching is off; manual switching still works.'
      break
    }
    'log' {
      if (Test-Path $LogPath) { Get-Content $LogPath -Tail 30 } else { Write-Host '(no log yet)' }
      break
    }
    'help' { Show-Usage; break }
    default { Show-Status }
  }
  if ($Pause) {
    if ($Command -ne 'status' -and $Command -ne 'help') { Show-Status }
    Read-Host 'Press Enter to close' | Out-Null
  }
}
catch {
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
  # A refused or failed switch must stay readable in a shortcut's console
  # window - vanishing on error is how a refusal goes unnoticed.
  if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
  exit 1
}
