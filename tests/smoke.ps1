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

# The guard only consults the environment when an env block declares no
# region, and that path reads the process env before the registry - so without
# a pin, the no-declared-region assertions would read whatever region the real
# machine (or its registry) supplies. Pin the process value so those cases
# resolve identically everywhere; child processes (the monitor runs) inherit it.
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
Write-Host '-- statusline: captures the utilization feed --'

# Claude Code hands the statusline the real five_hour/seven_day windows
# (used % + reset times) - the only place those numbers are exposed. The
# statusline keeps the latest copy in usage.json for `status` and the monitor.
$resetIso = (Get-Date).AddHours(2).ToString('o')
$json = '{"model":{"id":"claude-fable-5","display_name":"Fable 5"},"rate_limits":{"five_hour":{"used_percentage":34,"resets_at":"' + $resetIso + '"},"seven_day":{"used_percentage":62,"resets_at":"' + $resetIso + '"}}}'
$out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'statusline.ps1')
Assert ($out -match '^\[SUB\] Fable 5') 'statusline: capture does not disturb the rendered line'
Assert (Test-Path $UsagePath) 'statusline: usage.json written'
$u = Read-JsonFile $UsagePath
Assert ([double](Get-Prop $u.five_hour 'used_percentage') -eq 34) 'statusline: 5h percentage captured'
Assert ([double](Get-Prop $u.seven_day 'used_percentage') -eq 62) 'statusline: 7d percentage captured'
Assert ($null -ne (Get-Prop $u 'capturedAt')) 'statusline: capture timestamped'

# Unchanged numbers must not rewrite the file (this runs on every render).
$stamp1 = (Get-Item $UsagePath).LastWriteTimeUtc
Start-Sleep -Milliseconds 60
$out = $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'statusline.ps1')
Assert ((Get-Item $UsagePath).LastWriteTimeUtc -eq $stamp1) 'statusline: unchanged data not rewritten'
$out = $json.Replace('"used_percentage":34', '"used_percentage":41') |
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'statusline.ps1')
Assert ([double](Get-Prop (Read-JsonFile $UsagePath).five_hour 'used_percentage') -eq 41) 'statusline: changed data rewritten'

# And `status` renders the captured numbers.
$realProfile = $env:USERPROFILE
try {
  $env:USERPROFILE = $sandbox
  $statusOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'claude-switch.ps1') status | Out-String
}
finally { $env:USERPROFILE = $realProfile }
Assert ($statusOut -match '5h 41%') 'status: shows the 5h window'
Assert ($statusOut -match '7d 62%') 'status: shows the 7d window'
Assert ($statusOut -match 'resets \w{3} \d{2}:\d{2}') 'status: shows a reset time'
# Later monitor tests assert the no-data fallbacks; leave no usage behind.
Remove-Item $UsagePath -Force

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

# Back to subscription the way a user would (both files, offsets preserved) -
# a raw state.json write would leave settings on bedrock, and the monitor now
# ADOPTS what settings says rather than repairing it.
Set-ClaudeBackend -Mode subscription -Reason 'test'
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
Set-ClaudeBackend -Mode subscription -Reason 'test'
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

# Back to subscription, both files.
Set-ClaudeBackend -Mode subscription -Reason 'test'

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
Write-Host '-- monitor: a credit-cap error is logged, never acted on --'

# 2026-08-24, both directions of the same mistake. The org spend cap said
# neither plan wording, so fourteen errors in one evening produced zero
# failovers; v1.1.3 then over-corrected by switching on it. The wording is a
# usage-credit cap - on this plan that is Fable 5, which draws credits instead
# of plan limits - so the other models still answer and a backend switch would
# trade a working subscription for paid Bedrock. Logged and noted in state,
# deliberately not acted on.
Set-ClaudeBackend -Mode subscription -Reason 'test'
$spendLine = '{"type":"assistant","isApiError' + 'Message":true,"text":"You' + [char]39 + 've hit your org' + [char]39 + 's monthly spend ' + 'limit - run /usage-credits to ask your admin for a higher limit"}'
$transcript4 = Join-Path $sandbox '.claude\projects\proj\session4.jsonl'
Set-Content -Path $transcript4 -Value $spendLine -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'monitor: credit-cap error does NOT switch'
Assert ($null -ne (Get-Prop $st 'lastCreditCap')) 'monitor: credit cap noted in state'
Assert ((Get-Content (Join-Path $sandbox 'log.txt') -Raw) -match 'credit cap seen') 'monitor: named the credit cap in the log'

