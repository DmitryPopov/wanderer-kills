#!/bin/bash
# Script to start Phoenix server with proper logging for CI debugging

# Ensure script fails on error
set -e

# Function to cleanup on exit
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "Stopping server (PID: $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Start the Phoenix server with output captured
echo "Starting Phoenix server..."
MIX_ENV="${MIX_ENV:-dev}" elixir --erl "-kernel shell_history enabled" -S mix phx.server 2>&1 | tee server.log &
SERVER_PID=$!

echo "Server started with PID: $SERVER_PID"
echo "Waiting for server to be ready..."

# Wait a bit for initial startup
sleep 5

# Check if the process is still running
if ! ps -p $SERVER_PID > /dev/null; then
    echo "❌ Server process died during startup!"
    echo "=== Server output ==="
    cat server.log
    echo "=== End server output ==="
    exit 1
fi

# Wait for the server to be ready
max_attempts=30
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if curl -f -s http://localhost:4004/api/openapi > /dev/null 2>&1; then
        echo "✅ Server is ready after $((attempt + 1)) attempts!"
        exit 0
    fi
    
    # Check if process is still alive
    if ! ps -p $SERVER_PID > /dev/null; then
        echo "❌ Server process died while waiting!"
        echo "=== Server output ==="
        cat server.log
        echo "=== End server output ==="
        exit 1
    fi
    
    attempt=$((attempt + 1))
    echo "Attempt $attempt/$max_attempts - Server not ready yet, waiting..."
    
    # Show last few lines of log every 10 attempts
    if [ $((attempt % 10)) -eq 0 ]; then
        echo "=== Recent server output ==="
        tail -n 20 server.log
        echo "=== End recent output ==="
    fi
    
    sleep 2
done

echo "❌ Server failed to start after $max_attempts attempts"
echo "=== Full server output ==="
cat server.log
echo "=== End server output ==="
exit 1