Code.require_file(Path.expand("../../../../web/test/test_helper.exs", __DIR__))
Code.require_file(Path.expand("../test/support/test_fixtures.ex", __DIR__))
# Host tests exercise the installed native organisation reader using its owner's fixtures.
# This does not introduce an adapter-to-Organisation production dependency.
Code.require_file(
  Path.expand("../../../people/organisation/test/support/test_fixtures.ex", __DIR__)
)
