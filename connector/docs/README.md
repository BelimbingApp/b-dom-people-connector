# Connector

`people_connector/connector` owns integration contracts and company
connections. It requires the mounted `people/workforce` public module.

`Capability`, `Provider`, and `Registry` describe provider-declared read and
write ports. Duplicate or invalid declarations are refused. A provider also
declares whether a connection needs a credential (`:none` or `:secret`).
`Providers.installed/0` is the catalog operators choose from: only the
co-located native People provider (`people.native`), which reads through
People Workforce, declares company and employee directory reads, and needs no
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

The module owns one fresh Bilimbi-only table, `people_connector_connections`
(migration `20260930200101`, `:bilimbi_only`). A platform company has at most
one connection, and one workforce company identity backs at most one platform
company in a tenant; the database enforces both. No Belimbing table or data is
adopted or imported.

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

`request_port/6` refuses an undeclared capability or direction with
`:unsupported`, a declared port without an enabled connection to that
provider with `:disconnected`, and an enabled one with `:adapter_unavailable`:
no adapter serves ports yet. The read and write port behaviours are neutral
placeholders for that later resolver.

## Page

`/integrations/people/connections` requires `people-connector.connections.view`
and lists only companies the actor can reach. It shows the connection state,
provider, both company axes and whether a credential is stored. With the manage
capability it offers provider choice, a masked credential field for providers
that declare one, enable/disable, and removal behind a confirmation. The menu
leaf **Administration › System › Integrations › People connections** carries
the view capability; the route enforces it again.
