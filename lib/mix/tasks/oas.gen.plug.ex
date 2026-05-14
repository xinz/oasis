defmodule Mix.Tasks.Oas.Gen.Plug do
  @shortdoc "Generates Router and Plug modules from OpenAPI Specification"

  @moduledoc """
  Generates router and plug handlers from an OpenAPI specification in a YAML or JSON file.

      mix oas.gen.plug --file path/to/openapi.yaml
      mix oas.gen.plug --file path/to/openapi.yml
      mix oas.gen.plug --file path/to/openapi.json

  The `oas.gen.plug` mix task accepts these arguments:

  * `--file`, required. The full path to the specification file in YAML or JSON format.
  * `--router`, optional. The generated router module alias. The default is `Router`, which produces `Oasis.Gen.Router` by default. For example, if you pass `--router Hello.MyRouter` and do not define another namespace, the final router module becomes `Oasis.Gen.Hello.MyRouter` in `/lib/oasis/gen/hello/my_router.ex`.
  * `--name-space`, optional. The namespace for all generated modules. The default is `Oasis.Gen`. This argument always overrides any `"x-oasis-name-space"` fields defined in the specification file.
  * `--force`, optional. Forces creation without a shell prompt.
  * `--quiet`, optional. Does not log command output.
  """
  use Mix.Task

  @parse_opts [
    switches: [
      file: :string,
      router: :string,
      name_space: :string,
      body_reader: :string,
      force: :boolean,
      quiet: :boolean
    ],
    aliases: [f: :file, r: :router, n: :name_space, q: :quiet]
  ]

  def run(args) do
    if Mix.Project.umbrella?() do
      Mix.raise("mix oas.gen.plug can only be run inside an application directory")
    end

    Mix.shell().info("Generates Router and Plug modules from OAS")

    paths = Mix.Oasis.generator_paths()

    opts = parse_opts(args)
    files = build(opts)
    Mix.Oasis.copy_from(paths, "priv/templates/oas.gen.plug", files, opts)
  end

  defp build(opts) do
    %Oasis.Spec.Document{schema: schema} = Oasis.Spec.read(opts[:file])

    opts = Keyword.take(opts, [:router, :name_space, :body_reader])

    Mix.Oasis.new(schema, opts)
  end

  defp parse_opts(args) do
    {opts, _, _} = OptionParser.parse(args, @parse_opts)
    validate_opts!(opts)
  end

  defp validate_opts!(opts) do
    oas_file_path = Keyword.get(opts, :file)

    if oas_file_path == nil do
      raise_with_help("Expected input `--file` option to be a valid path to a yaml/json file")
    else
      if File.exists?(oas_file_path) do
        opts
      else
        raise_with_help("Could not find the file in `#{oas_file_path}` path")
      end
    end
  end

  defp raise_with_help(msg) do
    Mix.raise("""
    #{msg}

    For example:

        mix oas.gen.plug --file path/to/file.yaml
        mix oas.gen.plug --file path/to/file.json
        mix oas.gen.plug --file path/to/file.yml --name-space Test --router Router

    By default the `--name-space` is "Oasis.Gen", and by default
    the `--router` is "Router", these two options are optional.
    """)
  end
end
