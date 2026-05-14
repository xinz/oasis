defmodule Oasis.Spec do
  @moduledoc false

  require Logger

  alias __MODULE__
  alias __MODULE__.{Document, RefExpander}

  def read(path) do
    path
    |> Document.load()
    |> build_document()
  end

  defp build_document({:ok, {data, opts}}) do
    data
    |> Document.new(opts)
    |> expand_refs()
    |> Spec.Path.build()
  end

  defp build_document({:error, %Oasis.FileNotFoundError{} = error}) do
    {:error, error}
  end

  defp build_document({:error, %Oasis.InvalidSpecError{} = error}) do
    {:error, error}
  end

  defp expand_refs(%Document{schema: schema, source_path: source_path} = document) do
    %{document | schema: RefExpander.expand_refs(schema, source_path: source_path)}
  end

end
