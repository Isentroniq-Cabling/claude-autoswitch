# claude-autoswitch statusline for Claude Code.
# Receives session JSON on stdin; prints one line showing which backend THIS
# session is on, and (when different) what NEW sessions are configured for.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

$sessionBackend = ''
$modelName = ''
$j = $null
try {
  $stdin = [Console]::In.ReadToEnd()
  $j = $stdin | ConvertFrom-Json
  $model = Get-Prop $j 'model'
  $mid = [string](Get-Prop $model 'id' '')
  $modelName = [string](Get-Prop $model 'display_name' '')
  if ($mid -match '(^|\.)(eu|us|apac|global)\.anthropic\.' -or $mid -match '^anthropic\.') {
    $sessionBackend = 'BEDROCK'
  }
  elseif ($mid) { $sessionBackend = 'SUB' }
}
catch {}

# Keep the latest utilization Claude Code reports alongside the render data:
# rate_limits carries the real five_hour/seven_day used % and reset times,
# which nothing else exposes - `claude-switch status` displays the copy and
# the monitor reads the reset times from it. Written only when the numbers
# changed, and never allowed to break the render: whatever happens here, the
# statusline still prints its line.
try {
  $rl = Get-Prop $j 'rate_limits'
  if ($rl) {
    $snap = [pscustomobject]@{
      five_hour  = (Get-Prop $rl 'five_hour')
      seven_day  = (Get-Prop $rl 'seven_day')
      capturedAt = (Get-Date).ToString('o')
    }
    $newJson = ($snap | Select-Object five_hour, seven_day | ConvertTo-Json -Depth 8 -Compress)
    $oldJson = $null
    $old = Read-JsonFile $UsagePath
    if ($old) { $oldJson = ($old | Select-Object five_hour, seven_day | ConvertTo-Json -Depth 8 -Compress) }
    if ($newJson -ne $oldJson) { Write-JsonFile $UsagePath $snap }
  }
}
catch {}

$state = Get-State
$configured = 'SUB'
if ((Get-Prop $state 'mode' 'subscription') -eq 'bedrock') { $configured = 'BEDROCK' }

$returnTxt = ''
$resetRaw = Get-Prop $state 'resetAt'
if ($configured -eq 'BEDROCK' -and $resetRaw) {
  try {
    $mins = [int][Math]::Max(0, ((ConvertFrom-IsoDate $resetRaw) - (Get-Date)).TotalMinutes)
    $returnTxt = ' (sub in {0}h{1:d2}m)' -f [int][Math]::Floor($mins / 60), ($mins % 60)
  } catch {}
}

if (-not $sessionBackend) { $sessionBackend = $configured }
$line = '[{0}] {1}' -f $sessionBackend, $modelName
if ($sessionBackend -ne $configured) {
  $line += ' | new sessions: {0}{1}' -f $configured, $returnTxt
}
elseif ($returnTxt) {
  $line += ' |' + $returnTxt
}
Write-Output $line.Trim()
