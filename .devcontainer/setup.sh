#!/usr/bin/env bash
set -e

echo "→ fetching & compiling deps"
mix deps.get
mix compile

# only run Ecto if the project actually has those tasks
if mix help | grep -q "ecto.create"; then
  echo "→ running ecto.create && ecto.migrate"
  mix ecto.create --quiet
  mix ecto.migrate
fi

# only run assets.setup if defined
if mix help | grep -q "assets.setup"; then
  echo "→ running assets.setup"
  mix assets.setup
fi

echo "✅ setup complete"
