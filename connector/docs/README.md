# Connector

`people_connector/connector` owns integration contracts and disconnected state.
It requires the mounted `people/workforce` public module. It has no persistence,
transport, active connection, or menu contribution.

`Capability`, `Provider`, and `Registry` describe provider-declared read and
write ports without activating any of them. Duplicate or invalid declarations
are refused. `Connector.request_port/6` validates the platform company through
People Workforce, then returns `:unsupported` for an undeclared capability
or direction; a declared port returns `:disconnected` until a later
company-scoped connection contract exists. The read and write port behaviours
are neutral placeholders for that later resolver, not callable provider access.

`Connector.status/2` requires a validated tenant scope and explicit platform
company ID. It consumes People Workforce's `ReadResult` and uses its company
mapping only when `require_current/1` succeeds. Stale or unavailable identity
returns `{:error, {:not_current, freshness}}`, never a usable port. Current
reads return disconnected status with separate platform and workforce company
IDs; absent, cross-tenant, or inactive companies are refused.
The authorized `/integrations/people/connections` route displays this state
and has no activation controls or menu leaf. Its capability is
`people-connector.connections.view`; menu visibility waits for connection setup.

Future migrations create Bilimbi-only schema. Platform companies, workforce
companies, employees, provider identities, and login actors are separate
identities; integration state must not become People business history.
