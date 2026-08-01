# Static analysis gate. Fails on any Error or Warning that survives the
# documented exclusions in PSScriptAnalyzerSettings.psd1.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$Settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
  Write-Host 'PSScriptAnalyzer is not installed. Install it with:' -ForegroundColor Yellow
  Write-Host '  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
  exit 1
}

Import-Module PSScriptAnalyzer
$findings = @(Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $Settings)

if ($findings.Count -eq 0) {
  Write-Host 'LINT CLEAN' -ForegroundColor Green
  exit 0
}

$findings |
  Select-Object Severity, RuleName, @{n = 'File'; e = { Split-Path $_.ScriptPath -Leaf } }, Line, Message |
  Sort-Object Severity, File, Line |
  Format-Table -AutoSize -Wrap |
  Out-String |
  Write-Host

Write-Host ('{0} LINT FINDING(S)' -f $findings.Count) -ForegroundColor Red
exit 1
