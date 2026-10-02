# Connector

`people_connector/connector` owns integration contracts, company
connections, and directory synchronisation into Connector-owned projections.
It requires the mounted `people/workforce` public module.

`Capability`, `Provider`, and `Registry` describe provider-declared read and
write ports. Duplicate or invalid declarations are refused. A provider also
declares whether a connection needs a credential (`:none` or `:secret`).
`Providers.installed/0` is the catalog operators choose from: only the
co-located native People provider (`people.native`), which reads through
People Workforce, declares company, employee and organisation directory reads, and needs no
credential. Remote and third-party providers are not offered.

## Company axes

Every call takes a validated `Bilimbi.Base.Tenancy.Scope` and an explicit
platform company ID: a live Core Company in that tenant. People Workforce
validates that company and returns the separate workforce company identity
(`workforce_source_id` plus `workforce_company_id`). Stale or unavailable
Workforce identity is refused as `{:not_current, freshness}`, never used as a
mapping. A stored connection records both axes. When Workforce later maps the
platform company differently, `status/2` refuses with `:mapping_changed` until
an operator chooses the provider again, which records the current mapping and
leaves the connection disabled. A login actor is never a company or employee
identity.

## Storage

The module owns fresh Bilimbi-only tables. `people_connector_connections`
(migration `20261002070001`) holds connections: a platform company has at most
one, and one workforce company identity backs at most one platform company in
a tenant; the database enforces both. Migration `20261002070002` adds the
synchronisation tables, each cascading from its connection:
`people_connector_sync_checkpoints` (one per connection),
`people_connector_sync_runs` (unique idempotency key per connection, at most
one `running` row), `people_connector_workforce_records` (one row per
connection, kind, provider source and stable ID) and
`people_connector_reconciliation_issues` (unique issue key per connection).
Both migrations are `:bilimbi_only`. No Belimbing table or data is adopted or
imported.

A provider credential is the encrypted company-scoped Base Setting
`people-connector.connection.credential`. It is not editable on the generic
settings screen and has no reveal path. The facade stores or clears it and
reports only whether one exists; changing provider or removing the connection
deletes it. Enabling a connection whose provider declares `:secret` needs a
stored credential. Every table and settings write is recorded by Base Audit.

## API and authorization

`status/2` needs only the scope. `configure_connection/4`, `put_credential/4`,
`clear_credential/3`, `set_enabled/4`, and `remove_connection/2` need the
scope's signed-in actor to hold `people-connector.connections.manage` with
Core Company reach to the target: the actor's own company, or a same-tenant
sibling only with tenant-wide company reach. System work is refused.

`synchronise/6`, `resolve_issue/3` and `put_sync_policy/3` need the same
manage capability and reach. `sync_summary/2` and `workforce/2` follow People
Workforce's read policy by delegating to `Workforce.company/2`: a company the
scope's tenant cannot see, or one Workforce does not report as live and
current, is refused before any synchronised record is read.

`request_port/6` refuses an undeclared capability or direction with
`:unsupported`, a declared port without an enabled connection to that
provider with `:disconnected`, and an enabled one with `:adapter_unavailable`:
it never hands out an adapter, and reads are served only by `synchronise/6`.
The write port behaviour is a neutral placeholder; no writer is activated.

## Synchronisation

An adapter implements `ReadPort.read/2`. It receives a `PortAuthorization`
that only the Connector builds (both company axes, provider, capability) and a
`PortRequest` (`:bootstrap` or `:changes`, the resume cursor, the page cursor
and the page limit), and returns a `Page` of `WorkforceRecord` values (including positions with bounded `AssignmentRecord`
holders) plus, on
a changes pass, `Deactivation` values. `Adapters.installed/0` maps provider
IDs to adapter modules. A mounted adapter module (the Connector cannot depend
on it) calls `Adapters.register/2` when its application starts and
`Adapters.unregister/2` when it stops; without one, every pass is refused with
`:adapter_unavailable`. `people_connector/native_people_adapter` registers the
native provider. Callers pass the adapter map explicitly, as they pass the
provider registry.

