# Connector

`people_connector/connector` owns future integration contracts, connection
state, workforce projections, and reconciliation. It requires the mounted
`people/workforce` public module. This scaffold has no persistence, transport,
routes, capabilities, or menu contribution.

Future migrations create Bilimbi-only schema. Platform companies, workforce
companies, employees, provider identities, and login actors are separate
identities; integration state must not become People business history.
