# Native directory file exchange

Connection managers open **File exchange** from People connections. Choose an
accessible platform company, enable file exchange and the directory JSON format,
and set byte and record limits. Only enabled co-located native connections with
a current Workforce mapping are accepted. Remote and vendor formats are refused.

Export captures the current synchronised company, employee and position directory. Run
**Synchronise now** first when the directory is stale or unavailable. Import
validates and privately retains a directory file for review; it does not update
live projections, advance a checkpoint, restore a connection or change People
business history. Download the imported file from the recent exchange history.
This is file exchange, not backup/recovery or a provider write port.

The immutable format is `people-directory-v1`. The JSON object has exactly
`format`, `tenant_id`, `platform_company_id`, `workforce_source_id`,
`workforce_company_id`, and `records`. Platform company identifies Core Company;
workforce company and source identify the separate People Workforce mapping.
Each record has exactly the WorkforceRecord fields, with `kind` as `company`,
`employee` or `position` and `observed_at` as an ISO-8601 instant. Position records
also carry `parent_stable_id`, `version`, `vacant`, `assignments_incomplete`
and at most 500 `assignments`, each with exactly `source_id`, `stable_id`,
`employee_stable_id` and `kind`. Source and workforce company
must match the selected connection. Duplicate kind/stable-ID pairs, invalid
record fields, extra envelope/record fields and unsupported formats are refused.
No names, filenames or document contents enter exchange audit payloads.

Company settings (all editable on the file page):

| Key | Initial policy |
| --- | --- |
| `people-connector.files.enabled` | Disabled |
| `people-connector.files.json_enabled` | Directory JSON permitted when exchange is enabled |
| `people-connector.files.max_bytes` | 1 MiB, bounded to 10 MiB |
| `people-connector.files.max_records` | 1000, bounded to 100000 |
| `people-connector.files.stale_minutes` | 15, bounded to 1440 |

Base Artifacts also applies its installation byte limit. Configure its private
storage root and required retention days through **Operator Settings**, using
`admin.system.artifacts.manage`. The file page links there; the file manager
capability does not grant installation settings access. No unbounded retention
is allowed. Base captures expiry at creation, refuses expired reads immediately,
and records every private byte read/deletion. **Remove expired files** confirms
before running a bounded company/owner retention batch. Any purge error is shown
as a refusal; held/retry recovery remains with the Base retention contract.

Receipts have tenant/platform company, original workforce mapping, connection,
direction, content digest, count, status and opaque artifact ID. No document bytes
or storage paths are duplicated in Connector tables. Artifacts authorization
rechecks live company reach, original connection ID and connection mapping on every creation/read. Company
managers may purge owned expired bytes even after disconnect/remapping; they
cannot download the previous mapping's files. Connection removal leaves receipts
and Base's retention lifecycle in place, with an empty connection reference. Recreating a connection does not reopen its predecessor’s files.

SHA-256 of exact bytes plus connection and direction is the replay key.
While the recorded artifact is unexpired, identical re-import/export returns
that receipt without extending retention or creating another artifact. Once it
has expired (or been purged), the same bytes create a new receipt and artifact
with fresh retention; the expired receipt stays in history marked **Expired**,
without a download link. Semantically equivalent JSON with different bytes is a
different file. Failed storage/publication can retry the same receipt. A pending
operation refuses a concurrent retry. A pending receipt not updated within the
company's stale timeout is treated as abandoned: the next exchange of the same
bytes marks it failed with reason `stale`, audits
`people-connector.files.stale`, and proceeds with a new receipt. The history
shows in-progress receipts as **In progress** and abandoned ones as
**Abandoned**; a late publication of an abandoned receipt is refused and its
bytes are deleted. Interrupted or unpublished artifact bytes remain tracked by
Base's reservation/tombstone retention, never by an untracked filesystem copy.

The owner adapter is selected by server code. Downloads authenticate through the
host, require connection management, and return an attachment with private/no-store
and nosniff headers. Failed access reveals no bytes. Module action audit records
signed-in actor and company with receipt/artifact IDs and counts only. New receipt
schema is Bilimbi-only; there is no legacy import/adoption path.

Receipt retention is separate from private byte expiry. See
[Health and retention](operations.md) for company periods and audited receipt
purges after Base confirms expired byte cleanup.
