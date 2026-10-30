#!/bin/bash
set -euo pipefail
# Resolve with shell builtins so a missing search tool cannot corrupt cwd.
script_dir="${BASH_SOURCE[0]%/*}"
cd "$script_dir/.."
command -v rg >/dev/null 2>&1 || { echo "FAIL: rg is required" >&2; exit 1; }
[ -f Sources/Splitvox/main.swift ] && [ -f Package.swift ] \
    && [ -f Tools/notion-exporter/Package.swift ] && [ -d Tools/notion-exporter/Sources ] \
    || { echo "FAIL: expected source paths are unavailable" >&2; exit 1; }
assert_absent() {
    local status
    if rg --no-ignore -n "$@"; then
        echo "FAIL: forbidden boundary dependency found" >&2
        return 1
    else
        status=$?
        [ "$status" -eq 1 ] || { echo "FAIL: search failed (exit $status)" >&2; return 1; }
    fi
}
pattern='NotionDataSource|NotionCommand|NotionMeetingNotes|NotionCLI|NotionConfiguration|notionConfiguration|--notion-sync|--notion-status|/v1/blocks/meeting_notes'
assert_absent "$pattern" Sources/Splitvox
assert_absent 'notion-exporter|SplitvoxNotion' Package.swift
assert_absent 'import (AppKit|Splitvox|KeyboardShortcuts)|package\(url:' Tools/notion-exporter/Package.swift Tools/notion-exporter/Sources
echo "PASS: app and exporter are independent"
