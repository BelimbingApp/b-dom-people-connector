# b-dom-people-connector Agent Guide

This repository mounts at `apps/domains/people_connector` inside Bilimbi; it
does not build alone. Read Bilimbi's root `AGENTS.md`, `apps/domains/AGENTS.md`,
and `docs/architecture/0010_composition-model.md` before editing a mounted
copy. The [README](README.md) gives mount and CI instructions.

- Put code, migrations, tests, and documentation under the owning child module.
  The container root holds only composition files; Bilimbi's workspace
  boundary enforces this.
- Declare every cross-module dependency in the child's `bilimbi.module.exs`.
  Connector requires `people/workforce`; the native adapter requires that
  module and `people_connector/connector`. Use People public APIs rather than
  reading its private tables.
- Use meta-terms in this public repository. Keep customer and vendor names,
  country rules, endpoints, credentials, mappings, schedules, thresholds, and
  visibility out of hard-coded behavior. Provide operator settings and a UI
  when those capabilities are built; secrets must be encrypted and never
  displayed back or logged.
- Keep platform company, workforce company, provider identity, employee, and
  login actor distinct. Tenant-owned operations require a validated
  `Bilimbi.Base.Tenancy.Scope`; a schema or API must state which company axis
  each identifier belongs to.
- New tables are Bilimbi-only and module-owned. Do not build legacy adoption,
  import, or dual-run paths for People data. The relevant migration and schema
  rules live in Bilimbi's `docs/architecture/database.md`.
- Run `mix precommit` from the mounted Bilimbi root. The pinned host revision
  is `.github/bilimbi-revision`; CI's topology matrix is
  `.github/workflows/ci.yml`. Do not commit a composition lock in this repo.
- A Connector adapter registers itself with `Connector.Adapters.register/2` in
  its application start; do not hard-code adapter modules in the Connector,
  which cannot depend on them. See `native_people_adapter/docs/README.md`.
- Pick a new migration version later than every version in the mounted Bilimbi
  (including `apps/base/*`), not by date of authoring: Bilimbi refuses to start
  on duplicate versions. `connector/test/migration_versions_test.exs` fails on a
  collision when run from a mounted checkout.
