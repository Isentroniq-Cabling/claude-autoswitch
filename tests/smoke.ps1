# claude-autoswitch smoke tests. Runs everything against a sandbox in %TEMP% -
# never touches the real ~/.claude/settings.json or scheduled tasks.
#
# NOTE: detection trigger strings are assembled at runtime (string concat)
# instead of written literally, so that copies of this file - or chat
# transcripts containing it - can never themselves trigger the monitor.

$ErrorActionPreference = 'Stop'

$repoSrc = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$sandbox = Join-Path $env:TEMP 'claude-autoswitch-test'
if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox }
$bin = Join-Path $sandbox 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sandbox '.claude\projects\proj') | Out-Null
Copy-Item (Join-Path $repoSrc '*') $bin -Force

$script:fails = 0
function Assert($Condition, [string]$Label) {
  if ($Condition) { Write-Host ('  PASS  ' + $Label) }
  else { Write-Host ('  FAIL  ' + $Label) -ForegroundColor Red; $script:fails++ }
}

# --- fixtures ----------------------------------------------------------------
$sandboxSettings = Join-Path $sandbox '.claude\settings.json'
@'
{
  "awsAuthRefresh": "aws sso login --profile isentroniq",
  "env": {
    "CLAUDE_CODE_USE_POWERSHELL_TOOL": "1",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "eu-west-1",
    "AWS_PROFILE": "isentroniq",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "eu.anthropic.claude-sonnet-5[1m]",
    "API_TIMEOUT_MS": "1800000"
  },
  "model": "fable",
  "voice": { "enabled": true, "mode": "hold" }
}
'@ | Set-Content -Path $sandboxSettings -Encoding UTF8

@'
{
  "bedrockEnv": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "eu-west-1",
    "AWS_PROFILE": "isentroniq",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "eu.anthropic.claude-sonnet-5[1m]"
  },
  "subscriptionEnv": {},
  "subscriptionModel": "fable",
  "bedrockModel": "fable"
}
'@ | Set-Content -Path (Join-Path $sandbox 'config.json') -Encoding UTF8

# Load helpers against the sandbox.
. (Join-Path $bin 'common.ps1')
$SettingsPath = $sandboxSettings
$ProjectsDir  = Join-Path $sandbox '.claude\projects'

Write-Host ''
Write-Host '-- Set-ClaudeBackend --'

Set-ClaudeBackend -Mode subscription -Reason 'test'
$s = Read-JsonFile $sandboxSettings
Assert ($null -eq $s.env.PSObject.Properties['CLAUDE_CODE_USE_BEDROCK']) 'sub: bedrock flag removed'
Assert ($null -eq $s.env.PSObject.Properties['AWS_PROFILE']) 'sub: aws profile removed'
Assert ($null -eq $s.env.PSObject.Properties['ANTHROPIC_DEFAULT_SONNET_MODEL']) 'sub: bedrock model id removed'
Assert ($s.env.CLAUDE_CODE_USE_POWERSHELL_TOOL -eq '1') 'sub: unrelated env key kept'
Assert ($s.env.API_TIMEOUT_MS -eq '1800000') 'sub: timeout key kept'
Assert ($s.awsAuthRefresh -like '*isentroniq*') 'sub: non-env settings kept'
Assert ($s.model -eq 'fable') 'sub: model set'
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'sub: state mode updated'

$reset = (Get-Date).AddHours(5)
Set-ClaudeBackend -Mode bedrock -ResetAt $reset -Reason 'test'
$s = Read-JsonFile $sandboxSettings
Assert ($s.env.CLAUDE_CODE_USE_BEDROCK -eq '1') 'bedrock: flag restored'
Assert ($s.env.AWS_PROFILE -eq 'isentroniq') 'bedrock: profile restored'
Assert ($s.env.ANTHROPIC_DEFAULT_SONNET_MODEL -like 'eu.anthropic*') 'bedrock: model id restored'
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'bedrock: state mode updated'
Assert ([Math]::Abs(((ConvertFrom-IsoDate $st.resetAt) - $reset).TotalSeconds) -lt 2) 'bedrock: resetAt stored'

Write-Host ''
Write-Host '-- Get-ResetFromText --'

$pipe = [char]124
$epochFuture = [System.DateTimeOffset]::Now.AddHours(3).ToUnixTimeSeconds()
$strictLine = 'Claude AI usage ' + 'limit reached' + $pipe + $epochFuture
$r = Get-ResetFromText $strictLine
Assert ($null -ne $r -and [Math]::Abs(($r - (Get-Date).AddHours(3)).TotalMinutes) -lt 2) 'epoch form parsed'

$r = Get-ResetFromText 'You have hit your limit. Your limit will reset at 7pm.'
Assert ($null -ne $r -and $r.Hour -eq 19 -and $r -gt (Get-Date)) 'prose form parsed (7pm)'

