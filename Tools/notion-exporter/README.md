# splitvox-notion

Independent local Notion exporter. It builds/runs without the Splitvox app,
AppKit, KeyboardShortcuts or any Swift package dependency. Requires macOS 13+,
Swift 6.2+ to build, and authenticated `ntn` for real API operations.

```sh
swift test --package-path Tools/notion-exporter
swift build --package-path Tools/notion-exporter -c release
bash scripts/install-notion-hook.sh
```

The installed binary defaults to `~/.local/bin/splitvox-notion`. For a hook:

```sh
"$HOME/.local/bin/splitvox-notion" \
  --notion-sync "$SPLITVOX_SESSION_DIRECTORY" --write \
  --started-at "$SPLITVOX_RECORDING_STARTED_AT" --window-minutes 10
```

Omit `--write` for dry-run. Set `--ntn /absolute/path/to/ntn` if PATH discovery
cannot find the CLI. `--parent-page <UUID>` controls only the new-page parent;
empty means workspace root. It does not target a database. One matching note is
appended to, no candidate creates a native Meeting Note, and multiple candidates
stop until `--note <UUID>` is supplied. Text goes to Notes; no audio is sent.
Normal export/status reads explicit arguments and ntn authentication only.

## Migration

Stop the old app while idle before applying migration and before installing the
updated app. Old app `--notion-*` entry points no longer exist.

```sh
# Read-only preview; install the CLI first
"$HOME/.local/bin/splitvox-notion" --migrate-local-hooks \
  --new-executable "$HOME/.local/bin/splitvox-notion"

# Apply with a private preference backup, or use the installer --migrate
"$HOME/.local/bin/splitvox-notion" --migrate-local-hooks \
  --new-executable "$HOME/.local/bin/splitvox-notion" --write
```

Only the explicit migration command touches host preferences. It recognizes the
exact previously generated app command, preserves identity/enabled/timeout and
all arguments/unknown fields, and refuses customized old calls or malformed
schemas. Empty versioned lists stay empty; repeat migration is a no-op. Existing
legacy preferences remain for rollback. `--domain`, `--old-executable` and
`--backup-directory` support explicit alternative/isolated targets. Migration
executes no saved command and makes no API writes. The new app must not be
installed/started if migration reports a custom old invocation.

## Recovery

Existing `.notion-sync.json` and `.notion-sync.lock` formats are retained.
Completed export retries do not send again. Uncertain writes reconcile remote
state or stop; never clear journal/lock files to force a resend. Logs are appended
locally. API commands close stdin, remove ambient `NOTION_API_TOKEN` and suppress
raw error output. API children share a verified optional host group when used
from a hook; host or inner API timeout preserves uncertainty evidence.

For rollback, quit the app and restore its private backup plus only the changed
hook document as needed. Keep the standalone CLI and export journals available.
