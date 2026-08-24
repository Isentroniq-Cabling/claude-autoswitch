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

# Cross-check bedrockEnv for the mistakes that cannot work, without a network
# call, so this can run on every switch. A Bedrock inference profile is
# geography-scoped: `us.anthropic.*` resolves only in a us-* region, `eu.` only
# in eu-*, `apac.` only in ap-*; `global.` resolves anywhere, and a bare
# `anthropic.*` id is single-region and unverifiable from here.
#
# Getting this wrong answers every call with HTTP 400 "The provided model
# identifier is invalid." On 2026-08-21 a hand edit put us.* ids in front of an
# eu-west-1 profile: the desktop main loop authenticates against Anthropic
# directly and kept working, so nothing looked broken, while the auto-mode
# permission classifier - which does go through Bedrock - failed closed on
# every tool call for three days.
#
# Returns objects with Severity ('fatal'|'warning') and Message; empty means
# internally consistent. Wrap calls in @() - PowerShell unrolls an empty array
# to $null on return.
#
# Severity is the difference between "this destination cannot answer at all"
# and "it will answer, one feature degrades". Blocking a failover for the
# second kind would strand the user on a rate-limited subscription, which is a
# worse outcome than the fault being reported.
function Get-BedrockEnvIssue($BedrockEnv) {
  $problems = @()
  function New-Problem([string]$Severity, [string]$Message) {
    return [pscustomobject]@{ Severity = $Severity; Message = $Message }
  }
  $declared = [string](Get-Prop $BedrockEnv 'AWS_REGION')
  $models = @($BedrockEnv.PSObject.Properties | Where-Object { $_.Name -like 'ANTHROPIC_DEFAULT_*_MODEL' })

  # The region the ids have to match is the one that will actually apply, which
  # is not always the one written here. A region persisted in the user
  # environment (setx / HKCU:\Environment) is present in every process Claude
  # Code starts and takes precedence over the env block settings.json injects,
  # so the declared region can be completely inert.
  #
  # Checking the ids against the declared region alone would pass the exact
  # config that broke this machine: config.json named us-east-1, the
  # environment named eu-west-1, and the us.* ids 400ed against it. Internally
  # consistent, still dead.
  $ambient = ''
  foreach ($v in @($env:AWS_REGION, $env:AWS_DEFAULT_REGION)) {
    if ($v -and -not $ambient) { $ambient = [string]$v }
  }
  $region = $declared
  if ($ambient) { $region = $ambient }

  if (-not $region) {
    $problems += New-Problem 'fatal' 'AWS_REGION is not set in bedrockEnv.'
  }
  elseif (-not $declared) {
    $problems += New-Problem 'warning' ('AWS_REGION is not set in bedrockEnv - the backend only works because "{0}" is set in the environment, which this tool does not control.' -f $ambient)
  }
  elseif ($ambient -ne $declared) {
    $problems += New-Problem 'warning' ('AWS_REGION is "{0}" in bedrockEnv but "{1}" is set in the environment and wins at runtime - model ids are checked against "{1}".' -f $declared, $ambient)
  }
  if ($models.Count -eq 0) { $problems += New-Problem 'fatal' 'bedrockEnv has no ANTHROPIC_DEFAULT_*_MODEL entries.' }

  # Auto mode runs its permission classifier as a separate Haiku-class call, so
  # without a Haiku id that classifier has nothing to run on and fails closed.
  # A warning, not fatal: the main loop still works on the other ids, and a
  # degraded auto mode beats no failover at all.
  if ($models.Count -gt 0 -and -not (Get-Prop $BedrockEnv 'ANTHROPIC_DEFAULT_HAIKU_MODEL')) {
    $problems += New-Problem 'warning' 'ANTHROPIC_DEFAULT_HAIKU_MODEL is not set - auto mode''s permission classifier has no model on Bedrock and will deny tool calls.'
  }

  # Fatal: a geography mismatch 400s every call made with that id, and if it is
  # wrong for one id it is normally wrong for all of them.
  if ($region) {
    $geoPrefix = @{ 'us' = 'us-'; 'eu' = 'eu-'; 'apac' = 'ap-' }
    foreach ($m in $models) {
      $id  = [string]$m.Value
      $geo = ([regex]::Match($id, '^(us|eu|apac|global)\.anthropic\.')).Groups[1].Value
      if (-not $geo -or $geo -eq 'global') { continue }
      if (-not $region.StartsWith($geoPrefix[$geo])) {
        $problems += New-Problem 'fatal' ('{0} is "{1}" but AWS_REGION is "{2}" - a {3}. profile does not resolve in {2}.' -f
          $m.Name, $id, $region, $geo)
      }
    }
  }
  return $problems
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
      # Never route anyone to a destination whose own config cannot answer.
      # Sitting out a rate-limited subscription window beats flipping onto a
      # backend that returns 400 on every call - the second failure is silent
      # and outlasts the limit that triggered it.
      $problems = @(Get-BedrockEnvIssue $bedrockEnv)
      foreach ($w in @($problems | Where-Object { $_.Severity -ne 'fatal' })) {
        Write-Log ('warning about bedrock config: ' + $w.Message)
      }
      $fatal = @($problems | Where-Object { $_.Severity -eq 'fatal' } | ForEach-Object { $_.Message })
      if ($fatal.Count -gt 0) {
        Write-Log ('refused switch -> bedrock: ' + ($fatal -join ' | '))
        throw ("bedrockEnv in $ConfigPath cannot work, refusing to switch:`n  - " + ($fatal -join "`n  - "))
      }
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
