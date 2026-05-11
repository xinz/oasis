defmodule Mix.Oasis do
  @moduledoc false

  @jsonschex_compile_options [format_assertion: true, content_assertion: false]

  def new(%{"paths" => paths} = spec, opts) when is_map(paths) do
    Mix.Oasis.Router.generate_files_by_paths_spec(generator_paths(), spec, opts)
  end

  def new(spec, _opts) do
    raise "could not find any paths defined in #{inspect(spec)}"
  end

  def name_space(nil) do
    {
      "Oasis.Gen",
      "lib/oasis/gen"
    }
  end

  def name_space(name_space) when is_bitstring(name_space) do
    splited = split_module_alias(name_space)

    path = module_alias_to_path(splited)

    {
      conact_module_alias(splited),
      Path.join(["lib", path])
    }
  end

  defp split_module_alias(str) do
    str |> String.split(".") |> Enum.filter(&(&1 != ""))
  end

  defp module_alias_to_path(aliases) when is_list(aliases) do
    aliases
    |> Enum.map(&Recase.to_snake(&1))
    |> Enum.join("/")
  end

  def module_alias(name) when is_bitstring(name) do
    process_module_alias(name)
  end

  def module_alias(%{operation_id: operation_id}) when operation_id != nil do
    process_module_alias(operation_id)
  end

  def module_alias(%{http_verb: http_verb, url: url}) do
    uri = URI.parse(url)
    url = uri.path |> String.replace(["/", ":", "."], "-")
    last_alias = "#{http_verb}#{url}"
    module_alias_and_file_path(last_alias, [], [last_alias])
  end

  defp process_module_alias(name) do
    splited = split_module_alias(name)

    {last_alias, prefix_aliases} = List.pop_at(splited, -1)

    if last_alias == nil do
      raise "input invalid module alias: `#{name}`"
    end

    module_alias_and_file_path(last_alias, prefix_aliases, splited)
  end

  defp module_alias_and_file_path(last_alias, [], aliases) do
    {
      conact_module_alias(aliases),
      "#{Recase.to_snake(last_alias)}.ex"
    }
  end

  defp module_alias_and_file_path(last_alias, prefix_aliases, aliases) do
    path = module_alias_to_path(prefix_aliases)

    {
      conact_module_alias(aliases),
      "#{path}/#{Recase.to_snake(last_alias)}.ex"
    }
  end

  defp conact_module_alias(aliases) do
    aliases
    |> Enum.map(&Recase.to_pascal(&1))
    |> Enum.join(".")
  end

  def copy_from(apps, source_dir, mapping, opts \\ []) when is_list(mapping) do
    roots = Enum.map(apps, &to_app_source(&1, source_dir))
    create_file_opts = Keyword.take(opts, [:force, :quiet])

    for {format, target, source_file_path, module_name, binding} <- mapping do
      source =
        Enum.find_value(roots, fn root ->
          source = Path.join(root, source_file_path)
          if File.exists?(source), do: source
        end) || raise "could not find #{source_file_path} in any of the sources"

      binding = Map.put(binding, :module_name, module_name)
      file_contents = EEx.eval_file(source, context: binding) |> Code.format_string!()

      case format do
        :eex ->
          Mix.Generator.create_file(target, file_contents, create_file_opts)

        :new_eex ->
          if File.exists?(target) do
            :ok
          else
            Mix.Generator.create_file(target, file_contents, create_file_opts)
          end
      end
    end
  end

  def generator_paths() do
    [".", :oasis]
  end

  def eval_from(apps, source_file_path, binding) do
    sources = Enum.map(apps, &to_app_source(&1, source_file_path))

    content =
      Enum.find_value(sources, fn source ->
        File.exists?(source) && File.read!(source)
      end) || raise "could not find #{source_file_path} in any of the sources"

    EEx.eval_string(content, binding)
  end

  def render_embedded_schemas(term) do
    term
    |> schema_container_to_ast()
    |> Macro.to_string()
  end

  def compile_json_schema!(%JSONSchex.Types.Schema{} = schema), do: schema

  def compile_json_schema!(schema) when is_map(schema) or is_boolean(schema) do
    case JSONSchex.compile(schema, @jsonschex_compile_options) do
      {:ok, compiled} ->
        compiled

      {:error, error} ->
        raise ArgumentError, JSONSchex.format_error(error)
    end
  end

  defp schema_container_to_ast(%JSONSchex.Types.Schema{} = schema) do
    compiled_schema_ast(schema)
  end

  defp schema_container_to_ast(%{} = map) do
    {:%{}, [], map |> Enum.sort_by(&entry_sort_key/1) |> Enum.map(&schema_map_entry_to_ast/1)}
  end

  defp schema_container_to_ast(list) when is_list(list) do
    Enum.map(list, &schema_container_to_ast/1)
  end

  defp schema_container_to_ast(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&schema_container_to_ast/1)
    |> List.to_tuple()
  end

  defp schema_container_to_ast(value) do
    Macro.escape(value)
  end

  defp schema_map_entry_to_ast({"schema", %JSONSchex.Types.Schema{} = schema}) do
    {Macro.escape("schema"), compiled_schema_ast(schema)}
  end

  defp schema_map_entry_to_ast({"schema", schema}) do
    raise ArgumentError,
          "expected nested \"schema\" value to be a compiled JSONSchex.Types.Schema, got: #{inspect(schema, pretty: true)}"
  end

  defp schema_map_entry_to_ast({key, value}) do
    {Macro.escape(key), schema_container_to_ast(value)}
  end

  defp compiled_schema_ast(%JSONSchex.Types.Schema{} = schema) do
    compile_schema_ast(schema.raw, compile_options_from_compiled(schema))
  end

  defp compile_schema_ast(schema, opts) do
    quote do
      JSONSchex.Schema.compile!(
        unquote(Macro.escape(schema)),
        unquote(opts)
      )
    end
  end

  defp compile_options_from_compiled(%JSONSchex.Types.Schema{} = schema) do
    [
      format_assertion: schema.format_assertion,
      content_assertion: schema.content_assertion
    ]
  end

  defp entry_sort_key({key, _value}), do: :erlang.term_to_binary(key)

  defp to_app_source(path, source_dir) when is_binary(path),
    do: Path.join(path, source_dir)

  defp to_app_source(app, source_dir) when is_atom(app),
    do: Application.app_dir(app, source_dir)
end
