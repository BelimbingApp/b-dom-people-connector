# Native People adapter

`people_connector/native_people_adapter` serves the co-located native People
provider (`people.native`) to the Connector's read port from the People
Workforce public API. It depends on the Connector module and `people/workforce`;
People does not depend on Connector, and this module owns no tables, settings
or routes. Its application registers the adapter with `Connector.Adapters` at
start and withdraws it at stop, so unmounting the module leaves the Connector
refusing passes with `:adapter_unavailable`.

## What it serves

Only what the provider declares in `Connector.Providers`: `company_directory`,
`employee_directory` and `organization_directory` reads. The Connector runs
the company/employee stream under
the `employee_directory` authorization, and the adapter returns the company
first and then its employees as `WorkforceRecord` values. Employee records carry
the People employee number, display name, email and supervisor reference, never
a login actor or People business history. There is no writer, single sign-on,
manager-hierarchy read or remote transport. Organisation reads use
`Workforce.positions/4`, with positions, parent references, current version,
vacancy and at most 500 assignment facts per position. Assignment identities
and employee references stay distinct; they carry no login actor. The public
seam flags incomplete assignment lists, and the Connector preserves that flag.

## Scope and refusal

The adapter trusts only the `PortAuthorization` the Connector issues. It refuses
with a fixed atom, never People text, an authorization that:

- names another provider, a capability other than `employee_directory` or
  `organization_directory`, or a direction other than read (`:invalid_authorization`);
- names a workforce source other than `people/native`, or a workforce company
  that differs from the platform company (native identity maps one to one);
- is not a valid page request or cursor (`:invalid_request`, `:invalid_cursor`).

Reads go through `Workforce.company/2` and `Workforce.employees/2` with the
Connector's scope and platform company, so a company the scope's tenant cannot
see, or one that is not live, is `:not_found`, and only the working statuses the
company configures are exposed. A stale or unavailable Workforce result becomes
an empty page carrying that freshness, which stops the pass with nothing
applied. A result whose company axes do not match the authorization is
`:mapping_mismatch`.

## Paging and freshness

Native People has no change feed and no per-record observation time. Every
page of a pass shares one watermark, minted on the first page and carried in the
page cursor together with the last key emitted (the company is key 0, an
employee its native ID). Pages are therefore stable while the workforce changes
during a pass. A `:changes` pass returns the same full snapshot as a
`:bootstrap` pass, and every page is marked `snapshot: true`, so any
synchronisation deactivates an employee who has left. Each page rereads
Workforce, so a pass over many pages costs one read per page.

Organisation pages use the Workforce seam's bounded paging (at most 100
positions per page). Their cursor binds the tenant, platform company, page
size and observation watermark; a different stream or page size is refused.
The watermark fixes the effective day across a pass. Replaying a cursor over
unchanged source facts returns the same page. The seam uses offset paging,
so this is a live read, not a frozen database snapshot: concurrent position
changes can affect later pages. The Connector therefore deactivates absent
positions only when the stream arrived in a single page; with more pages an
ended position stays active until a pass fits in one page. A full page may be
followed by an empty final page. Missing Organisation returns unavailable; the
Connector still applies company and employee changes, leaves positions as they
were and opens an `organisation_unavailable` issue.

The engine reads the declared organisation stream alongside company/employees
before applying the combined pass. Position projection identity includes kind,
source and stable ID, so equal employee and position IDs never collide.
