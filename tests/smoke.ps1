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

# The config guard resolves the region that will actually apply at runtime, so a
# region persisted in the real user's environment would otherwise leak into
# these assertions - on a us-east-1 machine the sandbox's eu.* ids would read as
# a fatal mismatch and half the guard tests would fail. Pin it to the sandbox's
# declared region so the suite is machine-independent; child processes inherit it.
$oldAwsRegion = $env:AWS_REGION
$hadAwsDefault = Test-Path Env:AWS_DEFAULT_REGION
$oldAwsDefault = $env:AWS_DEFAULT_REGION
$env:AWS_REGION = 'eu-west-1'
if ($hadAwsDefault) { Remove-Item Env:AWS_DEFAULT_REGION }

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
$staleLine = '{"type":"assistant","isApiError' + 'Message":true,"text":"Claude AI usage ' + 'limit reached' + $pipe + $epochPast + '"}'
$transcript2 = Join-Path $sandbox '.claude\projects\proj\session2.jsonl'
Set-Content -Path $transcript2 -Value $staleLine -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'monitor: stale (past-epoch) error ignored'

$freshLine = '{"type":"assistant","isApiError' + 'Message":true,"text":"Claude AI usage ' + 'limit reached' + $pipe + $epochFuture + '"}'
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
Write-Host '-- monitor: text that only QUOTES a limit error must not trigger --'

# Back to subscription, preserving offsets.
$st = Read-JsonFile $StatePath
$st.mode = 'subscription'; $st.resetAt = $null
Write-JsonFile $StatePath $st

# A live-looking marker: correct shape, reset time still in the future.
$epochLive = [System.DateTimeOffset]::Now.AddHours(4).ToUnixTimeSeconds()
$quoted = 'Claude AI usage ' + 'limit reach' + 'ed' + $pipe + $epochLive

# (a) The real 2026-08-04 false positive: `claude-switch log` output captured
#     back into a transcript as a tool result. Text matches; record is a user
#     turn, so it must be ignored.
$toolResult = '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_x","type":"tool_result","content":"' + $quoted + '"}]}}'
# (b) An ordinary assistant message discussing the marker - not an API error.
$chatter = '{"type":"assistant","message":{"content":[{"type":"text","text":"the marker looks like ' + $quoted + '"}]}}'
$transcript3 = Join-Path $sandbox '.claude\projects\proj\session3.jsonl'
Set-Content -Path $transcript3 -Value @($toolResult, $chatter) -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'monitor: echoed log output does NOT trigger a switch'

# (c) The genuine article: same text, but a real assistant API-error record,
#     with the message nested in message.content[] as Claude Code writes it.
$real = '{"type":"assistant","isApiError' + 'Message":true,"message":{"content":[{"type":"text","text":"' + $quoted + '"}]}}'
Add-Content -Path $transcript3 -Value $real -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'monitor: real API-error record still triggers'
$mins = [Math]::Abs(((ConvertFrom-IsoDate $st.resetAt) - (Get-Date).AddHours(4)).TotalMinutes)
Assert ($mins -lt 2) 'monitor: reset time read from nested message.content'

Write-Host ''
Write-Host '-- monitor: reconciles settings.json that drifted from state --'

# The 2026-08-21 outage: something outside this tool (a hand edit) left Bedrock
# keys in settings.json while state.json still said subscription. The monitor
# read its own state, agreed with itself, and reported healthy for three days
# while auto mode denied every tool call.
Set-ClaudeBackend -Mode bedrock -Reason 'test'
$st = Read-JsonFile $StatePath
$st.mode = 'subscription'
Write-JsonFile $StatePath $st
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$s = Read-JsonFile $sandboxSettings
Assert ($null -eq $s.env.PSObject.Properties['CLAUDE_CODE_USE_BEDROCK']) 'monitor: repaired settings that drifted to bedrock'
Assert ((Get-Content (Join-Path $sandbox 'log.txt') -Raw) -match 'drift') 'monitor: logged the drift'

