# Troubleshooting

Start here:

```powershell
claude-switch status
claude-switch log
```

`status` shows the mode, the auto-return timer, what `settings.json` is actually
set to, and whether the monitor task is registered. `log` shows what the monitor
has been doing. Most problems are visible in one of those two.

---

## The monitor never runs

Symptoms: you hit the subscription limit and nothing switches. `claude-switch
log` has no `switched ->` lines, or no lines at all since install.

Check what Task Scheduler thinks:

```powershell
Get-ScheduledTaskInfo -TaskName ClaudeAutoswitch | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

- `LastTaskResult` `0x0` — the monitor ran fine. The problem is elsewhere
  (see *Detection stopped working* below).
- `LastTaskResult` `0xFFFD0000` — PowerShell started but the script terminated.
  Nearly always means the `-File` path in the task action does not exist from
  Task Scheduler's point of view. This is the MSIX trap below.
- `LastRunTime` never advancing — the task is disabled
  (`claude-switch enable`) or its trigger was removed; re-run `install.ps1`.

### The MSIX trap (this cost us two days)

Inside an MSIX/AppContainer process — for example a Claude Code shell hosted by
the Claude **desktop app** — writes under `%LOCALAPPDATA%` are silently
redirected into that package's private `LocalCache` directory. From inside the
container the path resolves normally, so an install there looks completely
successful. But Task Scheduler runs *outside* the container and cannot see that
location at all, so the monitor never executes even once. The only outward sign
was a console window flashing every five minutes.

Check whether your install directory is redirected:

```powershell
(Get-Item "$env:USERPROFILE\.claude-autoswitch" -Force).Target
```

Empty output is correct. Any output means the directory is a reparse point and
an outside process will not reach it.

This is why the tool installs to `~\.claude-autoswitch` and not
`%LOCALAPPDATA%`, and why `install.ps1` hard-fails if it detects redirection.
If you hit this on an older install, re-run `install.ps1` from a **normal
terminal** (Windows Terminal or `powershell.exe` directly, not a shell hosted
inside a packaged app), then confirm the path baked into the task is real:

```powershell
(Get-ScheduledTask -TaskName ClaudeAutoswitch).Actions[0].Arguments
```

Every path in there must exist when you `Test-Path` it from a fresh terminal.

---

## A console window flashes every few minutes

The task must launch through `conhost.exe --headless`. `powershell.exe
-WindowStyle Hidden` is **not** sufficient: conhost creates the window before
PowerShell can apply the style, so you still get a visible flash.

Re-running `install.ps1` fixes the task action. Verify:

```powershell
(Get-ScheduledTask -TaskName ClaudeAutoswitch).Actions[0] | Select-Object Execute, Arguments
```

`Execute` should end in `conhost.exe` and `Arguments` should start with
`--headless`.

The other fix — running the task as S4U ("run whether user is logged on or
not") — needs elevation and is blocked on Intune-managed machines, which is why
this tool uses conhost instead.

---

## It switched, but my current session didn't change

Expected. Claude Code reads `env` from `settings.json` at session start, so a
running session keeps whichever backend it started on. Start a new chat, or in
the CLI run `claude --continue` to resume the same conversation on the new
backend.

The statusline shows this explicitly: it prints the backend for *this* session,
and `| new sessions: BEDROCK` when the configured backend has diverged from it.

---

## Detection stopped working after a Claude Code update

The monitor recognises a limit either by the error's machine-readable form or by
a transcript line the CLI itself marked as an API error. If Anthropic changes
that wording, detection can go quiet. To re-derive the pattern, hit the limit
once and look at what actually got written:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude\projects" -Recurse -Filter *.jsonl |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
  Select-String -Pattern 'limit'
```

Update the two patterns in [src/monitor.ps1](src/monitor.ps1), add a case to
[tests/smoke.ps1](tests/smoke.ps1), then re-run `install.ps1` to copy the new
script into place.

Note that ordinary conversation text mentioning usage limits deliberately does
**not** trigger a switch — that restriction is why the patterns are narrow.

---

## Stuck on Bedrock, never goes back

`claude-switch status` shows `auto-return to sub : -`.

That means `state.json` has no reset time, which the monitor treats as a
*manual* Bedrock selection and deliberately never reverts. This is also the
state a fresh install adopts on a machine already running Bedrock.

Fix: `claude-switch sub`. To use Bedrock with a deadline instead, pass one:
`claude-switch bedrock -Hours 5`.

---

## Subscription sessions start on a model my plan doesn't include

Set `subscriptionModel` in `~\.claude-autoswitch\config.json` to a model your
plan offers (for example `"opus"`), leaving `bedrockModel` as-is. Each switch
writes the matching value to the top-level `model` setting.

---

## Bedrock requests fail with expired or missing credentials

The tool never stores credentials; Bedrock auth uses your normal AWS chain.
Refresh your SSO session:

```powershell
aws sso login --profile isentroniq
```

Substitute the profile from `bedrockEnv.AWS_PROFILE` in your `config.json`.

---

## Inspect or reset state by hand

```powershell
Get-Content "$env:USERPROFILE\.claude-autoswitch\state.json"
Get-Content "$env:USERPROFILE\.claude-autoswitch\config.json"
Get-Content "$env:USERPROFILE\.claude-autoswitch\log.txt" -Tail 40
```

`install.ps1` backs up `settings.json` to
`~\.claude-autoswitch\settings.backup.<timestamp>.json` on every run, so you can
always get back to a known-good file.

Full reset, keeping your Claude config:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -PurgeData
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
