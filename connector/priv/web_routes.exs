[
  %{
    path: "/integrations/people/connections",
    live: Bilimbi.PeopleConnector.Connector.Web.ConnectionsLive,
    session: :auth,
    capability: "people-connector.connections.view"
  }
]
