# read-config

[![test](https://github.com/skyhook-io/read-config/actions/workflows/test.yml/badge.svg)](https://github.com/skyhook-io/read-config/actions/workflows/test.yml)

A GitHub Action that reads service configuration from `.skyhook/skyhook.yaml` and exposes the matching service's fields as step outputs.

## Description

This action parses the Skyhook configuration file and extracts service-specific settings including:
- Service path
- Deployment repository configuration
- Docker build tool settings (build context, dockerfile path)

## Usage

```yaml
- name: Read service config
  id: config
  uses: skyhook-io/read-config@v1
  with:
    working_directory: code
    service_name: my-service
    default_build_context: '.'
    default_dockerfile_path: 'Dockerfile'

- name: Build Docker image
  run: |
    docker build \
      -f ${{ steps.config.outputs.dockerfile_path }} \
      ${{ steps.config.outputs.build_context }}
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `working_directory` | Path to the repository root containing `.skyhook/skyhook.yaml` | No | `.` |
| `service_name` | Name of the service to look up in the config | Yes | - |
| `config_path` | Path to the skyhook config file relative to working_directory | No | `.skyhook/skyhook.yaml` |
| `default_build_context` | Value emitted as `build_context` whenever it would otherwise be empty: YAML field absent, config file missing, or service missing. The action does not pick a value for you - callers must pass a non-empty default, otherwise the action fails loudly. | Yes | - |
| `default_dockerfile_path` | Value emitted as `dockerfile_path` whenever it would otherwise be empty (same triggers as `default_build_context`). Must be non-empty. | Yes | - |
| `include_env` | When `true`, also emit the `environments` block from the local skyhook.yaml as the `environments` output. When `true` and the local config has no `environments` block (key absent, or any YAML null spelling: `null` / `Null` / `NULL` / `~` / bare `environments:`), the action exits 1 with `Not supported yet`. When `true` and the config file itself is missing, the action also exits 1 with `Not supported yet`. Both cases are reserved for a future external-repository fetch path. | No | `false` |
| `git_token` | Reserved for a future release: token used to fetch the `environments` block from an external repository when `include_env=true` and the block is not present locally. Currently unused - the action fails `Not supported yet` in that scenario regardless of this input. | No | `''` |

## Outputs

| Output | Description |
|--------|-------------|
| `name` | Service name from config |
| `path` | Service path relative to repo root |
| `deployment_repo` | Separate deployment repository (if configured) |
| `deployment_repo_path` | Path within deployment repository |
| `build_context` | Docker build context relative to repo root. Falls back to `default_build_context` when absent/empty in config or when config/service is not found. |
| `dockerfile_path` | Dockerfile path relative to repo root. Falls back to `default_dockerfile_path` when absent/empty in config or when config/service is not found. |
| `config_found` | Whether the config file was found (`true`/`false`) |
| `service_found` | Whether the service was found in config (`true`/`false`) |
| `environments` | YAML block of environments from the local skyhook.yaml when `include_env=true` and the block is present. Empty when `include_env=false`. When `include_env=true` and the block is absent, the action exits 1 instead of emitting this output. |

> When a default is applied because a YAML field was absent, the action emits a `::notice::` line. When the entire config file or service is missing, the action emits a `::warning::` (more prominent in the run UI) — so the source of every emitted value is visible at a glance.

## Config File Format

The action expects a `.skyhook/skyhook.yaml` file with the following structure:

```yaml
services:
  - name: my-service
    path: services/my-service
    deploymentRepo: org/deployment-repo
    deploymentRepoPath: services/my-service
    buildTool:
      docker:
        buildContext: services/my-service
        dockerfilePath: docker/Dockerfile.my-service

  - name: another-service
    path: services/another
    buildTool:
      docker:
        # buildContext omitted - falls back to default_build_context input
        dockerfilePath: services/another/Dockerfile

environments:
  - name: dev
    clusterName: dev-cluster
    namespace: dev
```

## Example: Build with Dynamic Config

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          path: code

      - name: Read service config
        id: config
        uses: skyhook-io/read-config@v1
        with:
          working_directory: code
          service_name: ${{ env.SERVICE_NAME }}
          default_build_context: '.'
          default_dockerfile_path: Dockerfile

      - name: Build and push Docker image
        uses: skyhook-io/docker-build-push-action@v1
        with:
          context: code/${{ steps.config.outputs.build_context }}
          dockerfile: code/${{ steps.config.outputs.dockerfile_path }}
          image: ${{ inputs.image }}
```

## Example: include the environments block

```yaml
- name: Read service config + environments
  id: config
  uses: skyhook-io/read-config@v1
  with:
    working_directory: code
    service_name: my-service
    default_build_context: '.'
    default_dockerfile_path: Dockerfile
    include_env: 'true'

- name: Use environments
  env:
    # IMPORTANT: pass via env, not via direct expression interpolation. The
    # environments YAML can contain double quotes, `$`, backticks, etc., which
    # would be re-interpreted by the shell if inlined into the `run:` script.
    ENVS: ${{ steps.config.outputs.environments }}
  run: |
    printf '%s\n' "$ENVS" > /tmp/envs.yaml
    yq '.[].name' /tmp/envs.yaml
```

For a `skyhook.yaml` containing:

```yaml
environments:
  - name: autopush
    clusterName: nonprod-cluster-us-east1
    cloudProvider: gcp
    account: koalabackend
    location: us-east1-b
    namespace: autopush
  - name: dev
    clusterName: nonprod-cluster-us-east1
    cloudProvider: gcp
    account: koalabackend
    location: us-east1-b
    namespace: dev
  - name: prod
    clusterName: prod-cluster-us-east1
    cloudProvider: gcp
    account: koalabackend
    location: us-east1-b
    namespace: prod
  - name: ephemeral
    clusterName: ""
    namespace: ephemeral
```

the `environments` output contains the YAML list above (without the top-level `environments:` key).

If `include_env=true` and the local `skyhook.yaml` has no `environments:` block (key absent, or any YAML null spelling: `null` / `Null` / `NULL` / `~` / bare `environments:`) the action exits 1 with `Not supported yet`. Same exit if the config file itself is missing. An explicit empty list (`environments: []`) is passed through as-is - the action returns whatever the file declares.

`environments` is orthogonal to service lookup: when `include_env=true` and the block is present, the output is populated even if the named service is missing. (The service-missing `::warning::` still fires for the per-service outputs.)

`git_token` is declared so callers can wire it in advance, but the external-repository code path is not yet implemented.

## Behavior matrix

Let `BC` = `default_build_context` input, `DF` = `default_dockerfile_path` input.

**Uniform rule:** if the action would emit an empty value for `build_context` or `dockerfile_path`, it exits 1 instead. The corresponding default input must be non-empty whenever the YAML doesn't supply the value.

| Scenario | `config_found` | `service_found` | `name` / `path` / `deployment_*` | `build_context` | `dockerfile_path` |
|---|---|---|---|---|---|
| Service found, both YAML fields set | `true` | `true` | from config | from config | from config |
| Service found, only `buildContext` absent/`""`/`null`, `BC` non-empty | `true` | `true` | from config | `BC` | from config |
| Service found, only `dockerfilePath` absent/`""`/`null`, `DF` non-empty | `true` | `true` | from config | from config | `DF` |
| Service found, both YAML fields absent, both defaults non-empty | `true` | `true` | from config | `BC` | `DF` |
| Service missing, both defaults non-empty | `true` | `false` | `""` | `BC` | `DF` |
| Config file missing, both defaults non-empty | `false` | `false` | `""` | `BC` | `DF` |
| Any of the above where the relevant default is empty | n/a | n/a | n/a | n/a | **action exits 1** |
| Duplicate service names in config | n/a | n/a | n/a | n/a | action exits 1 |
| `include_env=true`, `environments` present in local config | unchanged | unchanged | unchanged | unchanged | unchanged - and `environments` output is populated |
| `include_env=true`, `environments: []` (explicit empty list) | unchanged | unchanged | unchanged | unchanged | unchanged - `environments` output is the literal `[]` (pass-through) |
| `include_env=true`, no `environments` block (key absent, `null`, `~`, `Null`, `NULL`, or bare) | n/a | n/a | n/a | n/a | **action exits 1 - `Not supported yet`** |
| `include_env=true`, local config file missing | n/a | n/a | n/a | n/a | **action exits 1 - `Not supported yet`** |
| `include_env=false` (default) | unchanged | unchanged | unchanged | unchanged | `environments` output is empty |

The action **always** emits a non-empty `build_context` and `dockerfile_path` on success, so the consuming workflow can drop `||` fallbacks:

```yaml
context: code/${{ steps.config.outputs.build_context }}
dockerfile: code/${{ steps.config.outputs.dockerfile_path }}
```

Logging:
- A `::notice::` is emitted when a default is applied because a YAML field was absent for an otherwise-found service.
- A `::warning::` is emitted when the entire config file or service is missing and defaults flow through (more prominent than a notice — the not-found state is usually a misconfiguration).

## Runner requirements

- Bash + `yq` v4.x. The action installs yq v4.47.1 if missing.
- Auto-install supports `Linux-x86_64`, `Linux-aarch64`, `Darwin-x86_64`, `Darwin-arm64`. On other platforms (Windows, BSD, etc.), pre-install yq before this step or the action will fail with a clear error.
- The auto-installer uses `curl` (preferred) or `wget`, and `sudo` if not running as root.

## License

MIT
