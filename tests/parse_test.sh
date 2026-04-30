#!/usr/bin/env bash
# Exercises scripts/parse.sh directly with a temp $GITHUB_OUTPUT, so the test
# fails if the real action's parsing logic regresses.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSE_SCRIPT="${REPO_ROOT}/scripts/parse.sh"
ACTION_FILE="${REPO_ROOT}/action.yml"

if ! command -v yq &>/dev/null; then
  echo "SKIP: yq not installed; install via 'brew install yq' or download from mikefarah/yq"
  exit 0
fi

# Require yq v4 (parse.sh uses v4 syntax)
if ! yq --version 2>&1 | grep -qE 'version v?4\.'; then
  echo "SKIP: yq is not v4.x: $(yq --version 2>&1)"
  exit 0
fi

if [ ! -x "$PARSE_SCRIPT" ]; then
  echo "FAIL: $PARSE_SCRIPT not found or not executable"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CONFIG_DIR="$WORK/.skyhook"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/skyhook.yaml"

cat >"$CONFIG_FILE" <<'YAML'
services:
  - name: with-context
    path: java-web-project
    deploymentRepo: KoalaOps/deployment
    deploymentRepoPath: nbjkgj
    buildTool:
      docker:
        buildContext: java-web-project/src
        dockerfilePath: java-web-project/src/Dockerfile
  - name: no-context
    path: java-multi-modules
    deploymentRepo: skyhook-dev/deployment
    deploymentRepoPath: nbjkgj
    buildTool:
      docker:
        dockerfilePath: java-multi-modules/Dockerfile
  - name: explicit-null
    path: svc-null
    buildTool:
      docker:
        buildContext: null
        dockerfilePath: svc-null/Dockerfile
  - name: empty-string
    path: svc-empty
    buildTool:
      docker:
        buildContext: ""
        dockerfilePath: svc-empty/Dockerfile
  - name: with-spaces
    path: "services/with spaces/sub"
    buildTool:
      docker:
        buildContext: "services/with spaces/sub"
        dockerfilePath: "services/with spaces/sub/Dockerfile"
  - name: 'name-with-"-quote'
    path: svc-quote
    buildTool:
      docker:
        dockerfilePath: svc-quote/Dockerfile
YAML

# Read a single output value from a $GITHUB_OUTPUT file written in heredoc form.
# The heredoc form is:  KEY<<DELIM\nVALUE...\nDELIM\n
read_output() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { capturing = 0; delim = "" }
    capturing && $0 == delim { capturing = 0; next }
    capturing { if (out != "") out = out "\n"; out = out $0; next }
    {
      idx = index($0, "<<")
      if (idx > 0 && substr($0, 1, idx - 1) == key) {
        delim = substr($0, idx + 2)
        capturing = 1
        out = ""
      }
    }
    END { print out }
  ' "$file"
}

run_parse() {
  local working_dir="$1" svc="$2" cfg_path="${3:-.skyhook/skyhook.yaml}"
  local out_file
  out_file="$WORK/gh_output.$RANDOM"
  : >"$out_file"
  WORKING_DIR="$working_dir" \
  SERVICE_NAME="$svc" \
  CONFIG_PATH="$cfg_path" \
  GITHUB_OUTPUT="$out_file" \
    bash "$PARSE_SCRIPT" >/dev/null
  echo "$out_file"
}

run_parse_expect_fail() {
  local working_dir="$1" svc="$2" cfg_path="${3:-.skyhook/skyhook.yaml}"
  local out_file err_file
  out_file="$WORK/gh_output.$RANDOM"
  err_file="$WORK/gh_err.$RANDOM"
  : >"$out_file"
  if WORKING_DIR="$working_dir" \
     SERVICE_NAME="$svc" \
     CONFIG_PATH="$cfg_path" \
     GITHUB_OUTPUT="$out_file" \
     bash "$PARSE_SCRIPT" >"$err_file" 2>&1; then
    echo "EXPECTED-FAIL-DID-NOT-FAIL"
    cat "$err_file"
    return
  fi
  cat "$err_file"
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL ($label): got '$got' want '$want'"
    exit 1
  fi
  echo "PASS: $label"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo "FAIL ($label): output does not contain '$needle'"
    echo "--- output ---"
    echo "$haystack"
    echo "---"
    exit 1
  fi
  echo "PASS: $label"
}

