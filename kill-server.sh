#!/usr/bin/env bash
set -euo pipefail

# Usage: kill-server.sh [port]
# Defaults to port 8080 when no argument provided.

PORT="${1:-8080}"

# Find PIDs listening on the port (macOS / Linux compatible with lsof)
PIDS=$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)

if [ -z "${PIDS}" ]; then
	echo "No process listening on port ${PORT}"
	exit 0
fi

echo "Found process(es) listening on port ${PORT}: ${PIDS}"
echo "Attempting graceful kill..."
sudo kill ${PIDS} || true
sleep 1

# If any remain, force kill
STILL=$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true)
if [ -n "${STILL}" ]; then
	echo "Processes still running; forcing kill: ${STILL}"
	sudo kill -9 ${STILL} || true
fi

echo "Done."

