# claude-autoswitch shared helpers. Dot-source this file from sibling scripts.
# Data layout (created by install.ps1):
#   ~\.claude-autoswitch\bin\*.ps1   <- these scripts
#   ~\.claude-autoswitch\config.json <- per-machine backend config
#   ~\.claude-autoswitch\state.json  <- current mode + timers
#   ~\.claude-autoswitch\log.txt
# (deliberately not %LOCALAPPDATA% - see the note in install.ps1)

$DataDir      = Split-Path $PSScriptRoot -Parent
$ConfigPath   = Join-Path $DataDir 'config.json'
$StatePath    = Join-Path $DataDir 'state.json'
$LogPath      = Join-Path $DataDir 'log.txt'
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$ProjectsDir  = Join-Path $env:USERPROFILE '.claude\projects'

function Get-Prop($Object, [string]$Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $Default
}

function Set-Prop($Object, [string]$Name, $Value) {
  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function ConvertFrom-IsoDate([string]$Value) {
  return [datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Write-Log([string]$Message) {
  try {
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    if ((Get-Item $LogPath).Length -gt 1MB) {
      $tail = Get-Content $LogPath -Tail 400
      Set-Content -Path $LogPath -Value $tail -Encoding UTF8
    }
  } catch {}
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  $raw = [System.IO.File]::ReadAllText($Path)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return ($raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 32
  # Per-process temp name so two writers never fight over the same scratch
  # file, plus a short retry: on-access virus scanning briefly locks a file
  # right after it is created, which used to abort a whole monitor run.
  $tmp = '{0}.{1}.tmp' -f $Path, $PID
  $enc = New-Object System.Text.UTF8Encoding($false)
  $lastErr = $null
  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
      [System.IO.File]::WriteAllText($tmp, $json, $enc)
      Move-Item -Path $tmp -Destination $Path -Force
      return
    }
    catch {
      $lastErr = $_
      Start-Sleep -Milliseconds (100 * ($attempt + 1))
    }
  }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  throw $lastErr
}

function Get-State {
  $state = Read-JsonFile $StatePath
  if ($null -eq $state) {
    $state = [pscustomobject]@{
      mode = 'subscription'; resetAt = $null; lastScan = $null
      lastFlipBackAt = $null; lastSwitch = $null; reason = $null
    }
  }
  return $state
}

function Save-State($State) { Write-JsonFile $StatePath $State }

# Which backend is settings.json actually configured for right now?
function Get-SettingsBackend {
  $settings = Read-JsonFile $SettingsPath
  $envBlock = Get-Prop $settings 'env'
  if ($null -ne (Get-Prop $envBlock 'CLAUDE_CODE_USE_BEDROCK')) { return 'bedrock' }
  return 'subscription'
}

# Pull a limit-reset time out of an error/transcript line, if one is present.
# Understands the piped-unix-epoch form and "resets at <clock time>" prose.
# Returns $null when nothing parseable is found (caller picks a fallback).
function Get-ResetFromText([string]$Text) {
  $m = [regex]::Match($Text, 'limit reached\|(\d{10,13})', 'IgnoreCase')
  if ($m.Success) {
    $n = [int64]$m.Groups[1].Value
    if ($n -gt 100000000000) { $n = [int64]($n / 1000) }  # ms epoch -> s epoch
    return ([System.DateTimeOffset]::FromUnixTimeSeconds($n)).LocalDateTime
  }
  $m = [regex]::Match($Text, 'reset(?:s)?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?', 'IgnoreCase')
  if ($m.Success) {
    $h = [int]$m.Groups[1].Value
    $min = 0
    if ($m.Groups[2].Success) { $min = [int]$m.Groups[2].Value }
    $ap = $m.Groups[3].Value.ToLower()
    if ($ap -eq 'pm' -and $h -lt 12) { $h += 12 }
    if ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
    if ($h -le 23) {
      $t = (Get-Date).Date.AddHours($h).AddMinutes($min)
      if ($t -le (Get-Date)) { $t = $t.AddDays(1) }
      return $t
    }
  }
  return $null
}

# Decide whether one transcript line is Claude genuinely reporting that the
# subscription limit was hit. Returns the error text, or $null.
#
# This MUST parse the line rather than substring-match it. A transcript records
# everything: command output, file contents, things the user or Claude typed.
# On 2026-08-04 a `claude-switch log` printout - which quotes an earlier limit
# error - was written back into a transcript as a tool result, matched the old
# raw-text patterns, and switched the machine to Bedrock for seven hours. Only
# an assistant record flagged as an API error counts; a tool result is
# type=user and is rejected here regardless of what text it carries.
function Get-LimitErrorFromLine([string]$Line) {
  if ($Line -notmatch 'limit') { return $null }   # cheap reject before parsing
  # The first line of a transcript carries a UTF-8 BOM, and ConvertFrom-Json
  # rejects it. Raw regex matching never noticed; parsing does.
  $Line = $Line.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
  try { $obj = $Line | ConvertFrom-Json } catch { return $null }
  if ($null -eq $obj) { return $null }
  if ((Get-Prop $obj 'type') -ne 'assistant') { return $null }
  if ((Get-Prop $obj 'isApiErrorMessage') -ne $true) { return $null }

  # The text sits either directly on the record or inside message.content[].
  $texts = @()
  $t = Get-Prop $obj 'text'
  if ($t) { $texts += [string]$t }
  $msg = Get-Prop $obj 'message'
  if ($msg) {
    $mt = Get-Prop $msg 'text'
    if ($mt) { $texts += [string]$mt }
    foreach ($c in @(Get-Prop $msg 'content')) {
      if ($null -eq $c) { continue }
      if ($c -is [string]) { $texts += $c }
      else {
        $ct = Get-Prop $c 'text'
        if ($ct) { $texts += [string]$ct }
      }
    }
  }

  foreach ($x in $texts) {
    if ($x -match 'limit reached\|\d{10,13}' -or $x -match 'usage limit') { return $x }
  }
  return $null
}

# Rewrite the managed env keys in ~/.claude/settings.json for the given mode.
# Only keys listed in config.json (bedrockEnv / subscriptionEnv) are touched;
# everything else in settings.json is preserved as-is.
function Set-ClaudeBackend {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('subscription', 'bedrock')][string]$Mode,
    [datetime]$ResetAt,
    [string]$Reason = 'manual'
  )
  $mutex = New-Object System.Threading.Mutex($false, 'ClaudeAutoswitchSettings')
  $owned = $mutex.WaitOne(10000)
  try {
    $config = Read-JsonFile $ConfigPath
    if ($null -eq $config) { throw "config.json not found at $ConfigPath - run install.ps1 first." }

    $settings = Read-JsonFile $SettingsPath
    if ($null -eq $settings) { $settings = [pscustomobject]@{} }
    $envBlock = Get-Prop $settings 'env'
    if ($null -eq $envBlock) {
      $envBlock = [pscustomobject]@{}
      Set-Prop $settings 'env' $envBlock
    }

    $bedrockEnv = Get-Prop $config 'bedrockEnv' ([pscustomobject]@{})
    $subEnv     = Get-Prop $config 'subscriptionEnv' ([pscustomobject]@{})

    if ($Mode -eq 'bedrock') {
      foreach ($p in $subEnv.PSObject.Properties) {
        if ($envBlock.PSObject.Properties[$p.Name]) { $envBlock.PSObject.Properties.Remove($p.Name) }
      }
      foreach ($p in $bedrockEnv.PSObject.Properties) { Set-Prop $envBlock $p.Name $p.Value }
      $model = Get-Prop $config 'bedrockModel'
    }
    else {
      foreach ($p in $bedrockEnv.PSObject.Properties) {
        if ($envBlock.PSObject.Properties[$p.Name]) { $envBlock.PSObject.Properties.Remove($p.Name) }
      }
      foreach ($p in $subEnv.PSObject.Properties) { Set-Prop $envBlock $p.Name $p.Value }
      $model = Get-Prop $config 'subscriptionModel'
    }
    if ($model) { Set-Prop $settings 'model' $model }

    Write-JsonFile $SettingsPath $settings

    $state = Get-State
    Set-Prop $state 'mode' $Mode
    if ($PSBoundParameters.ContainsKey('ResetAt')) {
      Set-Prop $state 'resetAt' $ResetAt.ToString('o')
    } else {
      Set-Prop $state 'resetAt' $null
    }
    Set-Prop $state 'lastSwitch' ((Get-Date).ToString('o'))
    Set-Prop $state 'reason' $Reason
    if ($Mode -eq 'subscription') { Set-Prop $state 'lastFlipBackAt' ((Get-Date).ToString('o')) }
    Save-State $state

    $resetTxt = Get-Prop $state 'resetAt' '-'
    Write-Log ("switched -> {0} (reason: {1}; auto-return: {2})" -f $Mode, $Reason, $resetTxt)
  }
  finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}
