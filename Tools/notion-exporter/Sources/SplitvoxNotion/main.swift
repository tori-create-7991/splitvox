import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") {
    print("""
    splitvox-notion --notion-sync <session directory> [--write] [--started-at <ISO8601>]
        [--ntn <absolute path>] [--parent-page <UUID>] [--window-minutes <1..120>] [--note <UUID>]
        [--data-source <UUID>] [--date-property <name, default: Start Date>]
    splitvox-notion --notion-status [--ntn <absolute path>] [--parent-page <UUID>]
    splitvox-notion --migrate-local-hooks [--write] [--domain <preferences domain>]
        [--old-executable <absolute app executable>] --new-executable <absolute CLI>
        [--backup-directory <private directory>]

    --data-source targets database rows; cannot combine with a nonempty --parent-page.
    Export is dry-run unless --write is given. Normal export uses only arguments
    and ntn authentication, never app preferences. Migration is explicit and
    backs up preferences before changing recognized hooks. Custom old calls stop
    migration; no commands or API writes are executed by migration.
    """)
    exit(0)
}
if arguments.contains("--migrate-local-hooks") {
    do { try HookMigration.run(arguments); exit(0) }
    catch { fputs("Migration: \(error.localizedDescription)\n", stderr); exit(1) }
}
exit(NotionCommand.run(arguments))
