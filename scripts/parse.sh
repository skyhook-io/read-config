#!/usr/bin/env bash
# Parse a Skyhook config file and emit GitHub Actions-style outputs.
#
# Inputs (env):
#   WORKING_DIR             - repo root containing the config (default ".")
#   SERVICE_NAME            - service to look up (required, non-empty)
#   CONFIG_PATH             - path to config relative to WORKING_DIR (default ".skyhook/skyhook.yaml")
#   DEFAULT_BUILD_CONTEXT   - REQUIRED. Emitted as build_context when YAML omits it OR when
#                             config/service is not found. The action does not pick a default
#                             for the caller; this is intentional so callers must opt in.
#   DEFAULT_DOCKERFILE_PATH - REQUIRED. Same contract as DEFAULT_BUILD_CONTEXT, for dockerfile_path.
#   INCLUDE_ENV             - "true" to additionally emit the `environments` block from the local
#                             config as the `environments` output. Anything else (including unset)
#                             is treated as false. When "true" and the local config has no
#                             `environments` block (or the file is missing), the script exits 1
#                             with "Not supported yet" - external-repo support is not implemented.
#   GIT_TOKEN               - Reserved for the future external-repo path. Currently unused.
#   GITHUB_OUTPUT           - file to append outputs to (required by GitHub Actions; tests pass a tempfile)
#
# Exits non-zero with ::error:: on:
#   - empty SERVICE_NAME
#   - DEFAULT_BUILD_CONTEXT or DEFAULT_DOCKERFILE_PATH unset (note: unset != empty;
#     unset catches "the input was never wired in action.yml")
#   - any time a default would be applied (YAML absent OR config/service not found)
#     and the corresponding default input is empty - the action refuses to emit
#     empty build_context / dockerfile_path because downstream `docker build` would
#     fail with a cryptic error. Uniform rule: defaults must be non-empty whenever
#     they're needed.
#   - yq parse failure
#   - duplicate service names
#   - unexpected SERVICE_INDEX shape
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
: "${DEFAULT_BUILD_CONTEXT?DEFAULT_BUILD_CONTEXT must be set (wire the default_build_context input)}"
: "${DEFAULT_DOCKERFILE_PATH?DEFAULT_DOCKERFILE_PATH must be set (wire the default_dockerfile_path input)}"

WORKING_DIR="${WORKING_DIR:-.}"
[ -z "$WORKING_DIR" ] && WORKING_DIR="."
WORKING_DIR="${WORKING_DIR%/}"
CONFIG_PATH="${CONFIG_PATH:-.skyhook/skyhook.yaml}"
SERVICE_NAME="${SERVICE_NAME:-}"
INCLUDE_ENV="${INCLUDE_ENV:-false}"

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

# Used when no service was matched (config missing OR service missing).
# Identity fields stay empty (no service to describe), but build_context and
# dockerfile_path are populated from the caller-supplied defaults so downstream
# steps can still construct a path. Consumers who care about the difference
# should branch on config_found / service_found.
write_unmatched_outputs() {
  write_output name ""
  write_output path ""
  write_output deployment_repo ""
  write_output deployment_repo_path ""
  write_output build_context "$DEFAULT_BUILD_CONTEXT"
  write_output dockerfile_path "$DEFAULT_DOCKERFILE_PATH"
}

# Refuse to emit an empty value for a SINGLE field. Used in the per-field
# YAML-absent path where we already know which field needs a default.
#
# `which`: human-readable label for the field whose default is about to be used.
#          One of "build_context" or "dockerfile_path".
require_nonempty_default() {
  local which="$1" reason="$2" value="$3"
  if [ -z "$value" ]; then
    echo "::error::${reason}, but default_${which} input is empty. Provide a non-empty value so the action can emit a usable ${which}."
    exit 1
  fi
}

# Refuse to emit empty values when BOTH defaults are about to be applied (config
# missing or service missing - we know up front we'll need both). Lists every
# empty input in a single error so the caller can fix them all at once instead
# of fail-then-fail-again.
require_nonempty_defaults_for_unmatched() {
  local reason="$1"
  local missing=()
  [ -z "$DEFAULT_BUILD_CONTEXT" ]   && missing+=("default_build_context")
  [ -z "$DEFAULT_DOCKERFILE_PATH" ] && missing+=("default_dockerfile_path")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error::${reason}, but the following required input(s) are empty: ${missing[*]}. Provide non-empty values so the action can emit usable build_context / dockerfile_path."
    exit 1
  fi
}

