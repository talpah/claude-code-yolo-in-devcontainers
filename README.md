# claude-code-yolo-in-devcontainers

One command to drop Claude Code in YOLO mode into any project via a devcontainer.

## What it does

1. Inspects the project (package manager, language, ports)
2. Asks Claude to pick the best devcontainer template and features
3. Generates `.devcontainer/devcontainer.json` and `setup.sh`
4. Starts the container (reuses it on subsequent runs)
5. Launches Claude Code with `--dangerously-skip-permissions`

Your `~/.claude` config, plugins, and `~/Projects` are bind-mounted at their exact host paths so Claude Code works identically to your host setup.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/getting-started) (`claude`)
- [devcontainer CLI](https://github.com/devcontainers/cli) (`npm i -g @devcontainers/cli`)
- Docker
- `jq`, `python3`, `curl`

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/talpah/claude-code-yolo-in-devcontainers/main/install.sh | sh
```

## Usage

```sh
cd /path/to/your/project
cc-yolo          # first run: generates .devcontainer, builds, launches
cc-yolo          # subsequent runs: reuses container, launches instantly
cc-yolo --reset  # regenerate .devcontainer from scratch and rebuild
```

## How it works

- **First run** (no `.devcontainer`): Claude analyses the project and generates a tailored devcontainer config, then builds and starts it.
- **Subsequent runs**: If the container is already running, skips `devcontainer up` entirely and jumps straight to `devcontainer exec`.
- **`--reset`**: Deletes `.devcontainer`, regenerates everything, and forces a container rebuild.

## What gets mounted

| Source (host) | Target (container) |
|---|---|
| `~/.claude` | `~/.claude` (same path) |
| `~/.claude.json` | `~/.claude.json` (same path) |
| `~/Projects` | `~/Projects` (same path) |

Mounting at the exact host path ensures all plugin paths, MCP server scripts, and tool configurations in `.claude.json` resolve correctly inside the container.

## Uninstall

```sh
rm ~/.local/bin/cc-yolo
```

To remove the generated devcontainer config from a project:

```sh
rm -rf .devcontainer
```
