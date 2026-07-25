# claude-autoswitch statusline for Claude Code.
# Receives session JSON on stdin; prints one line showing which backend THIS
# session is on, and (when different) what NEW sessions are configured for.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

$sessionBackend = ''
$modelName = ''
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

$state = Get-State
$configured = 'SUB'
if ((Get-Prop $state 'mode' 'subscription') -eq 'bedrock') { $configured = 'BEDROCK' }

$returnTxt = ''
$resetRaw = Get-Prop $state 'resetAt'
if ($configured -eq 'BEDROCK' -and $resetRaw) {
  try {
    $mins = [int][Math]::Max(0, ((Parse-IsoDate $resetRaw) - (Get-Date)).TotalMinutes)
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
