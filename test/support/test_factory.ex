defmodule WandererKills.TestFactory do
  @moduledoc """
  Test factory for creating mock expectations and test data.

  This module provides factory functions to set up common mock patterns
  and generate test data consistently across tests.
  """

  import Mox

  @doc """
  Sets up a mock HTTP client to always succeed with the given response.
  """
  def mock_http_success(client_mock \\ WandererKills.Http.ClientMock, response \\ %{}) do
    client_mock
    |> expect(:get_with_rate_limit, fn _url, _opts ->
      {:ok, %{status: 200, body: response}}
    end)
  end

  @doc """
  Sets up a mock HTTP client to always return not found.
  """
  def mock_http_not_found(client_mock \\ WandererKills.Http.ClientMock) do
    client_mock
    |> expect(:get_with_rate_limit, fn _url, _opts ->
      {:error, :not_found}
    end)
  end

  @doc """
  Sets up a mock HTTP client to always be rate limited.
  """
  def mock_http_rate_limited(client_mock \\ WandererKills.Http.ClientMock) do
    client_mock
    |> expect(:get_with_rate_limit, fn _url, _opts ->
      {:error, :rate_limited}
    end)
  end

  @doc """
  Sets up a mock HTTP client with multiple responses based on URL patterns.

  ## Example

      mock_http_responses(%{
        "killmails" => {:ok, %{status: 200, body: %{"killmail_id" => 123}}},
        "universe" => {:error, :timeout}
      })
  """
  def mock_http_responses(url_responses, client_mock \\ WandererKills.Http.ClientMock) do
    client_mock
    |> expect(:get_with_rate_limit, fn url, _opts ->
      find_matching_response(url, url_responses)
    end)
  end

  defp find_matching_response(url, url_responses) do
    Enum.find_value(url_responses, {:error, :not_found}, fn {pattern, response} ->
      if String.contains?(url, pattern), do: response
    end)
  end

  @doc """
  Sets up a mock ESI client to always succeed.
  """
  def mock_esi_success(esi_mock \\ EsiClientMock, response \\ %{}) do
    esi_mock
    |> expect(:get, fn _url, _opts ->
      {:ok, %{status: 200, body: response}}
    end)
  end

  @doc """
  Sets up a mock ESI client to always return not found.
  """
  def mock_esi_not_found(esi_mock \\ EsiClientMock) do
    esi_mock
    |> expect(:get, fn _url, _opts ->
      {:error, :not_found}
    end)
  end

  @doc """
  Creates a test killmail with the given ID and optional overrides.
  """
  def build_killmail(killmail_id, overrides \\ %{}) do
    base_killmail = %{
      "killmail_id" => killmail_id,
      "killmail_time" => "2024-01-01T12:00:00Z",
      "solar_system_id" => 30_000_142,
      "victim" => %{
        "character_id" => 95_465_499,
        "corporation_id" => 1_000_009,
        "alliance_id" => 1_354_830_081,
        "ship_type_id" => 587,
        "damage_taken" => 1337
      },
      "attackers" => [
        %{
          "character_id" => 95_465_500,
          "corporation_id" => 1_000_010,
          "alliance_id" => nil,
          "ship_type_id" => 17_619,
          "weapon_type_id" => 2488,
          "damage_done" => 1337,
          "final_blow" => true
        }
      ],
      "zkb" => %{
        "totalValue" => 10_000_000.0,
        "points" => 10,
        "npc" => false,
        "hash" => "abcdef123456"
      }
    }

    Map.merge(base_killmail, overrides)
  end

  @doc """
  Creates a test system with the given ID and optional overrides.
  """
  def build_system(system_id, overrides \\ %{}) do
    base_system = %{
      "system_id" => system_id,
      "name" => "Test System #{system_id}",
      "security" => 0.5
    }

    Map.merge(base_system, overrides)
  end

  @doc """
  Creates a test character with the given ID and optional overrides.
  """
  def build_character(character_id, overrides \\ %{}) do
    base_character = %{
      "character_id" => character_id,
      "name" => "Test Character #{character_id}",
      "corporation_id" => 1_000_009
    }

    Map.merge(base_character, overrides)
  end

  @doc """
  Creates a random killmail ID for testing.
  """
  def random_killmail_id do
    System.unique_integer([:positive]) + 100_000_000
  end

  @doc """
  Creates a random system ID for testing.
  """
  def random_system_id do
    Enum.random(30_000_000..31_000_000)
  end

  @doc """
  Creates a random character ID for testing.
  """
  def random_character_id do
    System.unique_integer([:positive]) + 90_000_000
  end

  @doc """
  Sets up property-based testing with common configurations.
  """
  def configure_property_testing do
    Application.put_env(:stream_data, :max_runs, 50)
    Application.put_env(:stream_data, :max_shrinking_steps, 100)
  end

  @doc """
  Sets up property testing with performance focus (fewer runs).
  """
  def configure_fast_property_testing do
    Application.put_env(:stream_data, :max_runs, 20)
    Application.put_env(:stream_data, :max_shrinking_steps, 50)
  end

  @doc """
  Build function for benchmark compatibility.
  Supports :full_killmail, :partial_killmail, and :raw_killmail atoms.
  """
  def build(type, overrides \\ %{})

  def build(:full_killmail, overrides) do
    build_killmail(random_killmail_id(), overrides)
  end

  def build(:partial_killmail, overrides) do
    # Partial killmail has minimal data
    %{
      "killmail_id" => Map.get(overrides, :killmail_id, random_killmail_id()),
      "killmail_time" => "2024-01-01T12:00:00Z",
      "solar_system_id" => Map.get(overrides, :solar_system_id, 30_000_142),
      "zkb" => %{
        "hash" => "partial_#{:rand.uniform(999_999)}"
      }
    }
  end

  def build(:raw_killmail, overrides) do
    # Raw killmail is just the JSON structure without processing
    Map.merge(
      %{
        "killmail_id" => random_killmail_id(),
        "killmail_time" => "2024-01-01T12:00:00Z",
        "solar_system_id" => 30_000_142,
        "victim" => %{
          "character_id" => 95_465_499,
          "ship_type_id" => 587
        },
        "attackers" => [
          %{"character_id" => 95_465_500}
        ]
      },
      overrides
    )
  end
end
