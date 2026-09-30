Code.require_file(Path.expand("../../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.PeopleConnector.NativePeopleAdapter.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../../..", __DIR__)

  def project do
    [
      app: :bilimbi_people_connector_native_people_adapter,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      elixir: "~> 1.20",
      compilers: [:bilimbi_graph] ++ Mix.compilers(),
      bilimbi_module_root: __DIR__,
      start_permanent: Mix.env() == :prod,
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.module_dependencies(__DIR__)
    ]
  end

  def application do
    [
      mod: {Bilimbi.PeopleConnector.NativePeopleAdapter.Application, []},
      extra_applications: [:logger],
      env: Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__)
    ]
  end
end
