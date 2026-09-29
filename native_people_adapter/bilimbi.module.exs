[
  id: "people_connector/native_people_adapter",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_people_connector_native_people_adapter,
  namespace: Bilimbi.PeopleConnector.NativePeopleAdapter,
  dependencies: ["people/workforce", "people_connector/connector"],
  migrations: nil,
  web: nil,
  schema_contract: nil,
  contribution_provider: nil,
  dev_seed: nil
]
