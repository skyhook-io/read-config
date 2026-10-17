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

# Sentinel defaults used by most tests. Distinctive strings so a regression
# (e.g. defaults silently leaking when YAML had a real value) is obvious.
DEFAULT_BC="DEFAULT_BC_SENTINEL"
DEFAULT_DF="DEFAULT_DF_SENTINEL"

run_parse() {
  local working_dir="$1" svc="$2" cfg_path="${3:-.skyhook/skyhook.yaml}"
  local out_file
  out_file="$WORK/gh_output.$RANDOM"
  : >"$out_file"
  WORKING_DIR="$working_dir" \
  SERVICE_NAME="$svc" \
  CONFIG_PATH="$cfg_path" \
  DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" \
  DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" \
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
     DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" \
     DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" \
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

# --- buildContext absent => caller-supplied default ---
out=$(run_parse "$WORK" no-context)
assert_eq "$(read_output "$out" build_context)" "$DEFAULT_BC" "no-context: build_context falls back to default_build_context"
assert_eq "$(read_output "$out" dockerfile_path)" "java-multi-modules/Dockerfile" "no-context: dockerfile_path comes from YAML (not default)"
assert_eq "$(read_output "$out" deployment_repo)" "skyhook-dev/deployment" "no-context: deployment_repo"

# --- buildContext: null => caller-supplied default ---
out=$(run_parse "$WORK" explicit-null)
assert_eq "$(read_output "$out" build_context)" "$DEFAULT_BC" "explicit-null: build_context falls back to default_build_context"

# --- buildContext: "" => caller-supplied default ---
out=$(run_parse "$WORK" empty-string)
assert_eq "$(read_output "$out" build_context)" "$DEFAULT_BC" "empty-string: build_context falls back to default_build_context"

# --- defaults must NOT leak when YAML provides a real value (regression guard) ---
out=$(run_parse "$WORK" with-context)
got_bc=$(read_output "$out" build_context)
got_df=$(read_output "$out" dockerfile_path)
if [ "$got_bc" = "$DEFAULT_BC" ] || [ "$got_df" = "$DEFAULT_DF" ]; then
  echo "FAIL: defaults leaked through despite YAML having values (build_context='$got_bc', dockerfile_path='$got_df')"
  exit 1
fi
echo "PASS: with-context: defaults do not override YAML-provided values"

# --- script must fail clearly if DEFAULT_BUILD_CONTEXT is unset ---
out_file="$WORK/gh_output.unset_bc"
err_file="$WORK/gh_err.unset_bc"
: >"$out_file"
set +e
env -u DEFAULT_BUILD_CONTEXT \
  WORKING_DIR="$WORK" \
  SERVICE_NAME="with-context" \
  CONFIG_PATH=".skyhook/skyhook.yaml" \
  DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" \
  GITHUB_OUTPUT="$out_file" \
  bash "$PARSE_SCRIPT" >"$err_file" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: parse.sh succeeded when DEFAULT_BUILD_CONTEXT was unset"
  cat "$err_file"
  exit 1
fi
assert_contains "$(cat "$err_file")" "DEFAULT_BUILD_CONTEXT must be set" "unset DEFAULT_BUILD_CONTEXT errors"

# --- script must fail clearly if DEFAULT_DOCKERFILE_PATH is unset ---
out_file="$WORK/gh_output.unset_df"
err_file="$WORK/gh_err.unset_df"
: >"$out_file"
set +e
env -u DEFAULT_DOCKERFILE_PATH \
  WORKING_DIR="$WORK" \
  SERVICE_NAME="with-context" \
  CONFIG_PATH=".skyhook/skyhook.yaml" \
  DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" \
  GITHUB_OUTPUT="$out_file" \
  bash "$PARSE_SCRIPT" >"$err_file" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: parse.sh succeeded when DEFAULT_DOCKERFILE_PATH was unset"
  cat "$err_file"
  exit 1
fi
assert_contains "$(cat "$err_file")" "DEFAULT_DOCKERFILE_PATH must be set" "unset DEFAULT_DOCKERFILE_PATH errors"

# Invoke parse.sh with explicit default values (including empty). Captures
# combined output and exit code without aborting the test on non-zero exit.
# Args: <working_dir> <service_name> <default_bc> <default_df>
# Sets globals: RC, COMBINED (the captured stdout+stderr).
run_parse_with_defaults() {
  local working_dir="$1" svc="$2" def_bc="$3" def_df="$4"
  local out_file err_file
  out_file="$WORK/gh_output.$RANDOM"
  err_file="$WORK/gh_err.$RANDOM"
  : >"$out_file"
  set +e
  WORKING_DIR="$working_dir" \
  SERVICE_NAME="$svc" \
  CONFIG_PATH=".skyhook/skyhook.yaml" \
  DEFAULT_BUILD_CONTEXT="$def_bc" \
  DEFAULT_DOCKERFILE_PATH="$def_df" \
  GITHUB_OUTPUT="$out_file" \
    bash "$PARSE_SCRIPT" >"$err_file" 2>&1
  RC=$?
  set -e
  COMBINED="$(cat "$err_file")"
}

# --- config file missing + empty default_build_context => fail ---
run_parse_with_defaults "$WORK/no-such-dir" "any-svc" "" "$DEFAULT_DF"
[ "$RC" -ne 0 ] || { echo "FAIL: missing config + empty default_build_context should fail"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "Config file not found" "missing config + empty BC: error mentions config"
assert_contains "$COMBINED" "default_build_context" "missing config + empty BC: error names default_build_context"

# --- config file missing + empty default_dockerfile_path => fail ---
run_parse_with_defaults "$WORK/no-such-dir" "any-svc" "$DEFAULT_BC" ""
[ "$RC" -ne 0 ] || { echo "FAIL: missing config + empty default_dockerfile_path should fail"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "default_dockerfile_path" "missing config + empty DF: error names default_dockerfile_path"

# --- config file missing + both defaults empty => fail, listing both ---
run_parse_with_defaults "$WORK/no-such-dir" "any-svc" "" ""
[ "$RC" -ne 0 ] || { echo "FAIL: missing config + both defaults empty should fail"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "default_build_context" "missing config + both empty: lists default_build_context"
assert_contains "$COMBINED" "default_dockerfile_path" "missing config + both empty: lists default_dockerfile_path"

# --- service not found + empty default_build_context => fail ---
run_parse_with_defaults "$WORK" "nonexistent-service" "" "$DEFAULT_DF"
[ "$RC" -ne 0 ] || { echo "FAIL: missing service + empty default_build_context should fail"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "Service 'nonexistent-service' not found" "missing service + empty BC: error mentions service"
assert_contains "$COMBINED" "default_build_context" "missing service + empty BC: error names default_build_context"

# --- service not found + empty default_dockerfile_path => fail ---
run_parse_with_defaults "$WORK" "nonexistent-service" "$DEFAULT_BC" ""
[ "$RC" -ne 0 ] || { echo "FAIL: missing service + empty default_dockerfile_path should fail"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "default_dockerfile_path" "missing service + empty DF: error names default_dockerfile_path"

# --- service not found + both defaults non-empty => still succeeds ---
run_parse_with_defaults "$WORK" "nonexistent-service" "$DEFAULT_BC" "$DEFAULT_DF"
[ "$RC" -eq 0 ] || { echo "FAIL: missing service + non-empty defaults should succeed"; echo "$COMBINED"; exit 1; }
echo "PASS: missing service with non-empty defaults still succeeds"

# --- UNIFORM RULE: service FOUND but YAML field absent + empty default => fail ---
# The fail-fast rule is uniform: if a default is ever applied and is empty, fail.
run_parse_with_defaults "$WORK" "no-context" "" "$DEFAULT_DF"
[ "$RC" -ne 0 ] || { echo "FAIL: service-found + empty default_build_context must now fail (uniform rule)"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "buildTool.docker.buildContext absent" "uniform: YAML-absent + empty BC: error mentions which YAML field"
assert_contains "$COMBINED" "default_build_context input is empty" "uniform: YAML-absent + empty BC: error names the input"

# Same for dockerfile_path: use a service whose YAML omits dockerfilePath.
# Add a fixture for that purpose.
NO_DF_DIR="$WORK/no-df"
mkdir -p "$NO_DF_DIR/.skyhook"
cat >"$NO_DF_DIR/.skyhook/skyhook.yaml" <<'YAML'
services:
  - name: no-df
    path: svc-no-df
    buildTool:
      docker:
        buildContext: svc-no-df
YAML
run_parse_with_defaults "$NO_DF_DIR" "no-df" "$DEFAULT_BC" ""
[ "$RC" -ne 0 ] || { echo "FAIL: service-found + empty default_dockerfile_path must now fail (uniform rule)"; echo "$COMBINED"; exit 1; }
assert_contains "$COMBINED" "buildTool.docker.dockerfilePath absent" "uniform: YAML-absent + empty DF: error mentions which YAML field"
assert_contains "$COMBINED" "default_dockerfile_path input is empty" "uniform: YAML-absent + empty DF: error names the input"

# --- "::notice::" is emitted when a non-empty default is applied (informational) ---
notice_log="$WORK/notice.log"
WORKING_DIR="$WORK" \
SERVICE_NAME="no-context" \
CONFIG_PATH=".skyhook/skyhook.yaml" \
DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" \
DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" \
GITHUB_OUTPUT="$WORK/gh_output.notice" \
  bash "$PARSE_SCRIPT" >"$notice_log" 2>&1
assert_contains "$(cat "$notice_log")" "::notice::buildTool.docker.buildContext absent" "notice emitted when build_context default applied"
assert_contains "$(cat "$notice_log")" "$DEFAULT_BC" "notice includes the default value"

# --- not-found paths emit ::warning:: (more prominent than the per-field ::notice::) ---
warn_log="$WORK/warn.log"
WORKING_DIR="$WORK" \
SERVICE_NAME="nonexistent-service" \
CONFIG_PATH=".skyhook/skyhook.yaml" \
DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" \
DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" \
GITHUB_OUTPUT="$WORK/gh_output.warn" \
  bash "$PARSE_SCRIPT" >"$warn_log" 2>&1
assert_contains "$(cat "$warn_log")" "::warning::Service 'nonexistent-service' not found" "service-not-found emits ::warning::"

warn_log2="$WORK/warn2.log"
WORKING_DIR="$WORK/no-such-dir" \
SERVICE_NAME="anything" \
CONFIG_PATH=".skyhook/skyhook.yaml" \
DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" \
DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" \
GITHUB_OUTPUT="$WORK/gh_output.warn2" \
  bash "$PARSE_SCRIPT" >"$warn_log2" 2>&1
assert_contains "$(cat "$warn_log2")" "::warning::Config file not found" "config-not-found emits ::warning::"

# --- value with spaces survives heredoc round-trip ---
out=$(run_parse "$WORK" with-spaces)
assert_eq "$(read_output "$out" path)" "services/with spaces/sub" "with-spaces: path preserves spaces"
assert_eq "$(read_output "$out" build_context)" "services/with spaces/sub" "with-spaces: build_context preserves spaces"

# --- service_name with literal quote: should still resolve via strenv() ---
out=$(run_parse "$WORK" 'name-with-"-quote')
assert_eq "$(read_output "$out" service_found)" "true" "quoted service name resolves"
assert_eq "$(read_output "$out" path)" "svc-quote" "quoted service name: path"

# --- service not found => identity fields empty, build/dockerfile fall back to defaults ---
out=$(run_parse "$WORK" nonexistent-service)
assert_eq "$(read_output "$out" config_found)" "true" "missing service: config_found=true"
assert_eq "$(read_output "$out" service_found)" "false" "missing service: service_found=false"
assert_eq "$(read_output "$out" name)" "" "missing service: name stays empty"
assert_eq "$(read_output "$out" path)" "" "missing service: path stays empty"
assert_eq "$(read_output "$out" build_context)" "$DEFAULT_BC" "missing service: build_context = default_build_context"
assert_eq "$(read_output "$out" dockerfile_path)" "$DEFAULT_DF" "missing service: dockerfile_path = default_dockerfile_path"

# --- config file missing => same fallback contract as missing service ---
out=$(run_parse "$WORK/no-such-dir" any-service)
assert_eq "$(read_output "$out" config_found)" "false" "missing config: config_found=false"
assert_eq "$(read_output "$out" service_found)" "false" "missing config: service_found=false"
assert_eq "$(read_output "$out" build_context)" "$DEFAULT_BC" "missing config: build_context = default_build_context"
assert_eq "$(read_output "$out" dockerfile_path)" "$DEFAULT_DF" "missing config: dockerfile_path = default_dockerfile_path"

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
( cd "$TMP_CWD" && WORKING_DIR="" SERVICE_NAME="cwd-svc" CONFIG_PATH=".skyhook/skyhook.yaml" DEFAULT_BUILD_CONTEXT="$DEFAULT_BC" DEFAULT_DOCKERFILE_PATH="$DEFAULT_DF" GITHUB_OUTPUT="$out_file" bash "$PARSE_SCRIPT" >/dev/null )
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
grep -q "default_build_context:" "$ACTION_FILE" || { echo "FAIL: action.yml does not declare default_build_context input"; exit 1; }
grep -q "default_dockerfile_path:" "$ACTION_FILE" || { echo "FAIL: action.yml does not declare default_dockerfile_path input"; exit 1; }
grep -q "DEFAULT_BUILD_CONTEXT:" "$ACTION_FILE" || { echo "FAIL: action.yml does not wire DEFAULT_BUILD_CONTEXT env"; exit 1; }
grep -q "DEFAULT_DOCKERFILE_PATH:" "$ACTION_FILE" || { echo "FAIL: action.yml does not wire DEFAULT_DOCKERFILE_PATH env"; exit 1; }
# Both default inputs must be required:true (no implicit defaults)
awk '/^  default_build_context:/{f=1} f && /required: true/{print "OK"; exit} f && /^  [a-z]/ && !/^  default_build_context:/{exit}' "$ACTION_FILE" | grep -q OK \
  || { echo "FAIL: default_build_context is not required: true"; exit 1; }
awk '/^  default_dockerfile_path:/{f=1} f && /required: true/{print "OK"; exit} f && /^  [a-z]/ && !/^  default_dockerfile_path:/{exit}' "$ACTION_FILE" | grep -q OK \
  || { echo "FAIL: default_dockerfile_path is not required: true"; exit 1; }
echo "PASS: action.yml delegates to scripts/parse.sh, validates yq v4, pins v4.47.1, declares required default inputs, no context_path residue"

# --- parse.sh structure sanity ---
grep -q "strenv(SERVICE_NAME)" "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not use strenv() for service_name"; exit 1; }
grep -q "Multiple services named" "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not detect duplicate names"; exit 1; }
grep -q "service_name input is required" "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not validate non-empty service_name"; exit 1; }
grep -q 'Failed to parse' "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not surface yq parse errors"; exit 1; }
grep -q 'DEFAULT_BUILD_CONTEXT' "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not consume DEFAULT_BUILD_CONTEXT"; exit 1; }
grep -q 'DEFAULT_DOCKERFILE_PATH' "$PARSE_SCRIPT" || { echo "FAIL: parse.sh does not consume DEFAULT_DOCKERFILE_PATH"; exit 1; }
# The script must NOT silently default build_context to "." anymore.
grep -q 'BUILD_CONTEXT="\."' "$PARSE_SCRIPT" && { echo "FAIL: parse.sh still hard-codes BUILD_CONTEXT=\".\" - defaults must come from caller input"; exit 1; }
echo "PASS: parse.sh has strenv, dup-detection, empty-name validation, parse-error surfacing, caller-supplied defaults"
