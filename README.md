# b-dom-people-connector

People Connector Domain for [Bilimbi](https://github.com/BelimbingApp/bilimbi).
It is an optional repository mounted at `apps/domains/people_connector` in a
Bilimbi checkout. The first release requires the separate
[`b-dom-people`](https://github.com/BelimbingApp/b-dom-people) repository mounted
at `apps/domains/people`, because Connector depends on `people/workforce`.
It does not build as a standalone Mix project.

| Module | Descriptor ID | Future ownership |
| --- | --- | --- |
| [`connector/`](connector/docs/README.md) | `people_connector/connector` | integration contracts, connections, projections, reconciliation |
| [`native_people_adapter/`](native_people_adapter/docs/README.md) | `people_connector/native_people_adapter` | in-process People Workforce adapter |

This is a composition scaffold only: it has no business tables, migrations,
transport, routes, capabilities, or menu entries. New persistence will use a
fresh Bilimbi schema. No legacy People users or data are being migrated.

## Mount

From a Bilimbi checkout:

```sh
git clone https://github.com/BelimbingApp/b-dom-people.git apps/domains/people
git clone https://github.com/BelimbingApp/b-dom-people-connector.git apps/domains/people_connector
mix deps.get
mix precommit
```

Bilimbi discovers both containers from their descriptors. The folder name is
the container ID; see Bilimbi's
[composition model](https://github.com/BelimbingApp/bilimbi/blob/main/docs/architecture/0010_composition-model.md).
Removing Connector removes its code from the next composition. Mounting
Connector without People fails with `module people_connector/connector declares
missing dependency people/workforce`.

## CI

[CI](.github/workflows/ci.yml) mounts the repositories into Bilimbi at the
revision in [`.github/bilimbi-revision`](.github/bilimbi-revision). It verifies
both mounted, People alone, neither mounted, and the expected failure when
Connector is mounted without People. Update the pin when adopting a newer
Bilimbi revision. The People checkout uses the `fm/people-scaffold` branch
while that scaffold is pending; switch CI to `main` after it merges.

## License

[MIT](LICENSE).
