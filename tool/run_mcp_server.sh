#!/usr/bin/env bash
# Convenience wrapper for MCP clients that prefer a single executable path.
# Usage: tool/run_mcp_server.sh [serve|mcp|token|status|import ...]
set -euo pipefail
cd "$(dirname "$0")/.."
exec dart mcp_server/bin/ota_sync_server.dart "$@"
