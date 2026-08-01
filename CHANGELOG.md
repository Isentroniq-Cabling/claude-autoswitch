# Changelog

## 1.1.0 — 2026-08-01

Recovery release. The 1.0.0 install looked healthy but the monitor had never
executed once; everything here follows from finding out why.

### Fixed

- **The monitor never ran.** Installs went to `%LOCALAPPDATA%`, which is
  silently redirected into a private `LocalCache` directory when the installer
  runs inside an MSIX/AppContainer process (such as a Claude Code shell hosted
  by the Claude desktop app). The path resolved from inside, so the install
  reported success, but Task Scheduler runs outside the container and could
  never reach `monitor.ps1`. The task failed with `0xFFFD0000` every five
  minutes for two days. Installs now go to `~\.claude-autoswitch`, and
  `install.ps1` hard-fails if that directory turns out to be redirected.
- **A console window flashed every five minutes.** The task now launches via
  `conhost.exe --headless`. `powershell.exe -WindowStyle Hidden` does not help:
  conhost creates the window before PowerShell can apply the style. (Running
  the task as S4U would also fix it but requires elevation, which is
  unavailable on Intune-managed machines.)
- `uninstall.ps1` also cleans up the legacy `%LOCALAPPDATA%` PATH entry left by
  1.0.0 installs.

### Added

- GitHub Actions CI: PSScriptAnalyzer static analysis, behavior tests, and
  installer lifecycle tests, all on `windows-latest` under Windows PowerShell
  5.1 to match the shell Claude Code actually launches.
- `tests/lifecycle.ps1` — exercises `install.ps1`/`uninstall.ps1` end to end in
  a sandboxed `USERPROFILE`, including a regression guard asserting that the
  script path baked into the scheduled task resolves from outside the
  installing process. That assertion is the MSIX bug, encoded.
- `-NoPath` and `-TaskName` on both `install.ps1` and `uninstall.ps1`, so
  unattended installs can leave PATH alone and a test run can never touch the
  real monitor task.
- `TROUBLESHOOTING.md`, `CONTRIBUTING.md`, this changelog, and a documented
  `PSScriptAnalyzerSettings.psd1`.

### Changed

- `Parse-IsoDate` renamed to `ConvertFrom-IsoDate` (approved PowerShell verb).
- Removed an unused `$BinDir` assignment from `src/common.ps1`.

## 1.0.0 — 2026-07-25

Initial version.

- `claude-switch` CLI: `status`, `sub`, `bedrock` (optionally with `-Hours` or
  `-ResetAt`), `enable`, `disable`, `log`.
- Monitor task that flips to Bedrock when a subscription usage limit is
  detected and back when the limit window resets, reading the reset time from
  the error where possible and falling back to 5 hours (24 hours if the limit
  recurs immediately after a flip back, the weekly-cap signature).
- Incremental transcript scanning with per-file byte offsets, so an old limit
  error in a still-active transcript cannot re-trigger a switch.
- Statusline showing `[SUB]`/`[BEDROCK]`, the configured backend for new
  sessions, and the countdown to auto-return.
- Per-user installer and uninstaller requiring no admin rights, seeding config
  from any Bedrock env already present in `settings.json`.
- Sandboxed smoke tests.
