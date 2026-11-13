defmodule Mix.Tasks.Atanor.Release do
  @shortdoc "Writes the files that build an app and Atanor into one release image"
  @moduledoc """
  Writes what an app needs to run in the same VM as an Atanor node, as a Mix release in a container image.

      mix atanor.release [--force]

  The app starts the node itself: its supervision tree begins with `Atanor.Daemon.children/0`, which
  reads the settings of docs/configuration.md. The release must be named `atanor`, so the image has the
  layout, the entry point and the start script of the product image:

      releases: [atanor: [include_executables_for: [:unix]]]

  The task writes, in the project directory:

    * `rel/env.sh.eex` and `rel/overlays/bin/atanor-entrypoint`, copied from the `atanor` dependency
      (`daemon/rel`), which the product image uses too;
    * `Dockerfile` and `Dockerfile.dockerignore`, which build the release from public sources and
      run it as the `atanor` user.

  It leaves a file that differs from what it would write, unless `--force` is given. When `atanor` is
  a `path:` dependency outside the project (the examples of this repository), the Docker build context is
  the closest directory that holds both, and the task prints the command to run from the project
  directory (`-f` is resolved from there). docs/how-to-build-a-derived-image.md.
  """
  use Mix.Task
  require EEx

  @template """
  # syntax=docker/dockerfile:1
  # Written by `mix atanor.release`: the release of this app and Atanor in one VM, on the base of the
  # product image. Build it from the directory of this file, with <%= @context_name %> as the context:
  #   <%= @build_command %>
  # EXTRA_PACKAGES adds Debian packages to the image (for example curl, for a healthcheck).
  ARG ELIXIR_IMAGE=<%= @elixir_image %>
  ARG RUNTIME_IMAGE=<%= @runtime_image %>

  FROM ${ELIXIR_IMAGE} AS build
  ARG RUST_VERSION=<%= @rust_version %>
  RUN apt-get update \\
   && apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config \\
   && rm -rf /var/lib/apt/lists/*
  ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
  RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION}
  ENV MIX_ENV=prod LANG=C.UTF-8
  RUN mix local.hex --force && mix local.rebar --force
  ARG CARGO_BUILD_JOBS
  WORKDIR /src
  COPY . /src
  WORKDIR <%= @work_dir %>
  RUN mix deps.get --only prod
  RUN --mount=type=cache,target=/opt/cargo/registry \\
      --mount=type=cache,target=<%= @atanor_target %> \\
      --mount=type=cache,target=<%= @alambique_target %> \\
      mix release atanor --overwrite

  FROM ${RUNTIME_IMAGE}
  ARG EXTRA_PACKAGES=
  RUN apt-get update \\
   && apt-get install -y --no-install-recommends libssl3 libstdc++6 libncurses6 ca-certificates ${EXTRA_PACKAGES} \\
   && rm -rf /var/lib/apt/lists/* \\
   && useradd --system --uid 10001 --home-dir /var/lib/atanor --create-home atanor \\
   && mkdir /var/lib/atanor/cells \\
   && chown atanor /var/lib/atanor/cells
  ENV LANG=C.UTF-8
  COPY --from=build <%= @work_dir %>/_build/prod/rel/atanor /opt/atanor
  ARG RELEASE_ID=
  ENV ATANOR_RELEASE=${RELEASE_ID}
  USER atanor
  WORKDIR /var/lib/atanor
  EXPOSE 4000 4001 4002
  ENTRYPOINT ["/opt/atanor/bin/atanor-entrypoint"]
  CMD ["start"]
  """

  EEx.function_from_string(:defp, :dockerfile, @template, [:assigns])

  @ignore ~w(.git **/_build **/deps **/target **/node_modules **/erl_crash.dump* **/.env **/.env.*)

  # The bases of the product image (the Dockerfile at the repository root); a test keeps them equal.
  @pins %{
    elixir_image: "hexpm/elixir:1.20.4-erlang-28.5.0.7-debian-trixie-20261005-slim",
    runtime_image: "debian:trixie-20260824-slim",
    rust_version: "1.97.1"
  }

  # Where this file was compiled: the root of the `atanor` dependency, which holds `daemon/rel`.
  @root Path.expand("../../..", __DIR__)

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [force: :boolean])
    if invalid != [], do: Mix.raise("usage: mix atanor.release [--force]")

    unless Keyword.has_key?(Mix.Project.config()[:releases] || [], :atanor), do: Mix.raise(release_hint())

    plan = plan(File.cwd!(), @root)

    for {path, contents, mode} <- files(plan, @root) do
      write(path, contents, mode, opts[:force] || false)
    end

    Mix.shell().info("""

    Build the image, from this directory, with #{plan.context_name} as the context:
      #{plan.build_command}
    Then see docs/how-to-build-a-derived-image.md for what the node needs to start.\
    """)
  end

  @doc """
  Where the Docker build starts, for the project at `app` and the `atanor` dependency at `atanor`. The
  context is `app` when the dependency lies inside it (a git dependency, in `deps/`) and otherwise the
  closest directory above both. `app_dir` and `atanor_dir` are relative to the context, `context_arg` is
  the context as seen from `app`.
  """
  @spec plan(Path.t(), Path.t()) :: map
  def plan(app, atanor) do
    app = Path.expand(app)
    atanor = Path.expand(atanor)
    git? = String.starts_with?(atanor, app <> "/")
    context = if git?, do: app, else: common(app, atanor)
    app_dir = relative(app, context)
    context_arg = if app_dir == ".", do: ".", else: app_dir |> Path.split() |> Enum.map_join("/", fn _ -> ".." end)

    %{
      git?: git?,
      app_dir: app_dir,
      atanor_dir: relative(atanor, context),
      context_arg: context_arg,
      build_command:
        if(git?,
          do: "docker build -t my-app .",
          else: "docker build -f Dockerfile -t my-app #{context_arg}"
        ),
      context_name: if(git?, do: "this directory", else: "`#{context_arg}`"),
      work_dir: Path.expand(app_dir, "/src"),
      atanor_target: Path.expand(Path.join(relative(atanor, context), "native/atanor_wasm/target"), "/src"),
      alambique_target: Path.expand(Path.join(app_dir, "deps/alambique/native/alambique_nif/target"), "/src")
    }
  end

  @doc "The files to write, as `{relative path, contents, mode}`; `atanor` is the path of the dependency."
  @spec files(map, Path.t()) :: [{Path.t(), binary, non_neg_integer}]
  def files(plan, atanor) do
    rel = Path.join(atanor, "daemon/rel")

    [
      {"rel/env.sh.eex", File.read!(Path.join(rel, "env.sh.eex")), 0o644},
      {"rel/overlays/bin/atanor-entrypoint", File.read!(Path.join(rel, "overlays/bin/atanor-entrypoint")), 0o755},
      {"Dockerfile", dockerfile(Map.merge(plan, @pins)), 0o644},
      {"Dockerfile.dockerignore", dockerignore(plan), 0o644}
    ]
  end

  # A context that is not the project (a path dependency above it) holds other projects: send only the
  # sources of Atanor and of this project.
  defp dockerignore(%{git?: true}), do: Enum.join(@ignore, "\n") <> "\n"

  defp dockerignore(%{app_dir: app_dir, atanor_dir: atanor_dir}) do
    allow = for name <- ~w(mix.exs alambique.ref lib native wit), do: "!" <> join(atanor_dir, name)
    Enum.join(["*"] ++ allow ++ ["!" <> app_dir] ++ @ignore, "\n") <> "\n"
  end

  defp write(path, contents, mode, force?) do
    case File.read(path) do
      {:ok, ^contents} ->
        Mix.shell().info("unchanged  #{path}")

      {:ok, _} when not force? ->
        Mix.shell().error("kept       #{path} (it differs; --force replaces it)")

      _ ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
        File.chmod!(path, mode)
        Mix.shell().info("wrote      #{path}")
    end
  end

  defp release_hint do
    """
    the project has no release named atanor. Add it to mix.exs, so the image has the layout of the product image:

        releases: [atanor: [include_executables_for: [:unix]]]
    """
  end

  defp common(a, b) do
    [a, b] = Enum.map([a, b], &Path.split/1)
    a |> Enum.zip(b) |> Enum.take_while(fn {x, y} -> x == y end) |> Enum.map(&elem(&1, 0)) |> Path.join()
  end

  defp relative(path, context), do: if(path == context, do: ".", else: Path.relative_to(path, context))
  defp join(".", name), do: name
  defp join(dir, name), do: Path.join(dir, name)
end
