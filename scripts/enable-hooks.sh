#!/bin/sh
# cursor-governance-managed:1.0.0
# Idempotent. Does not replace an existing hooks path such as Husky.
current=$(git config --local --get core.hooksPath || true)
if [ -z "$current" ]; then
  git config --local core.hooksPath .githooks
fi
if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$(command -v python3)" "$HOME/.local/bin/python"
fi
