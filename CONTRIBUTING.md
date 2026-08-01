# Contributing

Internal Isentroniq tooling. Small repo, plain PowerShell, no build step.

## Layout

| path | what it is |
|---|---|
| `install.ps1` / `uninstall.ps1` | per-user setup and removal, no admin required |
| `src/common.ps1` | shared helpers, dot-sourced by everything else |
| `src/monitor.ps1` | the scheduled-task body: detect limit, flip, flip back |
| `src/claude-switch.ps1` | the CLI |
| `src/statusline.ps1` | Claude Code statusline |
| `tests/smoke.ps1` | switching logic, reset parsing, transcript scanning |
| `tests/lifecycle.ps1` | installer/uninstaller end to end |
| `tests/lint.ps1` | PSScriptAnalyzer gate |

`src/` is what gets copied to `~\.claude-autoswitch\bin` at install time. After
changing anything in `src/`, re-run `install.ps1` — the installed copy is what
actually runs, and editing the repo alone changes nothing on your machine.

## Running the checks

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\lint.ps1
powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File .\tests\lifecycle.ps1
```

All three are safe to run on a machine with a live install: they work in
sandboxes under `%TEMP%` with an overridden `USERPROFILE`, pass `-NoPath`, and
use a `ClaudeAutoswitchTest` task name so they can never touch your real PATH,
your real `~/.claude/settings.json`, or the real monitor task.

The lint gate needs PSScriptAnalyzer once:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

CI runs exactly these three on `windows-latest`.

## Conventions

- **Target Windows PowerShell 5.1**, not pwsh 7. That is the shell Claude Code
  launches on Windows, and it is what CI uses. No ternary or null-coalescing
  operators, no `-AsHashtable`; `ConvertFrom-Json` yields a `PSCustomObject`, so
  probe properties through the `Get-Prop`/`Set-Prop` helpers in `common.ps1`.
- **Never write the limit-error trigger text literally into a file in this
  repo.** The test suite assembles those strings at runtime by concatenation on
  purpose. A transcript containing this repo's source — a Claude Code session
  that opened these files, for instance — would otherwise look exactly like a
  real limit error to the monitor and cause a spurious switch.
- **Touch only the keys listed in `config.json`.** `settings.json` belongs to
  the user; `Set-ClaudeBackend` adds and removes the managed env keys and leaves
  everything else byte-for-byte alone. There is a test for that.
- **Anything under `%LOCALAPPDATA%` is suspect.** See the MSIX section of
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md) before adding a new state location.
- **No secrets in the repo or in `config.json`** — profile names and model IDs
  only. Bedrock auth stays in the normal AWS credential chain, and each user
  keeps their own Claude seat.
- Lint exclusions live in `PSScriptAnalyzerSettings.psd1`, each with a written
  justification. If you need a new one, write down why.

## Changing limit detection

The patterns in `src/monitor.ps1` are the most likely thing to rot, since they
depend on Claude Code's error text. Keep them narrow enough that ordinary
conversation mentioning usage limits does not trigger a switch, and add a case
to `tests/smoke.ps1` for any new form. `TROUBLESHOOTING.md` explains how to
capture a real limit error to work from.