# A plan-limit error arriving after (or among) credit noise must still flip -
# the credits branch keeps scanning, it does not eat the run.
$planAfterCredits = '{"type":"assistant","isApiError' + 'Message":true,"text":"Claude AI usage ' + 'limit reached' + $pipe + $epochFuture + '"}'
Add-Content -Path $transcript4 -Value @($spendLine, $planAfterCredits) -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
Assert ((Read-JsonFile $StatePath).mode -eq 'bedrock') 'monitor: plan limit still flips through credit noise'

Write-Host ''
Write-Host '-- monitor: auto-return taken from the captured utilization --'

# A prose limit error carries no reset time. Before falling back to the 5h
# guess, the monitor consults usage.json: a weekly window at 100% knows
# exactly when it resets, otherwise the 5h window's reset stands in.
Set-ClaudeBackend -Mode subscription -Reason 'test'
$weeklyReset = (Get-Date).AddDays(3)
Write-JsonFile $UsagePath ([pscustomobject]@{
  five_hour  = [pscustomobject]@{ used_percentage = 40; resets_at = (Get-Date).AddHours(1).ToString('o') }
  seven_day  = [pscustomobject]@{ used_percentage = 100; resets_at = $weeklyReset.ToString('o') }
  capturedAt = (Get-Date).ToString('o')
})
$proseLine = '{"type":"assistant","isApiError' + 'Message":true,"text":"You have reached your usage ' + 'limit."}'
$transcript5 = Join-Path $sandbox '.claude\projects\proj\session5.jsonl'
Set-Content -Path $transcript5 -Value $proseLine -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'monitor: prose limit with usage data still flips'
Assert ([Math]::Abs(((ConvertFrom-IsoDate $st.resetAt) - $weeklyReset).TotalMinutes) -lt 2) 'monitor: auto-return taken from the exhausted weekly window'

# Weekly window healthy: the 5h window's reset is the one that applies.
Set-ClaudeBackend -Mode subscription -Reason 'test'
$fiveReset = (Get-Date).AddMinutes(90)
Write-JsonFile $UsagePath ([pscustomobject]@{
  five_hour  = [pscustomobject]@{ used_percentage = 100; resets_at = $fiveReset.ToString('o') }
  seven_day  = [pscustomobject]@{ used_percentage = 62; resets_at = (Get-Date).AddDays(3).ToString('o') }
  capturedAt = (Get-Date).ToString('o')
})
Add-Content -Path $transcript5 -Value $proseLine -Encoding UTF8
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'monitor: second prose limit flipped again'
Assert ([Math]::Abs(((ConvertFrom-IsoDate $st.resetAt) - $fiveReset).TotalMinutes) -lt 2) 'monitor: auto-return taken from the 5h window'
Remove-Item $UsagePath -Force

Write-Host ''
Write-Host '-- monitor: adopts out-of-band backend changes --'

# settings.json is the file Claude Code actually reads, so a hand edit to it
# is the user exercising the same right claude-switch does. The first cut of
# this check reasserted state.json over the file - and on 2026-08-24 it
# reverted the user's own hand-switch to Bedrock four times in forty minutes
# while their subscription was out of monthly credits. Drift is adopted now,
# never fought.
Set-ClaudeBackend -Mode subscription -Reason 'test'
$s = Read-JsonFile $sandboxSettings
Set-Prop $s.env 'CLAUDE_CODE_USE_BEDROCK' '1'
Set-Prop $s.env 'AWS_REGION' 'eu-west-1'
Set-Prop $s.env 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'eu.anthropic.claude-sonnet-5[1m]'
Write-JsonFile $sandboxSettings $s
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$s = Read-JsonFile $sandboxSettings
$st = Read-JsonFile $StatePath
Assert ($s.env.CLAUDE_CODE_USE_BEDROCK -eq '1') 'monitor: adoption left the hand-edited settings alone'
Assert ($st.mode -eq 'bedrock') 'monitor: state followed the file to bedrock'
Assert ($null -eq $st.resetAt) 'monitor: an adopted switch is manual - no auto-return'
Assert ((Get-Content (Join-Path $sandbox 'log.txt') -Raw) -match 'adopting bedrock') 'monitor: logged the adoption'