# --- happy path: buildContext present ---
out=$(run_parse "$WORK" with-context)
assert_eq "$(read_output "$out" config_found)" "true" "with-context: config_found=true"
assert_eq "$(read_output "$out" service_found)" "true" "with-context: service_found=true"
assert_eq "$(read_output "$out" name)" "with-context" "with-context: name"
assert_eq "$(read_output "$out" path)" "java-web-project" "with-context: path"
assert_eq "$(read_output "$out" deployment_repo)" "KoalaOps/deployment" "with-context: deployment_repo"
assert_eq "$(read_output "$out" deployment_repo_path)" "nbjkgj" "with-context: deployment_repo_path"
assert_eq "$(read_output "$out" build_context)" "java-web-project/src" "with-context: build_context"
assert_eq "$(read_output "$out" dockerfile_path)" "java-web-project/src/Dockerfile" "with-context: dockerfile_path"

# --- buildContext absent => default "." ---
out=$(run_parse "$WORK" no-context)
assert_eq "$(read_output "$out" build_context)" "." "no-context: build_context defaults to '.'"
assert_eq "$(read_output "$out" dockerfile_path)" "java-multi-modules/Dockerfile" "no-context: dockerfile_path"
assert_eq "$(read_output "$out" deployment_repo)" "skyhook-dev/deployment" "no-context: deployment_repo"

# --- buildContext: null => default "." ---
out=$(run_parse "$WORK" explicit-null)
assert_eq "$(read_output "$out" build_context)" "." "explicit-null: build_context defaults to '.'"

# --- buildContext: "" => default "." ---
out=$(run_parse "$WORK" empty-string)
assert_eq "$(read_output "$out" build_context)" "." "empty-string: build_context defaults to '.'"

# --- value with spaces survives heredoc round-trip ---
out=$(run_parse "$WORK" with-spaces)
assert_eq "$(read_output "$out" path)" "services/with spaces/sub" "with-spaces: path preserves spaces"
assert_eq "$(read_output "$out" build_context)" "services/with spaces/sub" "with-spaces: build_context preserves spaces"

# --- service_name with literal quote: should still resolve via strenv() ---
out=$(run_parse "$WORK" 'name-with-"-quote')
assert_eq "$(read_output "$out" service_found)" "true" "quoted service name resolves"
assert_eq "$(read_output "$out" path)" "svc-quote" "quoted service name: path"

# --- service not found ---
out=$(run_parse "$WORK" nonexistent-service)
assert_eq "$(read_output "$out" config_found)" "true" "missing service: config_found=true"
assert_eq "$(read_output "$out" service_found)" "false" "missing service: service_found=false"
assert_eq "$(read_output "$out" build_context)" "" "missing service: build_context empty (asymmetry)"

# --- config file missing ---
out=$(run_parse "$WORK/no-such-dir" any-service)
assert_eq "$(read_output "$out" config_found)" "false" "missing config: config_found=false"
assert_eq "$(read_output "$out" service_found)" "false" "missing config: service_found=false"
assert_eq "$(read_output "$out" build_context)" "" "missing config: build_context empty"

# --- empty service_name ---
err=$(run_parse_expect_fail "$WORK" "")
assert_contains "$err" "service_name input is required and must be non-empty" "empty service_name errors"

# --- duplicate service names ---
DUP_DIR="$WORK/dup"
mkdir -p "$DUP_DIR/.skyhook"
cat >"$DUP_DIR/.skyhook/skyhook.yaml" <<'YAML'
services:
  - name: dup
    path: a
  - name: dup
    path: b
YAML
err=$(run_parse_expect_fail "$DUP_DIR" "dup")
assert_contains "$err" "Multiple services named 'dup'" "duplicate service names error"

