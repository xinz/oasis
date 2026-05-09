defmodule Oasis.Spec do
  @moduledoc false

  require Logger

  alias __MODULE__
  alias __MODULE__.{Document, RefResolver}

  def read(path) do
    path
    |> extract_path_suffix()
    |> read_file()
    |> build_document()
  end

  defp build_document({:ok, {data, opts}}) do
    data
    |> Document.new(opts)
    |> expand_refs()
    |> Spec.Path.build()
  end

  defp build_document({:error, %YamlElixir.FileNotFoundError{message: message}}) do
    {:error, %Oasis.FileNotFoundError{message: message}}
  end

  defp build_document({:error, %YamlElixir.ParsingError{message: message}}) do
    {:error, %Oasis.InvalidSpecError{message: "Failed to parse yaml file: #{message}"}}
  end

  defp build_document({:error, %Oasis.FileNotFoundError{} = error}) do
    {:error, error}
  end

  defp build_document({:error, %Oasis.InvalidSpecError{} = error}) do
    {:error, error}
  end

  defp build_document({:error, %Jason.DecodeError{data: data}}) do
    {:error, %Oasis.InvalidSpecError{message: "Failed to parse json file: `#{data}`"}}
  end

  defp expand_refs(%Document{schema: schema} = document) do
    %{document | schema: RefResolver.expand_local_refs(schema)}
  end

  defp extract_path_suffix(path) do
    suffix = path |> String.trim() |> String.slice(-4..-1) |> String.downcase()
    {suffix, path}
  end

  defp read_file({type, path}) when type == "yaml" or type == ".yml" do
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> {:ok, {data, [source_path: path, format: type]}}
      {:error, _reason} = error -> error
    end
  end

  defp read_file({"json", path}) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, {data, [source_path: path, format: "json"]}}
          {:error, _reason} = error -> error
        end

      {:error, posix} ->
        {:error,
         %Oasis.FileNotFoundError{
           message: "Failed to open file #{inspect(path)} with error #{posix}"
         }}
    end
  end

  defp read_file({invalid_type, _path}) do
    {:error,
     %Oasis.InvalidSpecError{
       message: "Expect a yml/yaml or json format file, but got: `#{invalid_type}`"
     }}
  end
end
