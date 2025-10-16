# Debug Commands for Websocket Kill Streaming

## Check if kills are being received from zKillboard

```elixir
# Get RedisQ statistics to see if kills are coming in
WandererKills.Ingest.RedisQ.get_stats()

# Force a manual RedisQ poll
WandererKills.Ingest.RedisQ.poll_and_process()
```

## Check websocket subscriptions

```elixir
# List all active subscriptions
WandererKills.Subs.SimpleSubscriptionManager.list_subscriptions()

# Filter to show only websocket subscriptions
WandererKills.Subs.SimpleSubscriptionManager.list_subscriptions()
|> Enum.filter(&(&1.type == :websocket))

# Get subscription statistics
WandererKills.Subs.SimpleSubscriptionManager.get_stats()

# Get websocket-specific statistics
WandererKillsWeb.KillmailChannel.get_stats()
```

## Monitor PubSub broadcasts

```elixir
# Subscribe to a specific system's broadcasts (replace 30000142 with your system ID)
Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:system:30000142")

# Subscribe to detailed system broadcasts
Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:system:30000142:detailed")

# Subscribe to all systems (for character-only subscriptions)
Phoenix.PubSub.subscribe(WandererKills.PubSub, "killmails:all_systems")

# After subscribing, wait for messages - you should see broadcasts when kills happen
# Messages will appear in your IEx session when kills are broadcast
```

## Enable debug logging

```elixir
# Enable debug logging (will be very spammy)
Logger.configure(level: :debug)

# Reset to info level to reduce spam
Logger.configure(level: :info)
```

## Check if specific kills are being processed

With the logging added to RedisQ, you should see info-level messages like:
```
[RedisQ] Kill received killmail_id=123456 system_id=30000142 timestamp=2025-08-01T06:52:24Z
```

## Troubleshooting workflow

1. **Check if kills are coming in**: Run `WandererKills.Ingest.RedisQ.get_stats()` - look for `kills_processed` > 0
2. **Check subscriptions**: Run websocket subscription commands to see what systems/characters are subscribed
3. **Monitor broadcasts**: Subscribe to PubSub topics for your systems and see if messages come through
4. **Compare system IDs**: Match the system IDs from kill logs with your subscription system IDs

## Common issues

- **No kills received**: RedisQ not receiving from zKillboard
- **Kills received but no broadcasts**: Problem with PubSub broadcasting
- **Broadcasts but no websocket delivery**: Problem with websocket channel filtering or subscription matching
- **System ID mismatch**: Websocket subscribed to different systems than where kills are happening