`synchronise/6` needs an enabled connection whose provider declares
`employee_directory` reads, and a caller-chosen idempotency key (1-100
letters, digits, `.`, `_`, `:` or `-`). The same key returns the recorded
`SyncRun` without reading the provider. A second pass while one is running is
refused with `:sync_in_progress`. The first pass is a bootstrap; later passes
read changes after the checkpoint's resume cursor. `full: true` bootstraps
again and deactivates records the provider no longer lists. A provider without
a change feed marks each page `snapshot: true`; when every page of a pass is a
snapshot, a changes pass also deactivates records it no longer lists.

The engine reads every page of each declared stream before applying any.
The organisation stream is authorized separately as `organization_directory`.
A stale or failed stream prevents the entire pass from being applied. An
unavailable organisation stream does not: the directory stream is applied,
positions are left as they were, and an `organisation_unavailable` warning
issue stays open until a later pass reads the organisation stream. Absent
positions are deactivated only when the organisation stream arrived in a
single page, because the native seam pages by offset and a multi-page read
can skip a live position; until keyset paging exists, a multi-page pass leaves
an ended position active. Position identity
includes kind, source and stable ID. Parent, version, vacancy, assignment
completeness and holder identities are projected without writing People history.
Migration `20261003120001` adds those projection fields.

The engine reads every page before applying any. A stale or unavailable page
(Workforce freshness vocabulary), an adapter error or exception, a repeated
page cursor, or a page over the limit or of the wrong shape ends the run
`:stale`, `:unavailable` or `:failed` with nothing applied. Otherwise, in one
transaction, it applies the pages and moves the checkpoint to the oldest page
watermark, provided the run is still running, the connection is unchanged and
the checkpoint has not moved. A pass that has not finished within the
company's run timeout is marked `:unknown` by the next request, with an
`unknown_outcome` issue; its late result is discarded. Reasons are fixed
codes; adapter text is never stored.

A provider cannot overwrite People business history. Synchronisation writes
only Connector tables and holds directory facts only. A record from another
source, for another workforce company, of an undeclared kind or malformed is
refused as a `record_refused` issue and the pass continues; a refused record
that names its identity counts as listed, so a full read does not deactivate
it. If every record is refused the checkpoint stays put, nothing is
deactivated and a `feed_refused` issue opens. An older observation never
replaces a newer one, a repeated one writes nothing, and a
deactivation keeps the row inactive rather than deleting it. Changing provider
or workforce mapping deletes the projection and checkpoint so the next pass
bootstraps; removing the connection deletes all of its synchronisation rows.
Base Audit captures every table write.

`workforce/2` returns active records as a People Workforce `ReadResult`:
`:current`, `{:stale, as_of}` once the checkpoint is older than the company's
maximum age, or `{:unavailable, :never_synchronised | :disconnected}`.

Company-scoped Base Settings hold the policy, edited on the connections page:
`people-connector.sync.page_limit` (1-1000, default 250),
`people-connector.sync.max_age_minutes` (5-43200, default 1440) and
`people-connector.sync.run_timeout_minutes` (1-1440, default 30).

## Page

`/integrations/people/connections` requires `people-connector.connections.view`
and lists only companies the actor can reach. It shows the connection state,
provider, both company axes and whether a credential is stored. With the manage
capability it offers provider choice, a masked credential field for providers
that declare one, enable/disable, and removal behind a confirmation. For a
configured connection it shows freshness, the checkpoint watermark, the last
pass and open issues. Managers also get **Synchronise now** and **Full read**
(each carrying a page-minted idempotency key), **Mark resolved** per issue, and
the policy form. The menu
leaf **Administration › System › Integrations › People connections** carries
the view capability; the route enforces it again.

## Inbound notifications

The connection page configures encrypted native webhook signing settings and
shows the last accepted directory-change notification. See
[native inbound notifications](webhooks.md) for the exact signature, replay,
retry and audit contract. Receipt intake does not activate remote transport or
run synchronisation as a machine sender.

Native directory snapshots can be exchanged privately for operator review; see
[file exchange](files.md) for format, settings, replay and retention rules.

Operator-run [connection health and record retention](operations.md) diagnose
connection failures and purge only eligible operational history with audited
per-row retries. Retention periods default to keeping records.

Operator backup and recovery uses private Base Artifacts and an actor-bound,
confirmed restore; see [backup and recovery](backups.md).
