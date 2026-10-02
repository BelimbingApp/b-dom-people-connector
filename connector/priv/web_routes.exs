[
  %{
    path: "/integrations/people/backups",
    live: Bilimbi.PeopleConnector.Connector.Web.BackupsLive,
    session: :auth,
    capability: "people-connector.connections.manage"
  },
  %{
    path: "/integrations/people/operations",
    live: Bilimbi.PeopleConnector.Connector.Web.OperationsLive,
    session: :auth,
    capability: "people-connector.connections.manage"
  },
  %{
    path: "/integrations/people/files",
    live: Bilimbi.PeopleConnector.Connector.Web.FilesLive,
    session: :auth,
    capability: "people-connector.connections.manage"
  },
  %{
    path: "/integrations/people/files/:company_id/:id",
    controller: Bilimbi.PeopleConnector.Connector.Web.FilesController,
    action: :download,
    session: :auth,
    capability: "people-connector.connections.manage"
  },
  %{
    webhook: "people-native",
    verify: {Bilimbi.PeopleConnector.Connector.Webhooks, :verify},
    handle: {Bilimbi.PeopleConnector.Connector.Webhooks, :handle}
  },
  %{
    path: "/integrations/people/connections",
    live: Bilimbi.PeopleConnector.Connector.Web.ConnectionsLive,
    session: :auth,
    capability: "people-connector.connections.view"
  }
]