# The same repair in the other direction must not eat the auto-return timer:
# Set-ClaudeBackend nulls resetAt whenever -ResetAt is not passed.
$futureReset = (Get-Date).AddHours(3)
Set-ClaudeBackend -Mode bedrock -ResetAt $futureReset -Reason 'test'
$s = Read-JsonFile $sandboxSettings
$s.env.PSObject.Properties.Remove('CLAUDE_CODE_USE_BEDROCK')   # drift to subscription
Write-JsonFile $sandboxSettings $s
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$s = Read-JsonFile $sandboxSettings
$st = Read-JsonFile $StatePath
Assert ($s.env.CLAUDE_CODE_USE_BEDROCK -eq '1') 'monitor: repaired settings that drifted to subscription'
Assert ($null -ne $st.resetAt -and
  [Math]::Abs(((ConvertFrom-IsoDate $st.resetAt) - $futureReset).TotalMinutes) -lt 2) 'monitor: drift repair kept the auto-return timer'

Write-Host ''
Write-Host '-- Set-ClaudeBackend: refuses a destination that cannot answer --'

# A geography-scoped inference profile only resolves in its own region, so
# us.* ids in front of eu-west-1 answer every call with HTTP 400. Flipping onto
# that is worse than staying rate-limited, because the failure is silent.
$cfgPath   = Join-Path $sandbox 'config.json'
$cfgBackup = [System.IO.File]::ReadAllText($cfgPath)
$cfg = Read-JsonFile $cfgPath
$cfg.bedrockEnv.ANTHROPIC_DEFAULT_SONNET_MODEL = 'us.anthropic.claude-sonnet-5[1m]'
Write-JsonFile $cfgPath $cfg
Set-ClaudeBackend -Mode subscription -Reason 'test'
$threw = $false; $guardErr = ''
try { Set-ClaudeBackend -Mode bedrock -Reason 'test' }
catch { $threw = $true; $guardErr = $_.Exception.Message }
Assert $threw 'guard: refused to switch on a region/profile mismatch'
Assert ($guardErr -match 'does not resolve in eu-west-1') 'guard: named the mismatch'
$s = Read-JsonFile $sandboxSettings
Assert ($null -eq $s.env.PSObject.Properties['CLAUDE_CODE_USE_BEDROCK']) 'guard: left settings on subscription'
Assert ((Read-JsonFile $StatePath).mode -eq 'subscription') 'guard: left state on subscription'
[System.IO.File]::WriteAllText($cfgPath, $cfgBackup)

# A warning is not a veto. This sandbox config has no Haiku id, so auto mode
# would degrade on Bedrock - but blocking the failover for that would strand the
# user on a subscription that has already hit its limit.
Set-ClaudeBackend -Mode bedrock -Reason 'test'
Assert ((Read-JsonFile $StatePath).mode -eq 'bedrock') 'guard: a warning-only config still fails over'
Assert ((Get-Content (Join-Path $sandbox 'log.txt') -Raw) -match 'HAIKU') 'guard: logged the Haiku warning'

# The 2026-08-21 shape exactly, and the one a naive check misses: a config that
# is internally consistent - us.* ids alongside a declared us-east-1 - but whose
# region is overridden at runtime by a value persisted in the user environment.
# On paper it reads fine; every call still returns 400.
$cfg = Read-JsonFile $cfgPath
$cfg.bedrockEnv.AWS_REGION = 'us-east-1'
$cfg.bedrockEnv.ANTHROPIC_DEFAULT_SONNET_MODEL = 'us.anthropic.claude-sonnet-5[1m]'
Write-JsonFile $cfgPath $cfg
Set-ClaudeBackend -Mode subscription -Reason 'test'
$threw = $false; $guardErr = ''
try { Set-ClaudeBackend -Mode bedrock -Reason 'test' }
catch { $threw = $true; $guardErr = $_.Exception.Message }
Assert $threw 'guard: caught a self-consistent config that the environment overrides'
Assert ($guardErr -match 'does not resolve in eu-west-1') 'guard: judged the ids against the effective region'
[System.IO.File]::WriteAllText($cfgPath, $cfgBackup)

# A global.* profile resolves in every region, so it must never be flagged
# fatal however the regions disagree - that property is why the installer seeds
# global ids rather than a geography it had to guess.
$cfg = Read-JsonFile $cfgPath
$cfg.bedrockEnv.AWS_REGION = 'us-east-1'
$cfg.bedrockEnv.ANTHROPIC_DEFAULT_SONNET_MODEL = 'global.anthropic.claude-sonnet-5[1m]'
$probs = @(Get-BedrockEnvIssue $cfg.bedrockEnv)
Assert (@($probs | Where-Object { $_.Severity -eq 'fatal' }).Count -eq 0) 'guard: a global.* id is region-agnostic, never fatal'
Assert (@($probs | Where-Object { $_.Message -match 'wins at runtime' }).Count -eq 1) 'guard: flagged the declared region as inert'