# Emit (or refuse to emit) the `environments` output. Safe to call from any
# exit path that has confirmed CONFIG_FILE exists, OR from the empty-on-disable
# case (INCLUDE_ENV != "true").
#
# Contract:
#   - INCLUDE_ENV != "true" -> emit empty string (the default; backwards-compatible).
#   - INCLUDE_ENV == "true" + `environments` block present -> emit it as YAML (heredoc form
#     preserves multi-line structure across $GITHUB_OUTPUT).
#   - INCLUDE_ENV == "true" + `environments` block absent  -> exit 1 "Not supported yet"
#     (external-repo lookup via GIT_TOKEN is reserved for a future release).
emit_environments() {
  if [ "$INCLUDE_ENV" != "true" ]; then
    write_output environments ""
    echo "  environments: skipped (include_env=${INCLUDE_ENV})"
    return 0
  fi
  # Detect "no environments" structurally via yq's tag, not by string-matching
  # the value: YAML has four null spellings (null / Null / NULL / ~), plus a
  # bare key with no value (also null), plus an outright-missing key. yq's
  # tag is `!!null` in all of those cases; anything else means the key was
  # explicitly set to a value (including `[]`, which passes through verbatim
  # per the user spec - if `environments` is in the yaml, return it).
  local env_tag environments
  if ! env_tag=$(yq e '.environments | tag' "$CONFIG_FILE"); then
    echo "::error::Failed to parse $CONFIG_FILE while reading 'environments'"
    exit 1
  fi
  if [ "$env_tag" = "!!null" ]; then
    echo "::error::include_env=true but no 'environments' block in '${CONFIG_FILE}' - Not supported yet (external-repo environments source is not implemented; git_token is reserved for that future path)"
    exit 1
  fi
  if ! environments=$(yq e '.environments' "$CONFIG_FILE"); then
    echo "::error::Failed to parse $CONFIG_FILE while reading 'environments'"
    exit 1
  fi
  write_output environments "$environments"
  echo "  environments: emitted (include_env=true, tag=${env_tag})"
}

# Config file missing
if [ ! -f "$CONFIG_FILE" ]; then
  # include_env=true means the caller wants the environments block from the local file.
  # No local file -> there's nothing to return, and the external-repo path is not built yet.
  if [ "$INCLUDE_ENV" = "true" ]; then
    echo "::error::include_env=true but the local config file '${CONFIG_FILE}' is missing - Not supported yet (external-repo environments source is not implemented)"
    exit 1
  fi
  echo "Config file not found: $CONFIG_FILE"
  require_nonempty_defaults_for_unmatched "Config file not found at '${CONFIG_FILE}'"
  echo "::warning::Config file not found - emitting build_context='${DEFAULT_BUILD_CONTEXT}' and dockerfile_path='${DEFAULT_DOCKERFILE_PATH}' from default_build_context / default_dockerfile_path inputs"
  write_output config_found false
  write_output service_found false
  write_unmatched_outputs
  # Safe: INCLUDE_ENV is guaranteed != "true" here (fail-fast above caught the true case),
  # so emit_environments will just write an empty string.
  emit_environments
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
  require_nonempty_defaults_for_unmatched "Service '${SERVICE_NAME}' not found in '${CONFIG_FILE}'"
  echo "::warning::Service '${SERVICE_NAME}' not found - emitting build_context='${DEFAULT_BUILD_CONTEXT}' and dockerfile_path='${DEFAULT_DOCKERFILE_PATH}' from default_build_context / default_dockerfile_path inputs"
  write_output service_found false
  write_unmatched_outputs
  emit_environments
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

# Apply caller-supplied defaults when YAML omitted the value (or set it to ""/null).
# Uniform rule: if a default is needed and the input is empty, fail. We log the
# default-applied case as a notice so users can see in the action output that
# the value came from the input default and NOT from their config file.
if [ -z "$BUILD_CONTEXT" ]; then
  require_nonempty_default build_context "buildTool.docker.buildContext absent for service '${SERVICE_NAME}'" "$DEFAULT_BUILD_CONTEXT"
  echo "::notice::buildTool.docker.buildContext absent for '${SERVICE_NAME}' - using default_build_context='${DEFAULT_BUILD_CONTEXT}'"
  BUILD_CONTEXT="$DEFAULT_BUILD_CONTEXT"
fi
if [ -z "$DOCKERFILE_PATH" ]; then
  require_nonempty_default dockerfile_path "buildTool.docker.dockerfilePath absent for service '${SERVICE_NAME}'" "$DEFAULT_DOCKERFILE_PATH"
  echo "::notice::buildTool.docker.dockerfilePath absent for '${SERVICE_NAME}' - using default_dockerfile_path='${DEFAULT_DOCKERFILE_PATH}'"
  DOCKERFILE_PATH="$DEFAULT_DOCKERFILE_PATH"
fi

write_output name "$NAME"
write_output path "$PATH_VALUE"
write_output deployment_repo "$DEPLOYMENT_REPO"
write_output deployment_repo_path "$DEPLOYMENT_REPO_PATH"
write_output build_context "$BUILD_CONTEXT"
write_output dockerfile_path "$DOCKERFILE_PATH"
emit_environments

echo "Parsed service configuration:"
echo "  name: ${NAME}"
echo "  path: ${PATH_VALUE}"
echo "  deployment_repo: ${DEPLOYMENT_REPO}"
echo "  deployment_repo_path: ${DEPLOYMENT_REPO_PATH}"
echo "  build_context: ${BUILD_CONTEXT}"
echo "  dockerfile_path: ${DOCKERFILE_PATH}"
# Note: the environments log line is emitted by emit_environments() above so it
# also fires on the early-exit paths (config-missing, service-not-found).