# The other direction: a hand return to subscription while an auto-return was
# pending must clear the timer - the user has already done the returning.
Set-ClaudeBackend -Mode bedrock -ResetAt (Get-Date).AddHours(3) -Reason 'test'
$s = Read-JsonFile $sandboxSettings
$s.env.PSObject.Properties.Remove('CLAUDE_CODE_USE_BEDROCK')
Write-JsonFile $sandboxSettings $s
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'subscription') 'monitor: state followed the file back to subscription'
Assert ($null -eq $st.resetAt) 'monitor: hand return cleared the pending auto-return'

# A broken adopted env is a visibility problem, not grounds to override the
# human: the adoption stands, and everything wrong with the env is logged.
# us.* ids with no declared region resolve against the pinned eu-west-1.
$s = Read-JsonFile $sandboxSettings
Set-Prop $s.env 'CLAUDE_CODE_USE_BEDROCK' '1'
Set-Prop $s.env 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'us.anthropic.claude-sonnet-5[1m]'
if ($s.env.PSObject.Properties['AWS_REGION']) { $s.env.PSObject.Properties.Remove('AWS_REGION') }
Write-JsonFile $sandboxSettings $s
try {
  $env:USERPROFILE = $sandbox
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'monitor.ps1') | Out-Null
}
finally { $env:USERPROFILE = $oldProfile }
$st = Read-JsonFile $StatePath
Assert ($st.mode -eq 'bedrock') 'monitor: a broken env does not block adoption'
Assert ((Get-Content (Join-Path $sandbox 'log.txt') -Raw) -match 'does not resolve in eu-west-1') 'monitor: adoption logged the geography mismatch in the adopted env'
Set-ClaudeBackend -Mode subscription -Reason 'test'

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

# A config that declares its region is judged against that region, full stop:
# the declared value is written into settings.json on switch and reaches
# Claude Code's processes ahead of the machine environment. This exact shape -
# us.* ids, declared us-east-1, machine environment saying eu-west-1 - runs
# fine in production; an earlier revision of the guard assumed the environment
# won and refused it.
$cfg = Read-JsonFile $cfgPath
$cfg.bedrockEnv.AWS_REGION = 'us-east-1'
$cfg.bedrockEnv.ANTHROPIC_DEFAULT_SONNET_MODEL = 'us.anthropic.claude-sonnet-5[1m]'
$probs = @(Get-BedrockEnvIssue $cfg.bedrockEnv)
Assert (@($probs | Where-Object { $_.Severity -eq 'fatal' }).Count -eq 0) 'guard: declared region wins over the machine environment'

# No declared region at all leaves the choice to the environment - the actual
# 2026-08-21 shape: us.* ids, no AWS_REGION, on a machine that supplies
# eu-west-1. Fatal, and the dependence on an external value is called out.
$cfg.bedrockEnv.PSObject.Properties.Remove('AWS_REGION')
$probs = @(Get-BedrockEnvIssue $cfg.bedrockEnv)
Assert (@($probs | Where-Object { $_.Severity -eq 'fatal' -and $_.Message -match 'does not resolve in eu-west-1' }).Count -ge 1) 'guard: with no declared region the ids are judged against the environment'
Assert (@($probs | Where-Object { $_.Message -match 'comes from the machine environment' }).Count -eq 1) 'guard: flagged the missing declared region'

# A global.* profile resolves in every region, so it must never be flagged
# fatal whatever the regions say - that property is why the installer seeds
# global ids rather than a geography it had to guess.
$cfg = Read-JsonFile $cfgPath
$cfg.bedrockEnv.AWS_REGION = 'us-east-1'
$cfg.bedrockEnv.ANTHROPIC_DEFAULT_SONNET_MODEL = 'global.anthropic.claude-sonnet-5[1m]'
$probs = @(Get-BedrockEnvIssue $cfg.bedrockEnv)
Assert (@($probs | Where-Object { $_.Severity -eq 'fatal' }).Count -eq 0) 'guard: a global.* id is region-agnostic, never fatal'

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
Set-ClaudeBackend -Mode subscription -Reason 'test'
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
Set-ClaudeBackend -Mode subscription -Reason 'test'
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
