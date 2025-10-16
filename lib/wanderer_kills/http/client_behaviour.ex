defmodule WandererKills.Http.ClientBehaviour do
  @moduledoc """
  Behaviour definition for HTTP client implementations.

  This allows for easy mocking in tests and potential alternative implementations.
  """

  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type options :: keyword()
  @type response :: {:ok, map()} | {:error, term()}

  @callback get(url, headers, options) :: response
  @callback get_with_rate_limit(url, headers, options) :: response
  @callback post(url, body :: term(), headers, options) :: response
  @callback get_esi(url, headers, options) :: response
  @callback get_zkb(url, headers, options) :: response
end
