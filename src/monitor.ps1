# claude-autoswitch monitor - runs from Task Scheduler every few minutes.
# subscription mode: scan newly-appended transcript lines for a usage-limit
#                    error; on a PLAN-limit hit, flip to bedrock and remember
#                    when the limit window resets. A CREDIT-cap hit (Fable 5 /
#                    monthly spend cap) is logged and noted in state, never
#                    acted on - the plan's other models still answer.
# bedrock mode:      when the remembered reset time passes, flip back to
#                    subscription. Manual bedrock (no resetAt) is left alone.
# either mode:       if something else changed the backend in settings.json,
#                    adopt it - state follows the file, never the reverse.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Log excerpts with the machine-readable trigger broken up: the log is
# routinely printed back into a Claude Code session, and an intact copy in a
# transcript is exactly what caused the 2026-08-04 false positive. Belt and
# braces alongside the structural check in Get-LimitErrorFromLine.
function Get-SafeExcerpt([string]$Text) {
  if ($Text.Length -gt 200) { $Text = $Text.Substring(0, 200) }
  return ($Text -replace 'limit reached\|', ('limit-reach' + 'ed<pipe>'))
}

if (-not (Test-Path $ConfigPath)) { return }

# Only one monitor at a time. Task Scheduler will happily start a second run
# while the first is still going (and fires every missed run at once after the
# machine wakes) - on 2026-08-05 four instances performed and logged the same
# flip inside one second, and earlier overlaps died fighting over state.json.
$mutex = New-Object System.Threading.Mutex($false, 'ClaudeAutoswitchMonitor')
$owned = $false
try { $owned = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { $mutex.Dispose(); return }

try {
  $state = Get-State
  $now = Get-Date
  $mode = Get-Prop $state 'mode' 'subscription'

  # settings.json is what actually decides where Claude Code sends its calls;
  # state.json is only this tool's memory of where it last put things. When the
  # two disagree, the file was changed by something with more authority than a
  # scheduled task - a hand edit, another tool, a restored backup - so adopt
  # the file's answer instead of fighting it. The first cut of this check
  # (2026-08-24, morning) reasserted state over the file; by that evening it
  # had reverted the user's own hand-switch to Bedrock four times in forty
  # minutes, stranding them on a subscription that was out of monthly credits.
  # A scheduled task does not outrank the human.
  #
  # The 2026-08-21 outage this check exists for - Bedrock keys left in
  # settings.json that answered 400 on every call - is handled with
  # visibility, not reversal: adopt the backend, then run the static guard
  # over the env block actually in the file and log everything wrong with it.
  $settingsMode = Get-SettingsBackend
  if ($settingsMode -ne $mode) {
    Write-Log ("drift: settings.json says $settingsMode but state says $mode - adopting $settingsMode (out-of-band change)")
    Set-Prop $state 'mode' $settingsMode
    # An out-of-band switch has manual semantics: no auto-return. Whoever made
    # it decides when it ends.
    Set-Prop $state 'resetAt' $null
    Set-Prop $state 'lastSwitch' ($now.ToString('o'))
    Set-Prop $state 'reason' 'adopted out-of-band change'
    if ($settingsMode -eq 'subscription') { Set-Prop $state 'lastFlipBackAt' ($now.ToString('o')) }
    Save-State $state
    $mode = $settingsMode
    if ($settingsMode -eq 'bedrock') {
      $adoptedEnv = Get-Prop (Read-JsonFile $SettingsPath) 'env' ([pscustomobject]@{})
      foreach ($p in @(Get-BedrockEnvIssue $adoptedEnv)) {
        Write-Log ('adopted bedrock env, ' + $p.Severity + ': ' + $p.Message)
      }
    }
  }

  if ($mode -eq 'bedrock') {
    $resetRaw = Get-Prop $state 'resetAt'
    if ($resetRaw -and $now -ge (ConvertFrom-IsoDate $resetRaw)) {
      Set-ClaudeBackend -Mode subscription -Reason 'auto: limit window reset'
    }
    return
  }

  # --- subscription mode: look for a fresh limit error in the transcripts ---
  $sinceRaw = Get-Prop $state 'lastScan'
  if ($sinceRaw) { $since = (ConvertFrom-IsoDate $sinceRaw).AddMinutes(-1) } else { $since = $now.AddMinutes(-15) }

  # Per-file byte offsets so each run only scans lines appended since the last
  # one. Without this, an old limit error earlier in a still-active transcript
  # would re-trigger a flip every time the file is touched.
  $offsets = Get-Prop $state 'fileOffsets'
  if ($null -eq $offsets) { $offsets = [pscustomobject]@{} }

  $hit = $null
  $hitReset = $null
  $creditCap = $null
  if (Test-Path $ProjectsDir) {
    $files = Get-ChildItem -Path $ProjectsDir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $since }
    foreach ($f in $files) {
      $prev = [int64](Get-Prop $offsets $f.FullName 0)
      $len = $f.Length
      if ($len -lt $prev) { $prev = 0 }  # file replaced/truncated
      if ($len -gt $prev) {
        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try {
          [void]$fs.Seek($prev, 'Begin')
          $buf = New-Object byte[] ($len - $prev)
          $read = $fs.Read($buf, 0, $buf.Length)
          $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
        finally { $fs.Close() }

        foreach ($line in ($chunk -split "`n")) {
          # Structural check first: only a real assistant API-error record can
          # get past this. Text that merely quotes a limit error - a log dump
          # pasted into a chat, these very sources, documentation - is a tool
          # result or a plain message and is rejected.
          $errText = Get-LimitErrorFromLine $line
          if (-not $errText) { continue }

          if ((Get-LimitKind $errText) -eq 'credits') {
            # Usage credits ran out (Fable 5 / the org's monthly spend cap).
            # Model-scoped: the plan's other models still answer, so this is
            # noted, never acted on - flipping to Bedrock here is exactly the
            # false positive v1.1.3 shipped. /model moves the session to a
            # plan model for free; a real plan exhaustion still says the plan
            # wordings and still switches.
            if (-not $creditCap) {
              $creditCap = $errText
              Write-Log ('credit cap seen (usage credits, not a plan limit) - not switching: ' + (Get-SafeExcerpt $errText))
            }
            continue
          }

          $reset = Get-ResetFromText $errText
          if ($errText -match 'limit reached\|\d{10,13}') {
            # The machine-readable form carries its own reset time; if that
            # moment has already passed the error is from a spent window.
            if ($null -eq $reset -or $reset -le $now) { continue }
          }
          $hit = $errText
          $hitReset = $reset
          break
        }

        # Advance the offset only for a file this run actually read. Setting it
        # unconditionally for every file in $files - the shape before
        # 2026-08-24 - marked the ones after a hit as read to full length
        # without ever opening them, so a limit error sitting in one of those
        # was skipped once and then invisible for good: the next run starts
        # past it.
        Set-Prop $offsets $f.FullName $len
      }

      # One hit decides the flip. Stop, and leave every unscanned file's offset
      # where it was so the next run still sees what is in them.
      if ($null -ne $hit) { break }
    }
  }

  # Drop offset entries for transcripts that no longer exist.
  $kept = [pscustomobject]@{}
  foreach ($p in $offsets.PSObject.Properties) {
    if (Test-Path $p.Name) { Set-Prop $kept $p.Name $p.Value }
  }
  Set-Prop $state 'fileOffsets' $kept
  Set-Prop $state 'lastScan' ($now.ToString('o'))
  if ($creditCap) { Set-Prop $state 'lastCreditCap' ($now.ToString('o')) }
  Save-State $state

  if ($hit) {
    Write-Log ('limit detected in transcript: ' + (Get-SafeExcerpt $hit))

    if ($null -eq $hitReset) {
      # The error itself carried no reset time, but the statusline feed may
      # know it: Claude Code hands the statusline the real five_hour and
      # seven_day windows (used % + reset time), and statusline.ps1 keeps the
      # latest copy in usage.json. Passive data - only as fresh as the last
      # render - but a reset time still in the future is a reset time.
      $usage = Read-JsonFile $UsagePath
      if ($usage) {
        $seven = Get-Prop $usage 'seven_day'
        if ($seven -and [double](Get-Prop $seven 'used_percentage' 0) -ge 99) {
          $t = ConvertFrom-ResetStamp (Get-Prop $seven 'resets_at')
          if ($t -and $t -gt $now) {
            $hitReset = $t
            Write-Log ('auto-return taken from the weekly window in usage.json: ' + $t.ToString('o'))
          }
        }
        if ($null -eq $hitReset) {
          $t = ConvertFrom-ResetStamp (Get-Prop (Get-Prop $usage 'five_hour') 'resets_at')
          if ($t -and $t -gt $now) {
            $hitReset = $t
            Write-Log ('auto-return taken from the 5h window in usage.json: ' + $t.ToString('o'))
          }
        }
      }
    }
    if ($null -eq $hitReset) {
      # Still nothing. Default to the 5h session window; if we only just
      # flipped back and hit the wall again, assume a weekly cap instead.
      $flipBackRaw = Get-Prop $state 'lastFlipBackAt'
      $recentFlipBack = $false
      if ($flipBackRaw) { $recentFlipBack = ($now - (ConvertFrom-IsoDate $flipBackRaw)).TotalMinutes -lt 30 }
      if ($recentFlipBack) { $hitReset = $now.AddHours(24) } else { $hitReset = $now.AddHours(5) }
      Write-Log ('no reset time parseable, assuming auto-return at ' + $hitReset.ToString('o'))
    }
    Set-ClaudeBackend -Mode bedrock -ResetAt $hitReset -Reason 'auto: subscription limit reached'
  }
}
catch {
  Write-Log ('monitor error: ' + $_.Exception.Message)
}
finally {
  if ($owned) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
