# claude-autoswitch CLI. Installed on PATH as `claude-switch`.
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'sub', 'subscription', 'bedrock', 'enable', 'disable', 'log', 'help')]
  [string]$Command = 'status',

  # For `bedrock`: when to automatically return to subscription.
  [string]$ResetAt,
  [double]$Hours
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$TaskName = 'ClaudeAutoswitch'

function Show-Usage {
  Write-Host @'

claude-switch - route Claude Code to your Teams subscription or AWS Bedrock

  claude-switch status            show current mode, timers and monitor state
  claude-switch sub               switch to SUBSCRIPTION (claude.ai login)
  claude-switch bedrock           switch to BEDROCK (stays until switched back)
  claude-switch bedrock -Hours 5  switch to BEDROCK, auto-return to sub in 5h
  claude-switch bedrock -ResetAt "2026-07-25 18:00"   auto-return at a time
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
    $reset = Parse-IsoDate $resetRaw
    $mins = [int]($reset - (Get-Date)).TotalMinutes
    $resetTxt = '{0:ddd HH:mm} (in {1}h{2:d2}m)' -f $reset, [int][Math]::Floor($mins / 60), ($mins % 60)
  }

  $lastSwitchTxt = '-'
  $lastSwitchRaw = Get-Prop $state 'lastSwitch'
  if ($lastSwitchRaw) { $lastSwitchTxt = (Parse-IsoDate $lastSwitchRaw).ToString('ddd HH:mm') }

  Write-Host ''
  Write-Host ('  mode                 : {0}' -f (Get-Prop $state 'mode' '?').ToUpper())
  Write-Host ('  settings.json backend: {0}' -f (Get-SettingsBackend).ToUpper())
  Write-Host ('  auto-return to sub   : {0}' -f $resetTxt)
  Write-Host ('  last switch          : {0} ({1})' -f $lastSwitchTxt, (Get-Prop $state 'reason' '-'))
  Write-Host ('  monitor task         : {0}' -f $taskState)
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
}
catch {
  Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
