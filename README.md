# claude-code-yolo-in-devcontainers

One command to drop Claude Code in YOLO mode into any project via a devcontainer.

## What it does

1. Inspects the project (package manager, language, ports)
2. Asks Claude to pick the best devcontainer template and features
3. Generates `.devcontainer/devcontainer.json` and `setup.sh`
4. Starts the container (reuses it on subsequent runs)
5. Launches Claude Code with `--dangerously-skip-permissions`

Your `~/.claude` config, plugins, and gitconfig are bind-mounted at their exact host paths so Claude Code works identically to your host setup.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/talpah/claude-code-yolo-in-devcontainers/main/install.sh | sh
```

The script runs on any POSIX-compatible shell (`/bin/sh`). The installer checks for all requirements and offers to install any that are missing:

| Requirement | Auto-install |
|---|---|
| `curl` | — (needed to run the installer) |
| `python3` | apt / Homebrew |
| `jq` | apt / Homebrew |
| [Docker](https://docs.docker.com/engine/install/) | links to docs |
| [devcontainer CLI](https://github.com/devcontainers/cli) | `npm i -g @devcontainers/cli` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/getting-started) | native installer |
| `shellcheck` | optional — validates the generated `setup.sh` if present |

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
| `~/.gitconfig` | `~/.gitconfig` (same path) |
| `$SSH_AUTH_SOCK` | `/ssh-agent` (only if set) |
| `$CC_YOLO_PROJECTS_DIR` | same path (only if set) |

Mounting at the exact host path ensures all plugin paths, MCP server scripts, and tool configurations in `.claude.json` resolve correctly inside the container.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | **Required.** Your Anthropic API key. |
| `CC_YOLO_PROJECTS_DIR` | (unset) | If set, bind-mounts this directory at the same path inside the container. Useful for cross-project context when Claude's config references other projects. |
| `GITHUB_TOKEN` | (unset) | Optional. Raises the GitHub API rate limit from 60 to 5,000 req/hr during template and feature discovery. |

## Uninstall

```sh
rm ~/.local/bin/cc-yolo
```

To remove the generated devcontainer config from a project:

```sh
rm -rf .devcontainer
```