Write-Host ''
Write-Host '-- monitor: never marks a file read that it did not read --'

# The offset was advanced for every candidate file, including the ones the loop
# skipped because an earlier file had already produced a hit. Those files were
# recorded as read to full length without being opened, so a limit error inside
# one of them was passed over once and then invisible for good.
$offDir = Join-Path $sandbox '.claude\projects\offsets'
New-Item -ItemType Directory -Force -Path $offDir | Out-Null
$epochC  = [System.DateTimeOffset]::Now.AddHours(2).ToUnixTimeSeconds()
$lineC   = '{"type":"assistant","isApiError' + 'Message":true,"text":"Claude AI usage ' + 'limit reached' + $pipe + $epochC + '"}'
$fileA   = Join-Path $offDir 'a-first.jsonl'
$fileB   = Join-Path $offDir 'b-second.jsonl'
Set-Content -Path $fileA -Value $lineC -Encoding UTF8
Set-Content -Path $fileB -Value $lineC -Encoding UTF8
# Offsets are keyed by FullName. %TEMP% can be an 8.3 short path while
# Get-ChildItem inside the monitor always yields the long form, so compare
# resolved paths or every lookup below silently misses.
$fileA = (Get-Item $fileA).FullName
$fileB = (Get-Item $fileB).FullName
$st = Read-JsonFile $StatePath
$st.mode = 'subscription'; $st.resetAt = $null
Write-JsonFile $StatePath $st
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'offsets: first of the two files triggered the flip'
$unread = @(@($fileA, $fileB) | Where-Object { -not (Get-Prop $st.fileOffsets $_ 0) })
Assert ($unread.Count -eq 1) 'offsets: the file left unscanned kept no offset'

# So the error still in that file must be found on the next run.
$st.mode = 'subscription'; $st.resetAt = $null
Write-JsonFile $StatePath $st
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
Assert ((Read-JsonFile $StatePath).mode -eq 'bedrock') 'offsets: the skipped file is still seen on the next run'

Write-Host ''
Write-Host '-- claude-switch check: verifies the Bedrock destination --'

# A fake `aws` on PATH stands in for the real CLI - first failing (bad model /
# no access), then succeeding - so the test stays offline and free.
$shimDir = Join-Path $sandbox 'shim'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
$oldPath = $env:PATH
@'
@echo off
echo An error occurred (ValidationException) when calling the Converse operation: The provided model identifier is invalid. 1>&2
exit /b 254
'@ | Set-Content -Path (Join-Path $shimDir 'aws.cmd') -Encoding ASCII
try {
  $env:PATH = $shimDir + ';' + $env:PATH
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'claude-switch.ps1') check | Out-String
  Assert ($LASTEXITCODE -eq 1) 'check: exits 1 when a model fails'
  Assert ($out -match 'FAIL\s+eu\.anthropic') 'check: names the failing model id'
  Assert ($out -match 'model identifier is invalid') 'check: surfaces the AWS error text'

  @'
@echo off
echo {"stopReason":"end_turn"}
exit /b 0
'@ | Set-Content -Path (Join-Path $shimDir 'aws.cmd') -Encoding ASCII
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'claude-switch.ps1') check | Out-String
  Assert ($LASTEXITCODE -eq 0) 'check: exits 0 when all models answer'
  Assert ($out -match 'destination verified') 'check: reports success'
}
finally { $env:PATH = $oldPath }

Write-Host ''
Write-Host '-- log output is written without an intact trigger --'
$logText = Get-Content (Join-Path $sandbox 'log.txt') -Raw
Assert ($logText -notmatch 'limit reached\|\d{10,13}') 'log never contains an intact machine-readable trigger'

# Hand the shell back the region it came with.
$env:AWS_REGION = $oldAwsRegion
if ($hadAwsDefault) { $env:AWS_DEFAULT_REGION = $oldAwsDefault }

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green }
else { Write-Host ($script:fails.ToString() + ' TEST(S) FAILED') -ForegroundColor Red }
exit $script:fails
