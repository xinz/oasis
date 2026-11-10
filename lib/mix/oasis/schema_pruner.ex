defmodule Mix.Oasis.SchemaPruner do
  @moduledoc false

  # `JSONSchex.bundle_fragment/2` returns a standalone schema which embeds the
  # complete containing OpenAPI document plus every external document that is
  # reachable from the entry schema. For large specifications (for example a
  # small API file referencing a multi-megabyte data model) this would copy the
  # whole documents into every generated module.
  #
  # This module shrinks such a bundle to the subtrees which are actually
  # reachable from the entry schema by following `$ref`s. Anything it cannot
  # reason about safely (anchors, dynamic references, nested `$id`s, unresolved
  # refs, refs through arrays, ...) makes it return the original bundle
  # untouched, so pruning can never change validation behavior.

  alias JSONSchex.URIUtil

  @external_prefix "jsonschex_external"
  @unsupported_keywords [
    "$id",
    "$anchor",
    "$dynamicAnchor",
    "$dynamicRef",
    "$recursiveRef",
    "$recursiveAnchor"
  ]

  @doc """
  Prunes a bundled schema, using `root_spec` (the document the bundle was
  produced from) to tell which top-level keys belong to the entry schema.
  """
  @spec prune(term(), term()) :: term()
  def prune(bundle, root_spec) when is_map(bundle) and is_map(root_spec) do
    catch_unsupported(fn -> do_prune(bundle, root_spec) end, bundle)
  end

  def prune(bundle, _root_spec), do: bundle

  defp catch_unsupported(fun, fallback) do
    fun.()
  catch
    :unsupported -> fallback
  end

  defp do_prune(bundle, root_spec) do
    {generated, bundle_defs} = split_defs(Map.get(bundle, "$defs", %{}))

    root_doc =
      case bundle_defs do
        defs when map_size(defs) == 0 -> Map.delete(bundle, "$defs")
        defs -> Map.put(bundle, "$defs", defs)
      end

    root_id = Map.get(root_doc, "$id")

    live_keys =
      for {key, value} <- root_doc,
          key != "$id",
          Map.fetch(root_spec, key) != {:ok, value},
          do: key

    resources =
      Enum.reduce(generated, %{root: {root_id, root_doc}}, fn {key, doc}, acc ->
        Map.put(acc, key, {Map.fetch!(doc, "$id"), doc})
      end)

    ids = index_ids(resources)

    # The live keys together form the entry schema: they are kept as a whole,
    # and the entry schema as a unit is walked for refs (it may be a plain
    # `{"$ref": ...}`).
    kept = %{root: Enum.map(live_keys, &[&1])}
    entry_schema = Map.take(root_doc, live_keys)
    kept = walk(entry_schema, {:root, root_id}, kept, resources, ids)

    assemble(kept, resources, root_id)
  end

  # Returns `{generated_external_resources, remaining_user_defs}`.
  defp split_defs(defs) when is_map(defs) do
    Enum.reduce(defs, {%{}, %{}}, fn {key, value}, {generated, rest} ->
      cond do
        String.starts_with?(key, @external_prefix) and is_map(value) and
            is_binary(Map.get(value, "$id")) ->
          {Map.put(generated, key, value), rest}

        String.starts_with?(key, "jsonschex_") ->
          throw(:unsupported)

        true ->
          {generated, Map.put(rest, key, value)}
      end
    end)
  end

  defp split_defs(_defs), do: throw(:unsupported)

  defp index_ids(resources) do
    Enum.reduce(resources, %{}, fn
      {_key, {nil, _doc}}, acc ->
        acc

      {key, {id, _doc}}, acc ->
        if Map.has_key?(acc, id), do: throw(:unsupported)
        Map.put(acc, id, key)
    end)
  end

  # Marks `path` of resource `key` as needed and follows all refs contained in
  # the kept subtree.
  defp keep(kept, key, path, resources, ids) do
    paths = Map.get(kept, key, [])

    if covered?(paths, path) do
      kept
    else
      kept = Map.put(kept, key, [path | paths])
      {base, doc} = Map.fetch!(resources, key)
      value = fetch_path!(doc, path)

      value =
        if path == [] and is_map(value), do: Map.delete(value, "$id"), else: value

      walk(value, {key, base}, kept, resources, ids)
    end
  end

  defp covered?(paths, path) do
    Enum.any?(paths, &List.starts_with?(path, &1))
  end

  defp walk(%{} = map, ctx, kept, resources, ids) do
    Enum.each(@unsupported_keywords, fn keyword ->
      if is_binary(Map.get(map, keyword)), do: throw(:unsupported)
    end)

    kept =
      case map do
        %{"$ref" => ref} when is_binary(ref) -> follow(ref, ctx, kept, resources, ids)
        _other -> kept
      end

    Enum.reduce(map, kept, fn {_key, value}, acc -> walk(value, ctx, acc, resources, ids) end)
  end

  defp walk(list, ctx, kept, resources, ids) when is_list(list) do
    Enum.reduce(list, kept, fn value, acc -> walk(value, ctx, acc, resources, ids) end)
  end

  defp walk(_value, _ctx, kept, _resources, _ids), do: kept

  defp follow(ref, {key, base}, kept, resources, ids) do
    {uri, fragment} = URIUtil.split_fragment(ref)

    target_key =
      case uri do
        "" ->
          key

        uri ->
          case Map.fetch(ids, URIUtil.resolve(base, uri)) do
            {:ok, target} -> target
            :error -> throw(:unsupported)
          end
      end

    path =
      case fragment do
        nil -> []
        "" -> []
        "/" <> _ = pointer -> decode_pointer(pointer)
        _anchor -> throw(:unsupported)
      end

    # A whole-document reference to the bundle root would require keeping
    # everything, which is the same as not pruning.
    if path == [] and target_key == :root, do: throw(:unsupported)

    keep(kept, target_key, path, resources, ids)
  end

  defp decode_pointer("/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(fn token ->
      token
      |> URI.decode()
      |> String.replace("~1", "/")
      |> String.replace("~0", "~")
    end)
  end

  defp fetch_path!(doc, []), do: doc

  defp fetch_path!(%{} = doc, [token | rest]) do
    case Map.fetch(doc, token) do
      {:ok, value} -> fetch_path!(value, rest)
      :error -> throw(:unsupported)
    end
  end

  # Pointers going through arrays (or scalars) are not supported.
  defp fetch_path!(_doc, _path), do: throw(:unsupported)

  defp assemble(kept, resources, root_id) do
    {_id, root_doc} = Map.fetch!(resources, :root)

    root =
      kept
      |> Map.get(:root, [])
      |> build(root_doc, base_with_id(root_id))

    externals =
      for {key, paths} <- kept, key != :root, into: %{} do
        {id, doc} = Map.fetch!(resources, key)
        {key, build(paths, doc, id |> base_with_id() |> put_schema(doc))}
      end

    if map_size(externals) == 0 do
      root
    else
      Map.update(root, "$defs", externals, &Map.merge(&1, externals))
    end
  end

  defp base_with_id(nil), do: %{}
  defp base_with_id(id), do: %{"$id" => id}

  defp put_schema(acc, %{"$schema" => schema}), do: Map.put(acc, "$schema", schema)
  defp put_schema(acc, _doc), do: acc

  defp build(paths, doc, acc) do
    paths
    |> minimal_paths()
    |> Enum.reduce(acc, fn
      [], _acc -> doc
      path, acc -> put_path(acc, path, fetch_path!(doc, path))
    end)
  end

  defp minimal_paths(paths) do
    paths = Enum.uniq(paths)

    Enum.reject(paths, fn path ->
      Enum.any?(paths, fn other -> other != path and List.starts_with?(path, other) end)
    end)
  end

  defp put_path(_acc, [], value), do: value

  defp put_path(acc, [token | rest], value) do
    child = Map.get(acc, token, %{})
    Map.put(acc, token, put_path(child, rest, value))
  end
end
