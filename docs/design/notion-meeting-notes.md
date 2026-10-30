# Local Notion CLI integration

Splitvox exports a completed transcript into the Notes section of a native Notion Meeting Note when the user enables the integration. The local `ntn` CLI owns OAuth credentials in Keychain. Audio files remain local. Both live and file-based transcription success paths dispatch the same background export; failed transcription does not export.

## Decision table

| Decision | Reason | Alternative considered |
|---|---|---|
| Native coordinator, modeless candidate picker, local CLI | Preserves native choice UI and saved OAuth login | A shell hook alone cannot provide coordinated application UI |
| Separate integration from generic hooks | Generic hooks time out after 15 seconds | Raising timeouts for every existing hook |
| Markdown v2 creates a page containing a native Meeting Note | Verified without media upload | Dedicated meeting-note creation API requires audio/video |
| Append plain-text paragraphs inside one session toggle | Literal tags cannot inject blocks; existing agenda survives | Replacing page Markdown could erase existing material |
| Private request files, closed stdin, isolated process groups, sanitized errors | Prevents inherited token override, stdin hangs, pipe deadlocks and secret logging | Piping unbounded output and inheriting stdin |
| Local journal before writes, remote reconciliation | A timeout may have committed | Blindly retrying non-idempotent writes |

## Behavior and configuration

Default is disabled. Settings store the CLI path (automatic login-shell lookup when blank), optional parent page UUID (workspace root when blank), and start-time tolerance (default ±10 minutes). The Notes section is writable; Transcript injection and Notion AI summary generation are outside this feature.

Candidate search covers notes created from 30 days before through the day after recording start, accounting for calendar/recording start metadata before falling back to creation time. Notes prepared before this range are not automatically discovered; use an explicit note ID in the CLI. A saturated query is subdivided into disjoint date ranges; if one day still returns 50 results, it fails closed rather than inferring a missing note. Results inside the configured time tolerance: zero creates a native Meeting Note; one appends; multiple ask in a modeless app picker showing the source recording and carrying note IDs independently of duplicate titles. Concurrent jobs are counted separately in status. Cancellation sends nothing.

## Journal and recovery

Each recording directory contains `.notion-sync.json` and an exclusive `.notion-sync.lock` during export. The journal binds an immutable transcript digest, recording date, random session UUID, selected note, and pending batch count. Creation titles and session toggles contain the stable session UUID. Content is split at Unicode scalar boundaries within 1800 UTF-16 units and appended in batches of at most 50 paragraphs.

After an uncertain create, the service searches for the exact session UUID. After an uncertain container/batch append, it reads the Notes children and validates the expected prefix. It resumes only when the remote result proves success. No remote match after an uncertain write stops export; it does not prove the server rejected it. Inspect Notion and the journal before recovering manually. A leftover lock after app termination must only be removed after verifying no exporter is active. Definite CLI API rejections (validated HTTP 400/401/403/404/413/422/429 status prefix) restore retryable journal state; unknown failures remain conservative. There is no automatic destructive reset or journal deletion.

## Verification

Unit tests cover candidate selection, saturated searches, Unicode chunks, preserved agenda, literal transcript tags, process timeout/stdin/environment behavior, committed and uncertain request recovery, repeated exports and changed transcripts. Headless `--notion-sync` uses the same service as the app; it is read-only unless `--write` is explicit. Synthetic live verification creates content only under the implementation task. UI presentation is code-reviewed; no GUI automation is claimed.

## Not Doing

Audio upload, Transcript-tab injection, automatic AI summary, generic hook replacement, automatic export enablement, and historical bulk backfill.

## Sources

- https://developers.notion.com/guides/data-apis/notion-flavored-markdown
- https://developers.notion.com/guides/data-apis/working-with-markdown-content

Markdown v2 is an opt-in preview. A future API change must fail with a visible local error rather than fall back to silently creating ordinary text blocks.

## Subsequent changes

None.

## 後続の変更（2026-10-30）

[Command-only local hooks](local-hooks.md) replaces the native Notion settings,
candidate picker and automatic coordinator with generic external commands.
Headless export and journal reconciliation remain; ambiguous candidates require
dry-run inspection and explicit `--note`. The historical decisions above describe
the original implementation.
