# 0002. Notion export is an independent executable

Status: Accepted

## Context

Generic local hooks initially invoked the app's headless Notion exporter. The
settings were generic, but exporting still required the Splitvox executable and
its application package. This did not provide runtime independence.

## Decision

Move Notion matching, API transport, export/reconciliation and logging into the
separate Swift package `Tools/notion-exporter`, installed as `splitvox-notion`.
The app has no dependency on that package and no service-specific entry point,
configuration access or migration. Unknown CLI options fail before app startup.

Normal exporter execution reads explicit arguments and ntn authentication only.
An explicit migration subcommand in the external tool owns the one-time import
of legacy host settings and recognized old commands. Preserve IDs, enablement,
arguments, unknown fields and journal/lock compatibility. Refuse uncertain custom
calls rather than evaluating or guessing shell source.

## Consequences

The app and exporter build and run independently. Users install the external
command separately and may replace it with any other hook command. Old app
`--notion-*` invocations must be migrated before the updated app is started.
The installer does not silently change the Notion destination or resend data.

This supersedes the app-owned headless compatibility decision in the original
[local-hooks design](../design/local-hooks.md). The coordinated extraction and
rollout contract is in [external-notion-cli](../design/external-notion-cli.md).
