# Notion database destination

## Decision table
| Decision | Reason | Alternatives |
|---|---|---|
| Add explicit --data-source UUID and --date-property name to standalone CLI | Correct Notion parent is a data source; select target without app coupling | --parent-page DB UUID is invalid for a database row; moving pages after creation makes recovery harder |
| Validate schema and discover the unique title column; require the configured date column to be date | Respect existing Meeting name / Start Date schema without hardcoding private IDs | Creating a new DB would scatter existing notes |
| Query only this data source by recording time ± configured window; paginate fully | Preserve candidate matching within the requested destination | Workspace-wide matching can append outside target |
| Validate explicit note/bound page membership before writing | --note or old journal must not escape destination | Silent redirect or fallback risks wrong writes |
| Bind new journal to normalized destination; reconcile creation markers within target | Preserve uncertain-write and completed-retry guarantees | Clearing journals or retrying blind can duplicate |
| Keep legacy unbound uncertain journals on original global recovery first | An older creation may already exist outside DB | Switching recovery scope can hide a prior write |
| Update only known live hook arguments after CLI install, with private backup while app is idle/stopped | Preserve enabled/timeout/identity/unknown fields and avoid app-preference race | Adding app Notion settings would reverse separation |

## Structure
NotionCommand parses explicit args. NotionDataSource owns schema/query/page properties/membership. NotionMeetingNotes retains journal/lock/native Notes mutation pipeline and uses the helper only for DB mode. Legacy no-DB mode remains supported. No API mutation begins until schema/payload validation succeeds. Completed journals continue to return already-sent without redirects. New native block uses explicit Markdown v2; do not autoapply the DB template.

## Compatibility and rollout

Without --data-source, workspace/page mode remains supported. Completed journals never resend. Unfinished bound exports cannot silently change destinations; legacy uncertain creations use their original recovery search before membership validation.

Install the independent CLI and set the generic hook arguments to the chosen data-source UUID and date property. No schema changes or historical page moves are needed. Keep a private copy of the old executable and hook document for rollback; retain export journals.

## References

- [Query a data source](https://developers.notion.com/reference/query-a-data-source)
- [Retrieve a data source](https://developers.notion.com/reference/retrieve-a-data-source)

## 後続の変更

None.
