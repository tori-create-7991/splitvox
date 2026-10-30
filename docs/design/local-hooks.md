# Command-only local hooks

Status: approved design, implementation pending merge. Date: 2026-10-30.

## Context and scope

Integrations use external local commands. The menu-bar app has no Notion-specific
settings, preset, candidate picker or direct export coordinator. The existing
headless Notion exporter remains available to scripts, including its journals,
locks, reconciliation and explicit target selection. No dependency is added.

## Contract and structure

Each version-1 entry has a stable UUID, name, enabled flag, event, command and
finite timeout in the range 1–3600 seconds (default 15). Settings allow multiple
entries, additions and deletion. Webhooks have separate start/completion URLs.

Recording start fires after capture actually starts. Completion fires once on the
common success path for live or file transcription, only after usable transcript
text is written. Errors and empty transcription do not emit completion.

Commands execute via `/bin/zsh -lc`, with closed stdin and stdout/stderr discarded.
Four workers bound process concurrency; pending commands wait for a worker.
Timeout begins when a command launches. Webhooks start independently through
URLSession with a 15-second request timeout. Failed integrations do not stop capture.
Each process owns a group; timeout and normal shell exit terminate remaining group
members. The headless compatibility exporter verifies an internal process-group
marker and keeps its API processes in that same group. Its own API timeout hard
stops the verified group, preserving the journal and lock for explicit recovery.
Standalone CLI requests retain their own groups. Scripts must keep their work in that group, rather than daemonize it.

The existing external event values are `recording_started` and `recording_stopped`.
The environment remains `SPLITVOX_HOOK_EVENT`, `SPLITVOX_SESSION_DIRECTORY`,
`SPLITVOX_RECORDING_STARTED_AT`, `SPLITVOX_HOOK_OCCURRED_AT`. Webhook JSON retains
`event`, `sessionDirectory`, `recordingStartedAt`, `occurredAt`. Dates are ISO 8601.
Session paths enter shell commands through quoted environment expansions.

Jobs capture their source directory before dispatch. Generic `session.log` records
UUID, event, lifecycle status and exit code; it never copies arbitrary command
output, user-entered names, command source, URL tokens or transcript contents.
Commands needing diagnostics should write their own appropriately protected files.

## Migration and rollback boundary

When no versioned document exists, legacy start/completion commands become generic
entries with 15-second timeouts. A stored legacy Notion configuration becomes an
ordinary completion command invoking the current app executable with
`--notion-sync`, `--write`, `--started-at`, `--ntn`, `--parent-page` and
`--window-minutes`. All constant arguments are shell-quoted; session values are
quoted environment references. Its enabled state and parameters are preserved,
with an editable 600-second timeout. Disabled legacy export is never enabled.
Both Webhook URLs remain intact.

The migration persists even an empty list. Existing versioned settings are
authoritative: saving, deletion and explicit empty lists never re-import old
entries. Unknown/malformed documents fail closed with an actionable settings
error; they are not overwritten by opening or saving unrelated settings. Repair
the `localHooksConfiguration` preference with a compatible app or restore its
known-good backup, then reload Settings. Webhooks remain independently available.
Legacy preferences remain for CLI compatibility and an eventual app rollback;
their enabled flag never drives a second automatic export. New hook edits do not
back-propagate to the old preferences. If moving the app, update migrated commands
that refer to its old executable path. Do not clear journals or locks to retry
uncertain external writes.

## Headless ambiguity and recovery

When several Notion notes match, export fails before any API mutation. Run a
dry-run, inspect candidates and explicitly supply `--note <ID>`. There is no
app picker. Journal target binding and uncertain-write checks still apply.
`--notion-status` labels retained configuration as legacy CLI parameters, rather
than representing native automatic export. This change removes interactive
selection from normal operation and is documented in the migration instructions.

## Decisions

| Decision | Reason | Rejected alternative |
|---|---|---|
| Generic command-only settings | Integrations are extensible through user scripts | Notion preset or service-kind discriminator |
| External headless compatibility | Retain existing exporter and reconciliation | Delete exporter or keep a second native send path |
| Versioned stable identities | Durable deletions, migration once, private correlation | Recreate legacy commands on every load |
| Configurable generic timeout | Exports can take longer than 15 seconds | Notion-specific timeout behavior |
| Independent bounded jobs and Webhooks | Slow/failing work cannot block capture or unrelated sends | One serial combined command/Webhook runner |
| Explicit CLI target when ambiguous | Avoid guessed writes while retaining journal safety | Guess nearest note or retain app picker |

## Verification and limits

Isolated defaults, temporary scripts/transcripts and fake API/transport tests
cover migration, quoting, routing, process groups and exporter recovery.
`swift test` and `swift build -c release` are the required verification commands.
Rendered UI, installation and real integrations require separate observation.
No live hooks, existing recordings or external exports are exercised by tests.

## 後続の変更

None.

## 後続の変更（独立CLI、2026-10-30）

[ADR 0002](../adr/0002-external-notion-cli.md) moves the exporter out of the app.
The runtime, migration and rollout contract is now
[external-notion-cli](external-notion-cli.md). The historical app-owned headless
entry and migration above describe the superseded implementation.
