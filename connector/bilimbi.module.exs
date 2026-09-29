[
  id: "people_connector/connector",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_connector_connector,
  namespace: Bilimbi.PeopleConnector.Connector,
  dependencies: [
    "base/authz",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "people/workforce"
  ],
  migrations: nil,
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.PeopleConnector.Connector.Contributions,
  dev_seed: nil
]
