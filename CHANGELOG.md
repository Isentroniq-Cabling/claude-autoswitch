# Changelog

## 1.2.0 — 2026-08-27

### Fixed

- **Credit-cap errors no longer switch backends — reverting a 1.1.3
  misdiagnosis.** The "monthly spend limit" errors of 2026-08-24 were not the
  subscription running out: they were **Fable 5 exhausting the org's usage
  credits**, which that model draws instead of plan limits (the Claude Code
  binary says it outright: *"Fable 5 is now using usage credits instead of
  your plan limits"*, and one variant of the error even ends "Switch to
  another model to continue"). The 5-hour and weekly plan windows were fine
  the whole time. 1.1.3 made that wording a failover trigger, so a capped
  Fable — a `/model opus` problem, free to fix — would have moved the whole
  machine to paid Bedrock, daily. Detection now classifies limit errors
  (`Get-LimitKind`): plan wordings switch as before; credit wordings
  (`spend limit`, `usage credit`, `credit cap`) are logged, stamped into
  state (`lastCreditCap`, shown by `status`), and deliberately not acted on.
  If an org routes plan overage through credits, plan exhaustion still emits
  the plan wordings first, so nothing is stranded.

### Added

- **The statusline now captures the real subscription usage numbers.** Claude
  Code pipes `rate_limits` (five-hour and seven-day windows: used % + reset
  time) to the statusline on every render — the only place those numbers are
  exposed. `statusline.ps1` keeps the latest copy in
  `~\.claude-autoswitch\usage.json` (atomic, written only on change);
  `claude-switch status` displays it with its age; and when a limit error
  carries no parseable reset time, the monitor takes the auto-return from the
  exhausted window's real reset instead of guessing 5 hours. Passive data —
  only as fresh as the last rendered statusline.
- **Two desktop shortcuts: the deterministic manual switch.** `install.ps1`
  now creates "Claude - Subscription" and "Claude - Bedrock" on the Desktop
  (`-NoShortcuts` to skip, `-ShortcutDir` to redirect). Each opens a console,
  performs the switch, shows the resulting status, and waits for Enter — two
  explicit icons rather than a toggle, so what a click does never depends on
  state. Backed by a new `-Pause` flag on `claude-switch`, which also holds
  the window open on a refused switch. The uninstaller removes only shortcuts
  whose target points into its own bin dir.

## 1.1.3 — 2026-08-24 (evening)

1.1.2 shipped two wrong assumptions, and one evening of real use surfaced
both — this time by fighting the user instead of failing them.

### Fixed

- **Drift is adopted, never reverted.** 1.1.2 made the monitor reassert
  `state.json` over `settings.json`; within hours it had reverted the user's
  own hand-switch to Bedrock four times in forty minutes, each time landing
  them back on a subscription that was out of monthly credits. `settings.json`
  is the file Claude Code actually reads — a hand edit to it is the user
  exercising the same right `claude-switch` does, and a scheduled task does
  not outrank the human. The monitor now updates its own state to match the
  file (an adopted switch has manual semantics: no auto-return; a hand return
  to subscription clears any pending timer) and runs the static guard over the
  adopted env block, logging everything wrong with it. The 2026-08-21 shape is
  handled by that visibility, not by undoing the edit.
- **The guard judged model ids against the wrong region.** 1.1.2 assumed a
  region persisted in the user environment beats the declared one at runtime.
  Production proved the opposite: a value written into the settings `env`
  block reaches Claude Code's processes ahead of the machine environment — a
  session declaring `us-east-1` ran fine on a machine whose persisted region
  is `eu-west-1`, while the guard, run from a shell that had inherited a stale
  region, refused that same live-verified config. Ids are now judged against
  the declared `AWS_REGION` when there is one; only an env block with no
  region falls back to the environment (process, then user registry, then
  machine registry) — which is the actual 2026-08-21 gap: `us.*` ids with no
  declared region on a machine that supplies `eu-west-1`.
- **The monthly spend cap is now a recognized limit error.** Detection matched
  `usage limit` and the epoch-carrying `limit reached|…` form; the org-level
  "You've hit your org's monthly spend limit" wording matches neither, so
  fourteen of them in one evening produced zero failovers. It now triggers the
  flip, and since a spend cap resets on a billing day this tool cannot know,
  the auto-return is a daily retry of the subscription — worst case one failed
  call a day, which flips straight back.

## 1.1.2 — 2026-08-24

Three days of broken auto mode, from a config nothing had ever verified.

A hand edit on 2026-08-21 21:25 put `us.anthropic.*` model ids in front of a
profile whose effective region was `eu-west-1`. A Bedrock inference profile is
geography-scoped, so every call answered `400 The provided model identifier is
invalid` — and nothing looked broken, because the desktop app's main loop
authenticates against Anthropic directly and never touched Bedrock. What did go
through Bedrock was auto mode's permission classifier, a separate Haiku-class
call that fails closed when it cannot reach a model: from 21:54 that evening
until this release, every tool call in auto mode was denied with an empty
reason. The subscription/Bedrock switch itself worked correctly throughout.

Nothing here is a new failure mode. Each item closes a way the tool could route
someone to a destination it had never confirmed could answer.

### Added

- **`claude-switch check`** — one 1-token `converse` call per model in
  `bedrockEnv`, so a mistyped profile, a region that lacks these models, or a
  missing access grant fails when you run the check rather than at the moment
  the subscription limit hits. Covered by offline smoke tests using a fake
  `aws` shim.
- **A static config guard, run on every switch to Bedrock.** It rejects a
  geography mismatch (`us.*` ids against an `eu-*` region and the rest) and a
  `bedrockEnv` with no model ids at all; `Set-ClaudeBackend` refuses to switch
  rather than flip onto a backend that 400s every call. Crucially it judges the
  ids against the region that will *actually* apply: a region persisted in the
  user environment (`setx` / `HKCU:\Environment`) is present in every process
  Claude Code starts and overrides the env block written into `settings.json`,
  so the region named in `config.json` can be completely inert. Checking
  self-consistency alone would have passed the exact config that caused this
  outage. A missing Haiku id is reported as a warning, not a fatal — it breaks
  auto mode but not the main loop, and stranding someone on a rate-limited
  subscription is the worse outcome.
- `claude-switch status` now has a **`bedrock config`** line, so an unusable or
  warning-carrying failover destination is visible before it is needed instead
  of only in the log of a switch that refused to happen.
- `claude-switch check` runs the static pass first, before it needs the `aws`
  CLI at all: the live call reports the symptom, the static pass names the cause.
- Install and rollout docs include the check as a standard step.

### Fixed

- **The monitor now reconciles drift between `state.json` and `settings.json`.**
  If anything outside the tool changed the backend — a hand edit, a restored
  settings backup, a half-finished switch — the monitor took `state.json` at
  face value and, when it said `bedrock`, returned early without ever looking at
  `settings.json`. That is exactly the shape of the 2026-08-21 outage, and the
  monitor ran 800-odd times through it without noticing. Reconciliation happens
  before that early return, and preserves any pending auto-return time so a
  repair does not cancel the flip back to subscription.
- **The monitor stopped advancing file offsets once it had found a hit.** Byte
  offsets were only recorded on scans that found nothing, so after a detection
  every subsequent run re-read the same tail of every transcript that had grown
  since — and the scan now stops at the first hit instead of reading the
  remaining files for a decision already made.

### Changed

- `config.example.json` and a fresh `install.ps1` seed now use
  **`global.anthropic.*`** model ids. A `global.` inference profile resolves in
  every region, so a shipped default cannot contradict whichever region ends up
  applying — the failure class above becomes structurally impossible to
  reintroduce from a default. All four ids were verified `ACTIVE` and invocable
  on 2026-08-24; `claude-switch check` re-verifies per account, since access
  grants are per-account and nothing here can assume yours.
- **`install.ps1` resolves the region instead of hardcoding one.** It prefers
  `-Region`, then a region already set in the environment, then the `region` of
  the named profile in `~/.aws/config`, and only falls back to `us-east-1` when
  nothing on the machine says otherwise.

## 1.1.1 — 2026-08-05

Two live misfires found by reading the switch log on a machine that had been
running for four days.

### Fixed

- **The monitor triggered on its own log output.** Detection substring-matched
  raw transcript lines, so *any* line quoting a past limit error counted —
  including the output of `claude-switch log`, which Claude Code records back
  into the transcript as a tool result. On 2026-08-04 that flipped a machine to
  Bedrock for seven hours off a diagnostic command. Detection now parses each
  line and requires a genuine assistant record flagged as an API error; a tool
  result is a user-role record and is rejected whatever text it carries. The
  log also writes the marker broken up, as a second line of defence.
  Regression tests cover the echoed-log line, ordinary chat quoting the marker,
  and the real error nested in `message.content[]`.
- **Overlapping monitor runs.** Task Scheduler ran several instances at once —
  four performed and logged the same flip within one second after the machine
  woke, and earlier overlaps died fighting over `state.json`. The task is now
  registered `-MultipleInstances IgnoreNew` and the monitor takes a named mutex,
  so a second run exits immediately.
- **Writes now survive a briefly locked file.** `Write-JsonFile` uses a
  per-process temp name and retries with backoff; on-access virus scanning was
  aborting whole monitor runs (`state.json.tmp ... used by another process`).
- **Transcript lines with a UTF-8 BOM are parsed correctly.** The first line of
  a transcript carries one, which raw matching ignored but JSON parsing rejects.

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
