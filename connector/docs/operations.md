# Connection doctor and record retention

Connection managers open **Health and retention** from People connections at
`/integrations/people/operations`. Select a Core platform company; each run
checks that company's connection, including a broken workforce mapping. The
API requires a validated `Bilimbi.Base.Tenancy.Scope`, a signed-in actor with
`people-connector.connections.manage`, and live company reach. A system scope,
a view-only actor, a sibling company without company reach, and another tenant
are refused. Every event rechecks authority, including after a page is opened.

`Doctor.run(scope, platform_company_id)` checks configuration, installed provider
contract and adapter, credential presence (native needs none), last sync,
checkpoint freshness, timed-out passes, unsuccessful retained passes and open
reconciliation issues, webhook signing-secret presence and last receipt,
file-format/storage configuration, failed/abandoned exchanges and expired
receipts. Fixed actionable findings carry counts and timestamps, without
employee data, secret values, hashes or private paths. Checks are observations;
concurrent operations can change state while a check runs. It does not repair,
sync or send any transport. A Base Audit action records the check codes and
outcomes, actor and impersonator. Disabled intake/exchange is a valid state;
unsuccessful historical syncs remain visible until retained records are purged.

`Retention.policy/2`, `configure/3` and `purge/2` are company-scoped APIs.
Company Base Settings are edited inline on the operations page:

| Setting suffix under `people-connector.retention.` | Values | Initial value |
| --- | --- | --- |
| `sync_days` | 1–3650 days, or unset | Keep records |
| `webhook_days` | 1–3650 days, or unset | Keep records |
| `file_days` | 1–3650 days, or unset | Keep records |
| `batch_size` | 1–1000 rows per record type per call | 100 |
| `retry_minutes` | 1–1440 minutes | 60 |

The page confirms irreversible purges and shows removed/failed counts and
failed record IDs with recovery steps. Policies are validated together before
any setting changes. Settings changes and purge starts are audited. Each row
is separately locked, rechecked for current authority/eligibility, audited and
removed in its own transaction. A database/audit/byte cleanup failure retains
that row and allows the remaining rows to proceed. Failed IDs receive durable
retry holds, excluded from subsequent batches until the company retry delay
passes. Fix the cause and run another batch after that delay. Audit outages
can prevent recording a failure hold; the row still remains and other rows are
attempted. Purge results never expose exception text.

Eligibility is strictly older than the chosen period: sync uses `finished_at`
and preserves all running passes; webhook deliveries/nonces use `received_at`;
file receipts use `inserted_at`, preserve pending exchanges, and wait for the
stored artifact expiry. File receipts are removed only after Base Artifacts
confirms byte cleanup through its public API, outside the receipt transaction.
A failed cleanup keeps the receipt for access checks and retry, including after
connection removal. Byte cleanup and receipt removal are separate commits;
a receipt removal failure can leave a receipt referencing already-purged bytes.
Retrying is safe. Base's artifact tombstone and audit history remain.

Webhook nonces and delivery receipts are kept for at least twice the company's
current signing-skew allowance, even if a shorter retention period is chosen.
This covers a signed future timestamp accepted on initial receipt. Retention
bounds deduplication: a purged delivery ID or sync idempotency key can be treated
as a new request. Retain periods long enough for the installation's retry policy.
Checkpoint state survives run purges, so the next sync resumes normally.

This workflow never purges checkpoints, workforce projections, reconciliation
issues or Base audit history. It does not implement backup, recovery, remote
native transport, vendor transport, scheduling or People business-data cleanup.
The only new table is the module-owned Bilimbi-only retention retry record,
created by migration `20261002190001`; the same migration adds owned retention
indexes. Existing applied migration files remain unchanged.
