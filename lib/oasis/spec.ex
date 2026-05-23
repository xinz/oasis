defmodule Oasis.Spec do
  @moduledoc false

  alias __MODULE__.{Document, OpenAPIRefResolver}

  def read(path) do
    path
    |> Document.load()
    |> build_document()
  end

  defp build_document({:ok, {data, opts}}) do
    data
    |> Document.new(opts)
    |> OpenAPIRefResolver.resolve()
    |> Oasis.Spec.Path.build()
  end

  defp build_document({:error, %Oasis.FileNotFoundError{} = error}) do
    {:error, error}
  end

  defp build_document({:error, %Oasis.InvalidSpecError{} = error}) do
    {:error, error}
  end

end
