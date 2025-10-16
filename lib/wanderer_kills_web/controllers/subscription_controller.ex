defmodule WandererKillsWeb.SubscriptionController do
  @moduledoc """
  HTTP API controller for managing killmail webhook subscriptions.

  Supports subscribing to killmails by:
  - System IDs - receive all kills in specified systems
  - Character IDs - receive kills where character is victim or attacker
  - Both - receive kills matching either criteria
  """

  use WandererKillsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias WandererKills.Core.Support.Error
  alias WandererKills.Subs.SimpleSubscriptionManager

  operation(:create,
    summary: "Create webhook subscription",
    description: "Create a new webhook subscription for killmail notifications",
    request_body:
      {"Request body", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           subscriber_id: %OpenApiSpex.Schema{
             type: :string,
             description: "Unique identifier for the subscriber",
             example: "user123"
           },
           system_ids: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :integer},
             description: "List of EVE Online system IDs",
             example: [30_000_142, 30_000_143]
           },
           character_ids: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :integer},
             description: "List of EVE Online character IDs",
             example: [95_465_499, 90_379_338]
           },
           callback_url: %OpenApiSpex.Schema{
             type: :string,
             format: :uri,
             description: "HTTP/HTTPS URL to receive webhook notifications",
             example: "https://example.com/webhook"
           }
         },
         required: [:subscriber_id, :callback_url]
       }},
    responses: %{
      201 => {"Success", "application/json", WandererKillsWeb.Schemas.SubscriptionResponse},
      400 => {"Invalid parameters", "application/json", WandererKillsWeb.Schemas.Error}
    }
  )

  @doc """
  Create a new webhook subscription.

  ## Request body:
  ```json
  {
    "subscriber_id": "user123",
    "system_ids": [30000142, 30000143],
    "character_ids": [95465499, 90379338],
    "callback_url": "https://example.com/webhook"
  }
  ```

  At least one of system_ids or character_ids must be provided.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    with {:ok, attrs} <- validate_create_params(params),
         {:ok, subscription_id} <- SimpleSubscriptionManager.add_subscription(attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          subscription_id: subscription_id,
          message: "Subscription created successfully"
        }
      })
    else
      {:error, reason} ->
        message =
          case reason do
            %Error{} -> Error.to_string(reason)
            binary when is_binary(binary) -> binary
            _ -> inspect(reason)
          end

        # Ensure details field is JSON-serializable
        details = serialize_error_details(reason)

        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            message: message,
            details: details
          }
        })
    end
  end

  operation(:index,
    summary: "List all subscriptions",
    description: "Returns a list of all active webhook subscriptions",
    responses: %{
      200 => {"Success", "application/json", WandererKillsWeb.Schemas.SubscriptionListResponse}
    }
  )

  @doc """
  List all active subscriptions.

  Returns an array of subscription objects.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    subscriptions = SimpleSubscriptionManager.list_subscriptions()

    # Convert structs to maps for JSON serialization
    subscription_maps =
      Enum.map(subscriptions, fn sub ->
        %{
          id: sub.id,
          subscriber_id: sub.subscriber_id,
          type: sub.type,
          system_ids: sub.system_ids,
          character_ids: sub.character_ids,
          callback_url: sub.callback_url,
          created_at: sub.created_at,
          updated_at: sub.updated_at
        }
      end)

    conn
    |> json(%{
      data: %{
        subscriptions: subscription_maps,
        count: length(subscriptions)
      }
    })
  end

  operation(:stats,
    summary: "Get subscription statistics",
    description: "Returns aggregate information and statistics about subscriptions",
    responses: %{
      200 => {"Success", "application/json", WandererKillsWeb.Schemas.SubscriptionStatsResponse}
    }
  )

  @doc """
  Get subscription statistics.

  Returns counts and aggregate information about subscriptions.
  """
  @spec stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stats(conn, _params) do
    stats = SimpleSubscriptionManager.get_stats()

    conn
    |> json(%{
      data: stats
    })
  end

  operation(:delete,
    summary: "Delete subscriber subscriptions",
    description: "Delete all subscriptions for a specific subscriber",
    parameters: [
      subscriber_id: [
        in: :path,
        description: "Subscriber ID to unsubscribe",
        type: :string,
        required: true,
        example: "user123"
      ]
    ],
    responses: %{
      200 => {"Success", "application/json", WandererKillsWeb.Schemas.SubscriptionDeleteResponse},
      400 => {"Partial failure", "application/json", WandererKillsWeb.Schemas.Error}
    }
  )

  @doc """
  Delete all subscriptions for a subscriber.

  Unsubscribes the subscriber from all killmail notifications.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"subscriber_id" => subscriber_id}) do
    case SimpleSubscriptionManager.unsubscribe(subscriber_id) do
      :ok ->
        conn
        |> json(%{
          data: %{
            message: "Successfully unsubscribed",
            subscriber_id: subscriber_id
          }
        })

      {:error, :partial_failure} ->
        message = "Some subscriptions could not be removed"

        # Ensure details field is JSON-serializable
        details = serialize_error_details(:partial_failure)

        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            message: message,
            details: details
          }
        })
    end
  end

  # Private functions

  defp validate_create_params(params) do
    attrs = normalize_subscription_attrs(params)

    # Use a validation pipeline with early exit
    [
      &validate_required_fields/1,
      &validate_field_formats/1,
      &validate_business_rules/1
    ]
    |> run_validation_pipeline(attrs)
  end

  # Pipeline runner that stops at first error
  defp run_validation_pipeline(validators, attrs) do
    Enum.reduce_while(validators, {:ok, attrs}, fn validator, {:ok, attrs} ->
      case validator.(attrs) do
        :ok -> {:cont, {:ok, attrs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Normalize and clean input attributes
  defp normalize_subscription_attrs(params) do
    %{
      "subscriber_id" => params["subscriber_id"],
      "system_ids" => normalize_ids(params["system_ids"]),
      "character_ids" => normalize_ids(params["character_ids"]),
      "callback_url" => params["callback_url"]
    }
  end

  # Group related validations together
  defp validate_required_fields(attrs) do
    with :ok <- validate_required_subscriber_id(attrs["subscriber_id"]),
         :ok <- validate_required_callback_url(attrs["callback_url"]) do
      :ok
    end
  end

  defp validate_field_formats(attrs) do
    with :ok <- validate_callback_url_format(attrs["callback_url"]),
         :ok <- validate_ids_format(attrs["system_ids"], "system_ids"),
         :ok <- validate_ids_format(attrs["character_ids"], "character_ids") do
      :ok
    end
  end

  defp validate_business_rules(attrs) do
    with :ok <- validate_at_least_one_id(attrs),
         :ok <- validate_ids_count(attrs["system_ids"], "system_ids", 100),
         :ok <- validate_ids_count(attrs["character_ids"], "character_ids", 1000) do
      :ok
    end
  end

  defp validate_required_subscriber_id(nil), do: {:error, "subscriber_id is required"}
  defp validate_required_subscriber_id(""), do: {:error, "subscriber_id is required"}
  defp validate_required_subscriber_id(_), do: :ok

  defp validate_required_callback_url(nil), do: {:error, "callback_url is required"}
  defp validate_required_callback_url(""), do: {:error, "callback_url is required"}
  defp validate_required_callback_url(_), do: :ok

  defp validate_callback_url_format(url) do
    if valid_url?(url) do
      :ok
    else
      {:error, "callback_url must be a valid HTTP/HTTPS URL"}
    end
  end

  defp validate_at_least_one_id(attrs) do
    if Enum.empty?(attrs["system_ids"]) and Enum.empty?(attrs["character_ids"]) do
      {:error, "At least one system_id or character_id is required"}
    else
      :ok
    end
  end

  defp validate_ids_format(ids, field_name) do
    if valid_ids?(ids) do
      :ok
    else
      {:error, "#{field_name} must be an array of positive integers"}
    end
  end

  defp validate_ids_count(ids, field_name, max_count) do
    if length(ids) > max_count do
      {:error, "Maximum #{max_count} #{field_name} allowed per subscription"}
    else
      :ok
    end
  end

  defp normalize_ids(nil), do: []

  defp normalize_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_ids(_), do: []

  defp valid_ids?(ids) do
    is_list(ids) and Enum.all?(ids, fn id -> is_integer(id) and id > 0 end)
  end

  defp valid_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  # Converts error reasons to JSON-serializable format
  defp serialize_error_details(reason) do
    case reason do
      %Error{} = error ->
        # Include structured error information for Error structs
        %{
          domain: error.domain,
          type: error.type,
          message: Error.to_string(error),
          retryable: error.retryable
        }

      binary when is_binary(binary) ->
        binary

      atom when is_atom(atom) ->
        Atom.to_string(atom)

      _ ->
        inspect(reason)
    end
  end
end
