# claude-autoswitch org bootstrap - everything a new machine needs, one command.
# Configures the AWS SSO profile, seeds config.json with the org's Bedrock
# model ids, installs the tool (monitor, statusline, desktop shortcuts, PATH),
# wires awsAuthRefresh so Claude Code re-runs the SSO login itself, starts
# subscription-first, signs into SSO and live-verifies the failover destination.
#
# Idempotent: safe on a fresh machine, safe to re-run on an existing setup.
# The org identifiers (SSO start URL, account id) are parameters rather than
# code, so this file carries no account coordinates and the repo can be public:
#
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 `
#     -SsoStartUrl https://<your-directory>.awsapps.com/start -SsoAccountId <account-id>
#
# Requires: AWS CLI v2. Claude Code itself can be installed before or after.
param(
  [Parameter(Mandatory = $true)][string]$SsoStartUrl,
  [Parameter(Mandatory = $true)][string]$SsoAccountId,
  [string]$SsoRegion   = 'eu-west-3',
  [string]$SsoRoleName = 'Bedrock-ClaudeCode',
  [string]$Region      = 'eu-west-1',
  [string]$ProfileName = 'isentroniq',

  # Model ids seeded into config.json (bedrockEnv): EU cross-region inference
  # profiles where they exist, so inference stays in EU geography; Fable only
  # has a global. profile. All of them are live-verified by `claude-switch
  # check` at the end, so a wrong id fails here, in front of you.
  [string]$FableModel  = 'global.anthropic.claude-fable-5[1m]',
  [string]$SonnetModel = 'eu.anthropic.claude-sonnet-5[1m]',
  [string]$OpusModel   = 'eu.anthropic.claude-opus-5',
  [string]$HaikuModel  = 'eu.anthropic.claude-haiku-4-5-20251001-v1:0',

  # Skip `aws sso login` and the live model check (unattended installs).
  [switch]$NoLogin,
  # Don't persist AWS_PROFILE/AWS_REGION into the user environment.
  [switch]$NoUserEnv,
  # Passed through to install.ps1 (unattended installs, and the test suite).
  [switch]$NoShortcuts,
  [switch]$NoPath,
  [string]$ShortcutDir,
  [string]$TaskName = 'ClaudeAutoswitch'
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '[1/6] Prerequisites'
if ($null -eq (Get-Command aws -ErrorAction SilentlyContinue)) {
  throw 'AWS CLI v2 not found on PATH. Install it (https://aws.amazon.com/cli/) and re-run.'
}
if ($null -eq (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Warning ('Claude Code not found on PATH. Install it and sign in to claude.ai; ' +
    'everything set up here applies as soon as it exists.')
}

Write-Host ('[2/6] AWS SSO profile "{0}" (account {1}, role {2}, region {3})' -f $ProfileName, $SsoAccountId, $SsoRoleName, $Region)
aws configure set ('sso-session.{0}.sso_start_url' -f $ProfileName) $SsoStartUrl
aws configure set ('sso-session.{0}.sso_region' -f $ProfileName) $SsoRegion
aws configure set ('sso-session.{0}.sso_registration_scopes' -f $ProfileName) 'sso:account:access'
aws configure set sso_session $ProfileName --profile $ProfileName
aws configure set sso_account_id $SsoAccountId --profile $ProfileName
aws configure set sso_role_name $SsoRoleName --profile $ProfileName
aws configure set region $Region --profile $ProfileName

Write-Host '[3/6] Backend config (~\.claude-autoswitch\config.json)'
$DataDir    = Join-Path $env:USERPROFILE '.claude-autoswitch'
$ConfigPath = Join-Path $DataDir 'config.json'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
if (Test-Path $ConfigPath) {
  Write-Host '  config.json already exists - keeping it (delete it and re-run to regenerate).'
}
else {
  $config = [ordered]@{
    bedrockEnv = [ordered]@{
      CLAUDE_CODE_USE_BEDROCK        = '1'
      AWS_PROFILE                    = $ProfileName
      AWS_REGION                     = $Region
      ANTHROPIC_DEFAULT_FABLE_MODEL  = $FableModel
      ANTHROPIC_DEFAULT_SONNET_MODEL = $SonnetModel
      ANTHROPIC_DEFAULT_OPUS_MODEL   = $OpusModel
      ANTHROPIC_DEFAULT_HAIKU_MODEL  = $HaikuModel
    }
    subscriptionEnv   = [ordered]@{}
    subscriptionModel = 'fable'
    bedrockModel      = 'fable'
  }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($ConfigPath, (($config | ConvertTo-Json -Depth 8) + "`n"), $enc)
  Write-Host '  config.json written.'
}

Write-Host '[4/6] Install claude-autoswitch (monitor, statusline, shortcuts, PATH)'
$installArgs = @{ TaskName = $TaskName }
if ($NoShortcuts) { $installArgs['NoShortcuts'] = $true }
if ($NoPath)      { $installArgs['NoPath'] = $true }
if ($ShortcutDir) { $installArgs['ShortcutDir'] = $ShortcutDir }
& (Join-Path $PSScriptRoot 'install.ps1') @installArgs

Write-Host '[5/6] Claude Code settings + backend'
$BinDir = Join-Path $DataDir 'bin'
. (Join-Path $BinDir 'common.ps1')

# awsAuthRefresh: Claude Code runs this itself when the SSO token expires, so
# nobody has to remember the login command.
$settings = Read-JsonFile $SettingsPath
if ($null -eq $settings) { $settings = [pscustomobject]@{} }
Set-Prop $settings 'awsAuthRefresh' ('aws sso login --profile {0}' -f $ProfileName)
Write-JsonFile $SettingsPath $settings
Write-Host ('  awsAuthRefresh = aws sso login --profile {0}' -f $ProfileName)

if (-not $NoUserEnv) {
  # Default profile/region for plain `aws` use in any shell. Harmless to the
  # switcher: a region declared in the settings env block wins at runtime,
  # these only fill what an env block leaves unset.
  [Environment]::SetEnvironmentVariable('AWS_PROFILE', $ProfileName, 'User')
  [Environment]::SetEnvironmentVariable('AWS_REGION', $Region, 'User')
  Write-Host ('  user environment: AWS_PROFILE={0}, AWS_REGION={1}' -f $ProfileName, $Region)
}

# Subscription-first: work on the Teams plan; the monitor fails over to
# Bedrock when a plan limit hits and comes back when it resets.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'claude-switch.ps1') sub
if ($LASTEXITCODE -ne 0) { throw 'claude-switch sub failed - see output above.' }

Write-Host '[6/6] Sign in + live-verify the Bedrock destination'
if ($NoLogin) {
  Write-Host ('  skipped (-NoLogin). Later, run:  aws sso login --profile {0}' -f $ProfileName)
  Write-Host '  then verify the failover with:   claude-switch check'
}
else {
  aws sso login --profile $ProfileName
  if ($LASTEXITCODE -ne 0) { throw ('aws sso login --profile {0} failed - see output above.' -f $ProfileName) }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BinDir 'claude-switch.ps1') check
  if ($LASTEXITCODE -ne 0) { throw 'The Bedrock destination failed verification - send the output above to an admin.' }
}

Write-Host ''
Write-Host 'Done. New Claude Code sessions run on the Teams subscription; the monitor'
Write-Host 'fails over to Bedrock when a plan limit hits, and the two desktop icons'
Write-Host '("Claude - Subscription" / "Claude - Bedrock") switch by hand, deterministically.'