$r = Get-ResetFromText 'It resets at 14:30 tomorrow'
Assert ($null -ne $r -and $r.Hour -eq 14 -and $r.Minute -eq 30) 'prose form parsed (24h clock)'

$r = Get-ResetFromText 'no time in here at all'
Assert ($null -eq $r) 'no time -> null'

Write-Host ''
Write-Host '-- statusline --'

# state is currently bedrock w/ resetAt; feed it a Bedrock model id
$json = '{"model":{"id":"eu.anthropic.claude-sonnet-5[1m]","display_name":"Sonnet 5"}}'
$out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'statusline.ps1')
Assert ($out -match '^\[BEDROCK\] Sonnet 5') 'statusline: bedrock session detected'
Assert ($out -match 'sub in \d+h\d+m') 'statusline: auto-return countdown shown'

$json = '{"model":{"id":"claude-fable-5","display_name":"Fable 5"}}'
$out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'statusline.ps1')
Assert ($out -match '^\[SUB\] Fable 5') 'statusline: subscription session detected'
Assert ($out -match 'new sessions: BEDROCK') 'statusline: divergence from configured mode shown'

Write-Host ''
Write-Host '-- monitor: flip back to subscription after reset --'

$st = Read-JsonFile $StatePath
$st.resetAt = (Get-Date).AddMinutes(-1).ToString('o')
Write-JsonFile $StatePath $st
$oldProfile = $env:USERPROFILE
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
$s = Read-JsonFile $sandboxSettings
Assert ($st.mode -eq 'subscription') 'monitor: flipped back to subscription'
Assert ($null -eq $s.env.PSObject.Properties['CLAUDE_CODE_USE_BEDROCK']) 'monitor: settings back on subscription'

Write-Host ''
Write-Host '-- monitor: detect limit error, flip to bedrock --'

# The flip-back above just set lastFlipBackAt=now, which would trigger the
# 24h weekly-cap backoff. Age it so we exercise the default 5h fallback.
$st = Read-JsonFile $StatePath
$st.lastFlipBackAt = (Get-Date).AddHours(-2).ToString('o')
Write-JsonFile $StatePath $st

# Simulated transcript line: prose limit error marked as an API error.
# (concatenated so this file never contains the trigger text verbatim)
$marker = '"isApiError' + 'Message":true'
$errText = 'You have reached your usage ' + 'limit.'
$line = '{"type":"assistant",' + $marker + ',"text":"' + $errText + '"}'
$transcript = Join-Path $sandbox '.claude\projects\proj\session1.jsonl'
Set-Content -Path $transcript -Value $line -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
$s = Read-JsonFile $sandboxSettings
Assert ($st.mode -eq 'bedrock') 'monitor: flipped to bedrock on limit error'
Assert ($s.env.CLAUDE_CODE_USE_BEDROCK -eq '1') 'monitor: settings on bedrock'
Assert ($null -ne $st.resetAt) 'monitor: fallback auto-return set'
$hours = ((ConvertFrom-IsoDate $st.resetAt) - (Get-Date)).TotalHours
Assert ($hours -gt 4.9 -and $hours -lt 5.1) 'monitor: fallback is ~5h'

Write-Host ''
Write-Host '-- monitor: stale epoch is ignored; fresh epoch is honored --'

# Back to subscription (preserving file offsets), then a STALE strict error.
$st = Read-JsonFile $StatePath
$st.mode = 'subscription'; $st.resetAt = $null
Write-JsonFile $StatePath $st
$epochPast = [System.DateTimeOffset]::Now.AddHours(-6).ToUnixTimeSeconds()
$staleLine = '{"type":"x","text":"Claude AI usage ' + 'limit reached' + $pipe + $epochPast + '"}'
$transcript2 = Join-Path $sandbox '.claude\projects\proj\session2.jsonl'
Set-Content -Path $transcript2 -Value $staleLine -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'monitor: stale (past-epoch) error ignored'

$freshLine = '{"type":"x","text":"Claude AI usage ' + 'limit reached' + $pipe + $epochFuture + '"}'
Add-Content -Path $transcript2 -Value $freshLine -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'monitor: fresh strict error flips to bedrock'
$mins = [Math]::Abs(((ConvertFrom-IsoDate $st.resetAt) - (Get-Date).AddHours(3)).TotalMinutes)
Assert ($mins -lt 2) 'monitor: auto-return taken from error epoch'

# Offset regression: re-running must NOT rescan already-seen lines.
$st = Read-JsonFile $StatePath
$st.mode = 'subscription'; $st.resetAt = $null
Write-JsonFile $StatePath $st
(Get-Item $transcript2).LastWriteTime = Get-Date   # touch, no new content
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'monitor: old lines not rescanned (offsets work)'

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green }
else { Write-Host ($script:fails.ToString() + ' TEST(S) FAILED') -ForegroundColor Red }
exit $script:fails
