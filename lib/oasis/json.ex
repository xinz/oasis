defmodule Oasis.JSON do
  @moduledoc """
  JSON encode/decode helpers used by Oasis.

  This module provides a stable Oasis-owned wrapper around `JSONSchex.JSON`,
  which delegates to the available JSON backend such as the built-in `JSON`
  module on Elixir v1.18+ versions or `Jason` when appropriate.
  """

  alias JSONSchex.JSON, as: BackendJSON

  @spec decode(iodata()) :: {:ok, term()} | {:error, term()}
  defdelegate decode(data), to: BackendJSON

  @spec decode!(iodata()) :: term()
  defdelegate decode!(data), to: BackendJSON

  @spec encode!(term()) :: iodata()
  defdelegate encode!(data), to: BackendJSON

  @spec encode_to_iodata!(term()) :: iodata()
  defdelegate encode_to_iodata!(data), to: BackendJSON
end
