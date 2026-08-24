# claude-autoswitch monitor - runs from Task Scheduler every few minutes.
# subscription mode: scan newly-appended transcript lines for a usage-limit
#                    error; on hit, flip to bedrock and remember when the
#                    limit window resets.
# bedrock mode:      when the remembered reset time passes, flip back to
#                    subscription. Manual bedrock (no resetAt) is left alone.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

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
  # state.json is only this tool's memory of where it last put it. Anything else
  # that writes the env block - a hand edit, a half-finished install, another
  # tool - desyncs the two, and nothing here used to look. On 2026-08-21 a hand
  # edit left Bedrock keys in settings.json while state said subscription; this
  # monitor then re-read that state every five minutes for three days and
  # reported healthy while auto mode was denying every tool call. Trust state
  # for intent, but make the file match it.
  $settingsMode = Get-SettingsBackend
  if ($settingsMode -ne $mode) {
    Write-Log ("drift: settings.json is $settingsMode but state says $mode - reasserting $mode")
    $driftReset = Get-Prop $state 'resetAt'
    if ($mode -eq 'bedrock' -and $driftReset) {
      # Pass resetAt through: Set-ClaudeBackend nulls it when -ResetAt is not
      # bound, so repairing without it would silently cancel the auto-return
      # and strand the machine on Bedrock.
      Set-ClaudeBackend -Mode $mode -ResetAt (ConvertFrom-IsoDate $driftReset) -Reason 'auto: drift repair'
    }
    else {
      Set-ClaudeBackend -Mode $mode -Reason 'auto: drift repair'
    }
    $state = Get-State   # Set-ClaudeBackend rewrote it
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
  Save-State $state

  if ($hit) {
    $excerpt = $hit
    if ($excerpt.Length -gt 200) { $excerpt = $excerpt.Substring(0, 200) }
    # Logged with the trigger broken up: the log is routinely printed back into
    # a Claude Code session, and an intact copy in a transcript is exactly what
    # caused the 2026-08-04 false positive. Belt and braces alongside the
    # structural check in Get-LimitErrorFromLine.
    $safeMarker = 'limit-reach' + 'ed<pipe>'
    $excerpt = $excerpt -replace 'limit reached\|', $safeMarker
    Write-Log ('limit detected in transcript: ' + $excerpt)

    if ($null -eq $hitReset) {
      # No parseable reset time. Default to the 5h session window; if we only
      # just flipped back and hit the wall again, assume a weekly cap instead.
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
