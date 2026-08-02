defmodule Oasis.Spec do
  @moduledoc """
  Loads and prepares OpenAPI documents for Oasis generation.

  `read/1` is the public file-ingestion entrypoint used by
  `mix oas.gen.plug`. It parses YAML or JSON, resolves the structural OpenAPI
  Reference Objects Oasis consumes, preserves JSON Schema references for
  JSONSchex, and normalizes path/operation data.

  Since the JSONSchex boundary migration, successful reads return an
  `Oasis.Spec.Document` rather than the decoded OpenAPI map directly. Callers
  that previously consumed a map should use `document.schema`; generation code
  should retain the complete document so source paths and URI aliases remain
  available.
  """

  alias __MODULE__.{Document, OpenAPIRefResolver}

  @doc """
  Reads and prepares an OpenAPI YAML or JSON document.

  Returns an `Oasis.Spec.Document` on success. File and specification failures
  are returned as `{:error, exception}` tuples.
  """
  @spec read(Path.t()) :: Document.t() | {:error, Exception.t()}
  def read(path) do
    path
    |> Document.load()
    |> build_document()
  end

  defp build_document({:ok, {data, opts}}) do
    try do
      data
      |> Document.new(opts)
      |> OpenAPIRefResolver.resolve()
      |> Oasis.Spec.Path.build()
    rescue
      error in Oasis.InvalidSpecError -> {:error, error}
    end
  end

  defp build_document({:error, %Oasis.FileNotFoundError{} = error}) do
    {:error, error}
  end

  defp build_document({:error, %Oasis.InvalidSpecError{} = error}) do
    {:error, error}
  end

end
