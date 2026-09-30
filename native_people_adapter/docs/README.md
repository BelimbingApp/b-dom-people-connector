# Native People adapter

`people_connector/native_people_adapter` will translate declared People
Workforce reads into Connector ports. It depends on the Connector module and
`people/workforce`; People does not depend on Connector. Connector's installed
catalog already declares the native provider (`people.native`) with company and
employee directory reads; this module does not serve those ports yet, and no
write, SSO, or remote transport capability exists. When it does, it implements
Connector's `ReadPort` (returning `Page` values of `WorkforceRecord`) and is
listed in `Connector.Adapters`.
