[
  id: "people_connector/connector",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_connector_connector,
  namespace: Bilimbi.PeopleConnector.Connector,
  dependencies: [
    "base/audit",
    "base/artifacts",
    "base/authz",
    "base/database",
    "base/menu",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "people/workforce"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_002_070_001 => :bilimbi_only,
    20_261_002_070_002 => :bilimbi_only,
    20_261_002_070_003 => :bilimbi_only,
    20_261_002_173_001 => :bilimbi_only,
    20_261_002_190_001 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already.
  schema_contract: nil,
  contribution_provider: Bilimbi.PeopleConnector.Connector.Contributions,
  dev_seed: nil
]
