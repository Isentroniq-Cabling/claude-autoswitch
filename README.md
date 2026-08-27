# claude-autoswitch

[![CI](https://github.com/Isentroniq-Cabling/claude-autoswitch/actions/workflows/ci.yml/badge.svg)](https://github.com/Isentroniq-Cabling/claude-autoswitch/actions/workflows/ci.yml)

Subscription-first Claude Code on Windows: run on your Claude **Teams
subscription** until you hit its usage limit, automatically fall over to **AWS
Bedrock** (pay-per-token), and automatically switch back when the limit window
resets. Everyone keeps their own seat and their own AWS credentials — this tool
only edits the local `~/.claude/settings.json`.

## How it works

Claude Code picks its backend from the `env` block in `~/.claude/settings.json`
(`CLAUDE_CODE_USE_BEDROCK=1` + AWS profile/region/model IDs = Bedrock; without
those keys it uses your cached claude.ai login). This tool manages exactly
those keys and nothing else.

Four pieces:

- **`claude-switch`** (CLI) — manual switching and status, including your real
  subscription usage (5-hour and weekly windows, used % and reset times).
- **Desktop shortcuts** — "Claude - Subscription" and "Claude - Bedrock", the
  same switch packaged for a double-click: a console opens, switches, shows
  the resulting status, and waits for Enter. Two explicit icons rather than a
  toggle, so what a click does never depends on state. This is the
  deterministic path; the monitor below is best-effort by nature.
- **Monitor** (Task Scheduler job, every 5 min) —
  - in *subscription* mode, scans recent Claude Code transcripts
    (`~/.claude/projects/**/*.jsonl`) for the API error Claude Code writes when
    you hit your usage limit. On a **plan-limit** hit it flips to Bedrock and
    records when the limit window resets (parsed from the error, else from the
    captured usage data, else a 5-hour fallback). A **credit-cap** error
    (Fable 5 / monthly spend cap) is logged and never acted on — the plan's
    other models still work, so that's a `/model` problem, not a backend one.
  - in *bedrock* mode, flips back to subscription once that reset time passes.
    A *manual* switch to Bedrock (no auto-return time) is never flipped back.
  - in either mode, if something outside the tool changed the backend in
    `settings.json` (a hand edit, another tool, a restored backup), adopts it:
    state follows the file, the change is treated as a manual switch, and
    anything wrong with the adopted env is logged. The file sessions actually
    read always wins.
- **Statusline** — shows `[SUB]` / `[BEDROCK]` for the current session, plus
  what new sessions will use and the countdown to the auto-return. It also
  captures the `rate_limits` data Claude Code pipes to it — the only place the
  real usage numbers are exposed — into `~\.claude-autoswitch\usage.json` for
  `status` and the monitor.

Deliberately, we switch at 100% of the subscription rather than ~95%: there is
no supported API that exposes your subscription usage percentage, and reacting
to the actual limit error both squeezes out the full subscription and needs no
guesswork.

## Install

Setting up a machine for the Isentroniq rollout? Use the one-command
[setup.ps1](setup.ps1) flow under **Team rollout** below — it wraps everything
on this page. What follows is the generic, org-agnostic install.

```powershell
git clone <this-repo>
cd claude-autoswitch
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

On a machine that already runs Claude Code against Bedrock, the installer
copies your existing Bedrock env (profile, region, model IDs) from
`settings.json` into `config.json`. On a fresh machine pass them in:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AwsProfile my-sso-profile -Region eu-west-1
```

The installer is per-user (no admin), installs to and backs up `settings.json`
into `~\.claude-autoswitch\`, puts the two switch shortcuts on your Desktop
(`-NoShortcuts` to skip), and **does not change your current backend** — it
adopts whatever you are on. To start subscription-first behavior:

```powershell
claude-switch sub
```

Then **verify the failover destination** — this makes one 1-token Bedrock call
per configured model, so a wrong profile name, region, or model id fails here,
in front of you, instead of at the moment you hit your limit:

```powershell
claude-switch check
```

### Installer options

| flag | effect |
|---|---|
| `-AwsProfile` / `-Region` | Bedrock profile and region for a fresh machine (region is detected from the environment or `~/.aws/config` if omitted) |
| `-IntervalMinutes <n>` | how often the monitor checks (default 5) |
| `-NoStatusline` | don't add the statusline to `settings.json` |
| `-NoTask` | don't register the monitor task (manual switching only) |
| `-NoShortcuts` | don't create the two desktop shortcuts |
| `-ShortcutDir <dir>` | put the shortcuts somewhere other than the Desktop |
| `-NoPath` | leave the user PATH alone (unattended installs) |
| `-TaskName <name>` | override the scheduled-task name |

## Commands

```text
claude-switch status            mode, timers, subscription usage, monitor state
claude-switch sub               use the Teams subscription (claude.ai login)
claude-switch bedrock           use Bedrock until told otherwise
claude-switch bedrock -Hours 5  use Bedrock, auto-return to sub in 5 hours
claude-switch bedrock -ResetAt "2026-07-25 18:00"
claude-switch check             live-test every Bedrock model in config.json
claude-switch enable|disable    background monitor on/off
claude-switch log               recent activity
```

## Configuration (`~\.claude-autoswitch\config.json`)

| key | meaning |
|---|---|
| `bedrockEnv` | env keys written into `settings.json` in Bedrock mode and removed in subscription mode |
| `subscriptionEnv` | optional extra env keys for subscription mode (usually empty) |
| `subscriptionModel` / `bedrockModel` | optional per-mode value for the top-level `model` setting; `null` leaves it untouched |

If your subscription plan doesn't include the model you use on Bedrock, set
`subscriptionModel` (e.g. `"opus"`) so subscription sessions start on a model
your plan offers.

## Things to know

- **Switches apply to new sessions.** Env is read at session start, so a
  running chat keeps its backend. After a flip, start a new chat or run
  `claude --continue` in the CLI to resume the conversation on the new backend.
- **Detection is reactive.** After hitting the limit, the flip happens on the
  monitor's next run (≤5 min). Until then, requests in subscription mode fail
  with the limit message — retry after the flip.
- **A Fable "spend limit" is not a subscription limit.** Fable 5 draws on org
  usage credits, not your plan windows; when those cap, the other models still
  work. The monitor logs it (`status` shows when one was last seen) and
  deliberately does not switch — `/model opus` in the session is the fix. See
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the full story.
- **Weekly caps.** If the reset time can't be parsed and you re-hit the limit
  right after an auto-return (typical of the weekly cap), the monitor backs
  off to a 24 h stay on Bedrock instead of 5 h. Check `claude-switch log` if
  the timing looks off.
- **Error formats can change** with Claude Code releases. Detection requires
  either the limit error's machine-readable form or a line the CLI itself
  marked as an API error — ordinary conversation text that merely mentions
  usage limits will not trigger a switch. If detection ever stops working,
  look at a fresh limit error in `~/.claude/projects/...jsonl` and update the
  patterns in `src/monitor.ps1`.
- **Backends aren't perfectly identical.** Model lineup and rollout timing can
  differ between claude.ai and Bedrock, and the data path differs (Bedrock
  requests go through your AWS account; subscription requests go to
  Anthropic). The statusline keeps which one you're on visible at all times.
- **No secrets stored.** Bedrock auth stays with your normal AWS credential
  chain (`aws sso login`). `config.json` holds profile names and model IDs
  only, and lives outside the repo in `~\.claude-autoswitch\`.
- **Don't install into `%LOCALAPPDATA%`.** Inside an MSIX/AppContainer app (a
  Claude Code shell hosted by the Claude desktop app, for one) writes under
  `%LOCALAPPDATA%` are silently redirected into that package's `LocalCache`.
  The path resolves normally from inside, so an install there looks successful,
  but Task Scheduler runs outside the container and cannot see it — the monitor
  then never runs and the task just flashes a console window on every trigger.
  `install.ps1` uses `~\.claude-autoswitch` and hard-fails if it detects the
  redirection. If you're unsure what an outside process sees, check
  `(Get-Item <path> -Force).Target` — non-empty means redirected.
- **No console flash.** The task launches via `conhost --headless`;
  `powershell.exe -WindowStyle Hidden` is not enough, since conhost creates the
  window before PowerShell can hide it.

## Development

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\lint.ps1
powershell -ExecutionPolicy Bypass -File .\tests\smoke.ps1
powershell -ExecutionPolicy Bypass -File .\tests\lifecycle.ps1
```

All three are sandboxed and safe to run on a machine with a live install. CI
runs the same three on `windows-latest` under Windows PowerShell 5.1. See
[CONTRIBUTING.md](CONTRIBUTING.md) for conventions — in particular, why the
tests never contain the limit-error trigger text literally.

If something isn't behaving, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers the
known failure modes and how to diagnose each one.

## Team rollout

1. Prerequisites, once per machine: [AWS CLI v2](https://aws.amazon.com/cli/),
   git, and Claude Code signed in to the Teams subscription.
2. Clone and run the org bootstrap — the SSO start URL and account id come
   from your admin (they are parameters precisely so they don't live in this
   public repo):

   ```powershell
   git clone https://github.com/Isentroniq-Cabling/claude-autoswitch.git
   cd claude-autoswitch
   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -SsoStartUrl <url> -SsoAccountId <id>
   ```

   [setup.ps1](setup.ps1) does the whole thing: configures the AWS SSO
   profile, seeds `config.json` with the org model ids, runs `install.ps1`
   (monitor, statusline, desktop shortcuts, PATH), wires `awsAuthRefresh` so
   Claude Code refreshes the SSO login itself, starts subscription-first,
   opens the SSO sign-in, and finishes with `claude-switch check` so a broken
   failover destination fails here instead of at the moment a limit hits.
   Seats and AWS identities stay per-user — don't share either.
3. Day-to-day: nothing. Work on the subscription; when a limit hits, new
   sessions ride Bedrock until the window resets. For anyone who never opens
   a terminal, the two desktop icons are the whole interface: click the
   backend you want, read the status, press Enter.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1            # keep config/backups
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -PurgeData # remove everything
```

Uninstalling leaves `settings.json` on whichever backend it is currently set
to. `uninstall.ps1` takes the same `-NoPath` and `-TaskName` flags as the
installer.

---

Internal Isentroniq tooling — not licensed for external distribution.
Version history in [CHANGELOG.md](CHANGELOG.md).
