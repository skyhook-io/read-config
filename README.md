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
