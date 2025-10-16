defmodule WandererKills.SSE.EventFormatter do
  @moduledoc """
  Formats events for Server-Sent Events (SSE) streaming.

  This module provides consistent formatting for different types of SSE events,
  including connection status, historical data batches, real-time killmails,
  heartbeats, and error notifications.
  """

  @doc """
  Formats an event with the specified type and data.

  ## Parameters
  - `type` - The event type as an atom
  - `data` - The data to be JSON encoded

  ## Returns
  A map with :event and :data keys suitable for SSE transmission
  """
  @spec format_event(atom(), map()) :: map()
  def format_event(type, data) do
    %{
      event: to_string(type),
      data: Jason.encode!(data)
    }
  end

  @doc """
  Creates a connection confirmation event.

  ## Parameters
  - `filters` - The active filters for this connection

  ## Returns
  Formatted SSE event indicating successful connection
  """
  @spec connected_event(map()) :: map()
  def connected_event(filters) do
    format_event(:connected, %{
      status: "connected",
      filters: filters,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Creates a batch event for historical killmails.

  ## Parameters
  - `kills` - List of killmail data
  - `batch_info` - Map with :number and :total keys

  ## Returns
  Formatted SSE event containing a batch of historical killmails
  """
  @spec batch_event([map()], map()) :: map()
  def batch_event(kills, batch_info) do
    format_event(:batch, %{
      kills: kills,
      count: length(kills),
      batch_number: batch_info.number,
      total_batches: batch_info.total
    })
  end

  @doc """
  Creates a transition event indicating switch from historical to real-time mode.

  ## Parameters
  - `total_historical` - Total number of historical killmails sent

  ## Returns
  Formatted SSE event marking the transition to real-time streaming
  """
  @spec transition_event(non_neg_integer()) :: map()
  def transition_event(total_historical) do
    format_event(:transition, %{
      status: "historical_complete",
      total_historical: total_historical,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Creates a heartbeat event.

  ## Parameters
  - `mode` - Current streaming mode (:historical or :realtime)

  ## Returns
  Formatted SSE heartbeat event
  """
  @spec heartbeat_event(atom()) :: map()
  def heartbeat_event(mode) do
    format_event(:heartbeat, %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      mode: to_string(mode)
    })
  end

  @doc """
  Creates an error event.

  ## Parameters
  - `error_type` - Type of error as an atom
  - `message` - Human-readable error message

  ## Returns
  Formatted SSE error event
  """
  @spec error_event(atom(), String.t()) :: map()
  def error_event(error_type, message) do
    format_event(:error, %{
      type: to_string(error_type),
      message: message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Creates a killmail event for real-time updates.

  ## Parameters
  - `killmail` - The killmail data

  ## Returns
  Formatted SSE event containing a single killmail
  """
  @spec killmail_event(map()) :: map()
  def killmail_event(killmail) do
    format_event(:killmail, killmail)
  end
end
