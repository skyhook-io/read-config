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

| Scenario | `config_found` | `service_found` | `build_context` | Other outputs |
|---|---|---|---|---|
| Config file missing | `false` | `false` | `""` | `""` |
| Config found, service missing | `true` | `false` | `""` | `""` |
| Service found, `buildContext` set | `true` | `true` | from config | from config |
| Service found, `buildContext` absent | `true` | `true` | `"."` | from config |
| Duplicate service names in config | n/a | n/a | n/a | action exits 1 |

`build_context` defaults to `"."` only when the service is found and the field is absent. When the service or config itself is missing, `build_context` is empty - the workflow should decide whether to fall back or fail loudly:

```yaml
context: ${{ steps.config.outputs.build_context || '.' }}
dockerfile: ${{ steps.config.outputs.dockerfile_path || 'Dockerfile' }}
```

## Runner requirements

- Bash + `yq` v4.x. The action installs yq v4.47.1 if missing.
- Auto-install supports `Linux-x86_64`, `Linux-aarch64`, `Darwin-x86_64`, `Darwin-arm64`. On other platforms (Windows, BSD, etc.), pre-install yq before this step or the action will fail with a clear error.
- The auto-installer uses `curl` (preferred) or `wget`, and `sudo` if not running as root.

## License

MIT
