# Independent Notion command

Status: approved design; implementation pending merge. Date: 2026-10-30.

## Context and scope

The app records/transcribes, emits metadata and executes generic local commands.
Notion export lives in a separate Swift package and executable under
`Tools/notion-exporter`. It does not import the app, AppKit or KeyboardShortcuts,
and can be built with no app package dependency. Normal execution does not read
host preferences. [ADR 0002](../adr/0002-external-notion-cli.md) records the boundary.

## Runtime contract

`splitvox-notion` retains the export arguments `--notion-sync`, `--write`,
`--started-at`, `--ntn`, `--parent-page`, `--window-minutes` and `--note`.
Status describes explicit CLI parameters, rather than app automatic-send state.
Missing ntn is an actionable CLI error. Authentication remains in ntn's Keychain;
ambient NOTION_API_TOKEN is removed, stdin is closed, and arbitrary process output
is not copied into error messages. The exporter owns its append-only session log.

The app removes its old Notion CLI route, configuration access and conversion.
It retains generic hook settings, legacy plain-command import, event metadata,
Webhooks and process execution. Unknown double-dash arguments fail before starting
the accessory app. Existing service names used as audio-exclusion examples are
unrelated and remain.

Journals/locks, digest and target binding, uncertain-write reconciliation,
pagination, explicit ambiguity recovery and chunking keep their existing formats
and behavior. Normal standalone API processes have owned groups. A verified
optional host-group marker retains API children inside a local hook's lifetime;
managed timeout stops that group and preserves uncertainty evidence.

## Explicit external migration

Only `--migrate-local-hooks` reads/writes host preferences. It imports legacy
settings when no versioned document exists, or replaces an exactly recognized
old executable invocation in a version-1 document. Existing explicit empty lists
remain empty. Repeated migration is a no-op. UUIDs, name/event/enabled/timeout,
remaining command bytes, Webhook URLs, other preferences and unknown JSON fields
are preserved. Legacy preferences are not deleted or updated.

Malformed/unknown versions and customized old app invocations stop migration.
No shell source is evaluated. CLI installation can succeed while migration stops;
do not install/start the new app until migration succeeds. Preference writes have
private backups and a pre-write consistency check. This check is not a general
cross-process transaction: stop the idle app and avoid concurrent settings edits
for cutover.

Install the independent CLI first, back up/stop the idle app, dry-run and apply
migration, then install the app. Refuse to replace a symlink destination; stage
and atomically replace regular CLI files, preserving a private backup. Keep the
old app/settings for rollback; do not clear journals/locks or blindly resend.

## Decisions

| Decision | Reason | Rejected alternative |
|---|---|---|
| Independent Swift package in same repo | Reuse tested exporter with build/runtime independence | Same app entry point, forwarding shim, Python rewrite, new repo |
| Explicit external migration | Preserve existing hooks without adding service knowledge to the app | Migration in PreferenceStore |
| Exact command recognition | Avoid altering user shell semantics | Evaluate shell or infer customized invocations |
| Keep journal and group contracts | Retain duplicate-send and timeout protection | Reset export state or allow child groups to escape |

## Verification

App tests/release build and CLI tests/release build run independently. A boundary
check rejects exporter symbols/endpoints in app sources and app/package/UI
imports in the exporter. Tests cover raw JSON preservation, empty/deleted state,
repeated import, quoting, backup/dry-run, old completed journals and owned process
groups using temporary fixtures/fake CLI only. No real recordings or new external
pages are needed. GUI inspection is separate.

## Not doing

No destination/database schema changes, new services, dependency upgrades,
recording changes, historical sends or automatic permission changes.

## 後続の変更

None.
