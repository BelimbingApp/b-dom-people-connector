[
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