# --- malformed YAML ---
BAD_DIR="$WORK/bad"
mkdir -p "$BAD_DIR/.skyhook"
cat >"$BAD_DIR/.skyhook/skyhook.yaml" <<'YAML'
services:
  - name: ok
    path: [unterminated
YAML
err=$(run_parse_expect_fail "$BAD_DIR" "ok")
assert_contains "$err" "Failed to parse" "malformed YAML errors loudly"

# --- empty WORKING_DIR collapses to "." (uses cwd, not "/") ---
TMP_CWD="$WORK/cwd-test"
mkdir -p "$TMP_CWD/.skyhook"
cat >"$TMP_CWD/.skyhook/skyhook.yaml" <<'YAML'
services:
  - name: cwd-svc
    path: x
YAML
out_file="$WORK/gh_output.cwd"
: >"$out_file"
( cd "$TMP_CWD" && WORKING_DIR="" SERVICE_NAME="cwd-svc" CONFIG_PATH=".skyhook/skyhook.yaml" GITHUB_OUTPUT="$out_file" bash "$PARSE_SCRIPT" >/dev/null )
assert_eq "$(read_output "$out_file" service_found)" "true" "empty WORKING_DIR collapses to cwd"

# --- trailing slash on WORKING_DIR is stripped ---
out=$(run_parse "$WORK/" with-context)
assert_eq "$(read_output "$out" service_found)" "true" "trailing slash on WORKING_DIR works"

# --- multiline / "=" / leading space round-trip via heredoc ---
HEREDOC_DIR="$WORK/heredoc"
mkdir -p "$HEREDOC_DIR/.skyhook"
cat >"$HEREDOC_DIR/.skyhook/skyhook.yaml" <<'YAML'
services:
  - name: weird
    path: "  leading-space"
    deploymentRepo: "key=value-equals"
    deploymentRepoPath: "line1\nline2"
    buildTool:
      docker:
        dockerfilePath: "Dockerfile"
YAML
out=$(run_parse "$HEREDOC_DIR" weird)
assert_eq "$(read_output "$out" path)" "  leading-space" "leading whitespace preserved through heredoc"
assert_eq "$(read_output "$out" deployment_repo)" "key=value-equals" "literal '=' preserved through heredoc"
# yq parses double-quoted YAML strings with escape sequences, so "line1\nline2"
# becomes a real two-line value. The heredoc round-trip must preserve the
# embedded newline - this is exactly the multiline output-injection case.
expected_multiline=$'line1\nline2'
assert_eq "$(read_output "$out" deployment_repo_path)" "$expected_multiline" "multiline value round-trips through heredoc"

# --- action.yml structure sanity ---
grep -q 'bash "\$GITHUB_ACTION_PATH/scripts/parse.sh"' "$ACTION_FILE" || { echo "FAIL: action.yml does not call scripts/parse.sh"; exit 1; }
grep -q 'version v?4\\.' "$ACTION_FILE" || { echo "FAIL: action.yml does not validate yq v4"; exit 1; }
grep -q 'v4.47.1' "$ACTION_FILE" || { echo "FAIL: action.yml does not pin yq v4.47.1"; exit 1; }
grep -q "context_path" "$ACTION_FILE" && { echo "FAIL: action.yml still references old context_path"; exit 1; }
grep -q "build_context:" "$ACTION_FILE" || { echo "FAIL: action.yml does not declare build_context output"; exit 1; }
echo "PASS: action.yml delegates to scripts/parse.sh, validates yq v4, pins v4.47.1, no context_path residue"

# --- parse.sh structure sanity ---
grep -q "strenv(SERVICE_NAME)" "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not use strenv() for service_name"; exit 1; }
grep -q "Multiple services named" "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not detect duplicate names"; exit 1; }
grep -q "service_name input is required" "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not validate non-empty service_name"; exit 1; }
grep -q 'Failed to parse' "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not surface yq parse errors"; exit 1; }
grep -q 'BUILD_CONTEXT="\."' "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not default build_context to '.'"; exit 1; }
echo "PASS: parse.sh has strenv, dup-detection, empty-name validation, parse-error surfacing, build_context default"
