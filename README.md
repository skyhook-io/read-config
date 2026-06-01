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

- name: Build Docker image
  run: |
    docker build \
      -f ${{ steps.config.outputs.dockerfile_path || 'Dockerfile' }} \
      ${{ steps.config.outputs.build_context }}
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `working_directory` | Path to the repository root containing `.skyhook/skyhook.yaml` | No | `.` |
| `service_name` | Name of the service to look up in the config | Yes | - |
| `config_path` | Path to the skyhook config file relative to working_directory | No | `.skyhook/skyhook.yaml` |
| `default_dockerfile_path` | Fallback for `dockerfile_path` when the YAML doesn't supply one (config unreadable, service missing, or `buildTool.docker.dockerfilePath` unset/empty). | No | `""` |
| `default_build_context` | Fallback for `build_context` when the YAML doesn't supply one. | No | `""` |

## Outputs

| Output | Description |
|--------|-------------|
| `name` | Service name from config |
| `path` | Service path relative to repo root |
| `deployment_repo` | Separate deployment repository (if configured) |
| `deployment_repo_path` | Path within deployment repository |
| `build_context` | Docker build context relative to repo root (defaults to `.` when absent in config) |
| `dockerfile_path` | Dockerfile path relative to repo root |
| `config_found` | Whether the config file was found (`true`/`false`) |
| `service_found` | Whether the service was found in config (`true`/`false`) |

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
        # buildContext omitted - defaults to "."
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

      - name: Build and push Docker image
        uses: skyhook-io/docker-build-push-action@v1
        with:
          context: code/${{ steps.config.outputs.build_context }}
          dockerfile: code/${{ steps.config.outputs.dockerfile_path || format('{0}/Dockerfile', steps.config.outputs.build_context) }}
          image: ${{ inputs.image }}
```

## Behavior matrix

The two build-tool outputs (`build_context`, `dockerfile_path`) follow a single rule:

> **YAML wins when the config is readable AND the service exists AND the field is non-empty. In every other case, the caller-supplied `default_*` input is emitted.**

`name`, `path`, `deployment_repo`, and `deployment_repo_path` are always sourced from the YAML and emit empty when the config/service can't be read — there are no `default_*` fallbacks for them.

| Scenario | `config_found` | `service_found` | `build_context` | `dockerfile_path` |
|---|---|---|---|---|
| Config file missing | `false` | `false` | `default_build_context` | `default_dockerfile_path` |
| Config found, service missing | `true` | `false` | `default_build_context` | `default_dockerfile_path` |
| Service found, both fields set | `true` | `true` | from YAML | from YAML |
| Service found, only `buildContext` set | `true` | `true` | from YAML | `default_dockerfile_path` |
| Service found, neither field set | `true` | `true` | `default_build_context` | `default_dockerfile_path` |
| Duplicate service names | n/a | n/a | n/a | action exits 1 |

Without `default_*` inputs the fallback is empty — meaning a workflow that wants a guaranteed-non-empty value should pass them at the call site:

```yaml
- uses: skyhook-io/read-config@v1
  with:
    service_name: my-svc
    # Computed sensible fallbacks the caller controls:
    default_dockerfile_path: services/my-svc/Dockerfile
    default_build_context: .
```

`config_found` and `service_found` remain available so the caller can distinguish between a YAML-sourced value and a fallback if needed.

## Runner requirements

- Bash + `yq` v4.x. The action installs yq v4.47.1 if missing.
- Auto-install supports `Linux-x86_64`, `Linux-aarch64`, `Darwin-x86_64`, `Darwin-arm64`. On other platforms (Windows, BSD, etc.), pre-install yq before this step or the action will fail with a clear error.
- The auto-installer uses `curl` (preferred) or `wget`, and `sudo` if not running as root.

## License

MIT
