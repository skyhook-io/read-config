#!/usr/bin/env bash
# Parse a Skyhook config file and emit GitHub Actions-style outputs.
#
# Inputs (env):
#   WORKING_DIR    - repo root containing the config (default ".")
#   SERVICE_NAME   - service to look up (required, non-empty)
#   CONFIG_PATH    - path to config relative to WORKING_DIR (default ".skyhook/skyhook.yaml")
#   GITHUB_OUTPUT  - file to append outputs to (required by GitHub Actions; tests pass a tempfile)
#
# Exits non-zero with ::error:: on:
#   - empty SERVICE_NAME
#   - yq parse failure
#   - duplicate service names
#   - unexpected SERVICE_INDEX shape
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

WORKING_DIR="${WORKING_DIR:-.}"
[ -z "$WORKING_DIR" ] && WORKING_DIR="."
WORKING_DIR="${WORKING_DIR%/}"
CONFIG_PATH="${CONFIG_PATH:-.skyhook/skyhook.yaml}"
SERVICE_NAME="${SERVICE_NAME:-}"

if [ -z "$SERVICE_NAME" ]; then
  echo "::error::service_name input is required and must be non-empty"
  exit 1
fi

CONFIG_FILE="${WORKING_DIR}/${CONFIG_PATH}"

# Heredoc-form output write: safe for multiline values, leading/trailing whitespace,
# and values containing literal "=". Generates a unique delimiter per call.
write_output() {
  local key="$1" val="$2"
  local delim
  delim="ghadelim_$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16 || echo "$$_$RANDOM$RANDOM")"
  {
    printf '%s<<%s\n' "$key" "$delim"
    printf '%s\n' "$val"
    printf '%s\n' "$delim"
  } >> "$GITHUB_OUTPUT"
}

write_empty_outputs() {
  write_output name ""
  write_output path ""
  write_output deployment_repo ""
  write_output deployment_repo_path ""
  write_output build_context ""
  write_output dockerfile_path ""
}

# Config file missing
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE"
  write_output config_found false
  write_output service_found false
  write_empty_outputs
  exit 0
fi

write_output config_found true
echo "Found config file: $CONFIG_FILE"

# Look up the service. Use strenv() to inject SERVICE_NAME safely (handles
# names containing literal `"`). Do NOT suppress yq stderr - a malformed YAML
# should surface as a clear parse error, not a silent "service not found".
if ! SERVICE_INDEX=$(SERVICE_NAME="$SERVICE_NAME" yq e \
    '.services | to_entries | .[] | select(.value.name == strenv(SERVICE_NAME)) | .key' \
    "$CONFIG_FILE"); then
  echo "::error::Failed to parse $CONFIG_FILE - check YAML syntax"
  exit 1
fi

if [ -z "$SERVICE_INDEX" ]; then
  echo "Service '$SERVICE_NAME' not found in config"
  write_output service_found false
  write_empty_outputs
  exit 0
fi

# Duplicate service names: yq returns newline-separated indices.
MATCH_COUNT=$(printf '%s\n' "$SERVICE_INDEX" | grep -c .)
if [ "$MATCH_COUNT" -gt 1 ]; then
  INDICES=$(echo "$SERVICE_INDEX" | tr '\n' ',' | sed 's/,$//')
  echo "::error::Multiple services named '$SERVICE_NAME' found in $CONFIG_FILE (indices: $INDICES)"
  exit 1
fi

if ! [[ "$SERVICE_INDEX" =~ ^[0-9]+$ ]]; then
  echo "::error::Unexpected service index from yq: '$SERVICE_INDEX'"
  exit 1
fi

write_output service_found true
echo "Found service '$SERVICE_NAME' at index $SERVICE_INDEX"

SERVICE_PATH=".services[$SERVICE_INDEX]"

NAME=$(yq e "${SERVICE_PATH}.name // \"\"" "$CONFIG_FILE")
PATH_VALUE=$(yq e "${SERVICE_PATH}.path // \"\"" "$CONFIG_FILE")
DEPLOYMENT_REPO=$(yq e "${SERVICE_PATH}.deploymentRepo // \"\"" "$CONFIG_FILE")
DEPLOYMENT_REPO_PATH=$(yq e "${SERVICE_PATH}.deploymentRepoPath // \"\"" "$CONFIG_FILE")
BUILD_CONTEXT=$(yq e "${SERVICE_PATH}.buildTool.docker.buildContext // \"\"" "$CONFIG_FILE")
DOCKERFILE_PATH=$(yq e "${SERVICE_PATH}.buildTool.docker.dockerfilePath // \"\"" "$CONFIG_FILE")

# yq v4 with `// ""` returns "" for missing/null; the "null" string post-checks
# below are defensive guards in case yq behaviour shifts.
[ "$NAME" = "null" ] && NAME=""
[ "$PATH_VALUE" = "null" ] && PATH_VALUE=""
[ "$DEPLOYMENT_REPO" = "null" ] && DEPLOYMENT_REPO=""
[ "$DEPLOYMENT_REPO_PATH" = "null" ] && DEPLOYMENT_REPO_PATH=""
[ "$BUILD_CONTEXT" = "null" ] && BUILD_CONTEXT=""
[ "$DOCKERFILE_PATH" = "null" ] && DOCKERFILE_PATH=""

# Default build context to "." when absent
[ -z "$BUILD_CONTEXT" ] && BUILD_CONTEXT="."

write_output name "$NAME"
write_output path "$PATH_VALUE"
write_output deployment_repo "$DEPLOYMENT_REPO"
write_output deployment_repo_path "$DEPLOYMENT_REPO_PATH"
write_output build_context "$BUILD_CONTEXT"
write_output dockerfile_path "$DOCKERFILE_PATH"

echo "Parsed service configuration:"
echo "  name: ${NAME}"
echo "  path: ${PATH_VALUE}"
echo "  deployment_repo: ${DEPLOYMENT_REPO}"
echo "  deployment_repo_path: ${DEPLOYMENT_REPO_PATH}"
echo "  build_context: ${BUILD_CONTEXT}"
echo "  dockerfile_path: ${DOCKERFILE_PATH}"
