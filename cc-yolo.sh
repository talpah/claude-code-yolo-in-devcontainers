#!/usr/bin/env zsh
# cc-yolo.sh — set up and launch Claude Code in YOLO mode inside a devcontainer.
# Usage: cd /path/to/project && cc-yolo.sh [--reset]
set -euo pipefail

# ─── Guards ───────────────────────────────────────────────────────────────────

for cmd in claude devcontainer docker jq python3; do
  command -v "$cmd" &>/dev/null || { print "$cmd not found." >&2; exit 1; }
done

reset=0
[[ "${1:-}" == "--reset" ]] && reset=1

if (( reset )); then
  print "→ Resetting .devcontainer…" >&2
  rm -rf .devcontainer
fi

# ─── Setup (skipped if .devcontainer already exists) ─────────────────────────

if [[ ! -d ".devcontainer" ]]; then

  project=$(basename "$PWD")
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  ctx="$tmpdir/ctx.txt"

  {
    printf "=== Project: %s ===\n\n" "$project"
    printf "=== Root directory listing ===\n%s\n\n" "$(ls -1 | head -60)"

    local -a manifests=(
      package.json pyproject.toml Cargo.toml go.mod Gemfile
      requirements.txt setup.py setup.cfg composer.json build.gradle.kts
      .nvmrc .node-version .tool-versions .python-version
      Dockerfile docker-compose.yml
    )
    for f in "${manifests[@]}"; do
      [[ -f "$f" ]] && printf "=== %s ===\n%s\n\n" "$f" "$(head -100 "$f")"
    done
  } > "$ctx"

  # ─── Fetch templates + features index ──────────────────────────────────────

  print "→ Fetching devcontainer templates + features index…" >&2

  _fetch_ids() {
    local owner="$1" repo="$2"
    curl -sf --max-time 10 \
      "https://api.github.com/repos/${owner}/${repo}/contents/src" \
      2>/dev/null \
      | jq -r '.[] | select(.type == "dir") | .name' \
      2>/dev/null || true
  }

  template_names=($(_fetch_ids devcontainers templates))

  for name in "${template_names[@]}"; do
    curl -sf --max-time 5 \
      "https://raw.githubusercontent.com/devcontainers/templates/main/src/${name}/devcontainer-template.json" \
      -o "$tmpdir/tmeta_${name}.json" 2>/dev/null &
  done
  wait

  {
    printf "=== Available devcontainer TEMPLATES ===\n"
    printf "(choose one as base; use its exact name in the OCI reference)\n\n"
    for name in "${template_names[@]}"; do
      if [[ -f "$tmpdir/tmeta_${name}.json" ]]; then
        jq -r --arg id "ghcr.io/devcontainers/templates/${name}" '
          $id
          + " | " + .name
          + " | " + (.description // "")
          + if .options.imageVariant then
              " [imageVariant proposals: " + (.options.imageVariant.proposals | join(", ")) + "]"
            else "" end
        ' "$tmpdir/tmeta_${name}.json" 2>/dev/null || printf "ghcr.io/devcontainers/templates/%s\n" "$name"
      else
        printf "ghcr.io/devcontainers/templates/%s\n" "$name"
      fi
    done
  } >> "$ctx"

  {
    printf "\n=== Available devcontainer FEATURES ===\n"
    printf "# official\n"
    _fetch_ids devcontainers features | while read -r n; do printf "ghcr.io/devcontainers/features/%s:1\n" "$n"; done
    printf "# extra\n"
    _fetch_ids devcontainers-extra features | while read -r n; do printf "ghcr.io/devcontainers-extra/features/%s:1\n" "$n"; done
    printf "# oven (bun)\nghcr.io/oven-sh/bun/devcontainer/features/bun:1\n"
    printf "\n"
  } >> "$ctx"

  count=$(grep -c '^ghcr\.io/' "$ctx" 2>/dev/null || echo 0)
  print "  ${count} IDs loaded" >&2

  # ─── Claude call helpers ────────────────────────────────────────────────────

  run_claude() { claude -p --no-session-persistence --tools "" < "$1"; }

  make_prompt() {
    local out="$tmpdir/prompt_$1.txt"
    cat "$ctx" > "$out"
    printf "\n---\n\n" >> "$out"
    printf "%s" "$2" >> "$out"
    printf "%s" "$out"
  }

  extract_json() {
    python3 -c "
import sys, json
content = sys.stdin.read()
start = content.find('{')
if start == -1: sys.exit(1)
obj, _ = json.JSONDecoder().raw_decode(content[start:])
print(json.dumps(obj, indent=2))
"
  }

  # ─── Step 1: Claude picks template + features ───────────────────────────────

  print "→ Selecting template and features…" >&2

  p=$(make_prompt select \
"Analyse the project context above and output a JSON object selecting the best
devcontainer template and any extra features needed.
Output ONLY valid JSON — no markdown fences, no explanations.

{
  \"template_id\": \"ghcr.io/devcontainers/templates/<name>\",
  \"template_args\": { ... },
  \"extra_features\": [ \"ghcr.io/...\", ... ],
  \"forward_ports\": [ ... ]
}

Rules:
- template_id: choose from the TEMPLATES list. Do NOT append a version suffix.
- template_args: use a value from the template's [imageVariant proposals] list exactly
  as shown (e.g. '3.12-bookworm', '22-bookworm'). Use {} if template has no options.
- extra_features: choose ONLY IDs that appear in the FEATURES list above.
  DO NOT include: ripgrep, fd, pnpm, common-utils (ripgrep+fd installed via apt;
  pnpm has no published OCI feature; common-utils+claude-code are auto-added).
  For pnpm/bun: they are installed via setup.sh or corepack, not as features.
- forward_ports: infer from project type (3000 React/Next, 5173 Vite, 4321 Astro,
  8000 Django/FastAPI, 8080 Go, 18789 openclaw). Empty array [] if unclear.")

  selection=$(run_claude "$p" | extract_json)
  template_id=$(printf '%s' "$selection" | jq -r '.template_id')
  template_args=$(printf '%s' "$selection" | jq -c '.template_args // {}')
  extra_features=$(printf '%s' "$selection" | jq -c '.extra_features // []')
  forward_ports=$(printf '%s' "$selection" | jq -c '.forward_ports // []')
  template_name="${template_id##*/}"

  print "  template:  $template_id" >&2
  print "  args:      $template_args" >&2
  print "  features:  $extra_features" >&2
  print "  ports:     $forward_ports" >&2

  # ─── Step 1b: Validate features against OCI registry ───────────────────────

  print "→ Validating features…" >&2

  local -a fids=("${(@f)$(printf '%s' "$extra_features" | jq -r '.[]')}")

  for fid in "${fids[@]}"; do
    [[ -z "$fid" ]] && continue
    local key="${fid//[^a-zA-Z0-9]/_}"
    {
      if docker manifest inspect "$fid" >/dev/null 2>&1; then
        printf 'ok'
      else
        printf 'bad'
      fi
    } > "$tmpdir/fcheck_${key}.txt" &
  done
  wait

  local -a valid_features=()
  for fid in "${fids[@]}"; do
    [[ -z "$fid" ]] && continue
    local key="${fid//[^a-zA-Z0-9]/_}"
    local result=''
    [[ -f "$tmpdir/fcheck_${key}.txt" ]] && result=$(<"$tmpdir/fcheck_${key}.txt")
    if [[ "$result" == "ok" ]]; then
      valid_features+=("$fid")
    else
      print "  ⚠ dropping unavailable feature: $fid" >&2
    fi
  done

  if (( ${#valid_features[@]} > 0 )); then
    extra_features=$(printf '%s\n' "${valid_features[@]}" | jq -R . | jq -s .)
  else
    extra_features='[]'
  fi
  print "  validated: $extra_features" >&2

  # ─── Step 2: Apply template ─────────────────────────────────────────────────

  print "→ Applying template…" >&2
  mkdir -p .devcontainer

  template_files=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/devcontainers/templates/contents/src/${template_name}/.devcontainer" \
    | jq -r '.[].name' 2>/dev/null) || {
    print "⚠ Could not list template files for '${template_name}'." >&2
    exit 1
  }

  cat > "$tmpdir/apply_tmpl.py" << 'PYEOF'
import sys, json, re
args = json.loads(sys.argv[1])
content = sys.stdin.read()
for key, val in args.items():
    content = content.replace('${templateOption:' + key + '}', str(val))
content = re.sub(r'\$\{templateOption:[^}]+\}', '', content)
sys.stdout.write(content)
PYEOF

  for fname in ${(f)template_files}; do
    raw=$(curl -sf --max-time 10 \
      "https://raw.githubusercontent.com/devcontainers/templates/main/src/${template_name}/.devcontainer/${fname}") || {
      print "  ⚠ Could not fetch ${fname}" >&2; continue
    }
    python3 "$tmpdir/apply_tmpl.py" "$template_args" <<< "$raw" > ".devcontainer/${fname}"
    print "  wrote .devcontainer/${fname}" >&2
  done

  # ─── Step 3: Patch devcontainer.json ────────────────────────────────────────

  print "→ Patching devcontainer.json…" >&2

  cat > "$tmpdir/patch.py" << 'PYEOF'
import sys, json, re

dc_path, project, extra_features_json, forward_ports_json = sys.argv[1:5]
is_compose    = len(sys.argv) > 5 and sys.argv[5] == '1'
ssh_auth_sock = sys.argv[6] if len(sys.argv) > 6 else ''
extra_features = json.loads(extra_features_json)
forward_ports  = json.loads(forward_ports_json)

with open(dc_path) as f:
    content = f.read()

content = re.sub(r'//[^\n]*', '', content)
content = re.sub(r'/\*[\s\S]*?\*/', '', content)
obj = json.loads(content)

obj['name'] = project

# Determine remoteUser. Priority:
#   1. Template already specifies a non-root user → trust it.
#   2. Image name matches a known pattern with a non-vscode default user.
#   3. Fall back to "vscode" (created by common-utils).
# javascript-node/typescript-node images ship with "node" at UID 1000;
# common-utils fails if it tries to create "vscode" there.
IMAGE_USER_PATTERNS = [
    ('javascript-node', 'node'),
    ('typescript-node', 'node'),
]

existing_user = obj.get('remoteUser') or ''
image = obj.get('image', '')

if existing_user and existing_user not in ('root',):
    remote_user = existing_user
else:
    remote_user = 'vscode'
    for pattern, user in IMAGE_USER_PATTERNS:
        if pattern in image:
            remote_user = user
            break

obj['remoteUser'] = remote_user

# Mount .claude at its literal host path so absolute paths in .claude.json
# (plugin refs, MCP server scripts) resolve correctly inside the container.
mounts = [
    'source=${localEnv:HOME}/.claude,target=${localEnv:HOME}/.claude,type=bind,consistency=cached',
    'source=${localEnv:HOME}/.claude.json,target=${localEnv:HOME}/.claude.json,type=bind,consistency=cached',
    'source=${localEnv:HOME}/Projects,target=${localEnv:HOME}/Projects,type=bind,consistency=cached',
    'source=${localEnv:HOME}/.gitconfig,target=${localEnv:HOME}/.gitconfig,type=bind,consistency=cached',
]
if ssh_auth_sock:
    mounts.append('source=${localEnv:SSH_AUTH_SOCK},target=/ssh-agent,type=bind')
obj['mounts'] = mounts

remote_env = {'ANTHROPIC_API_KEY': '${localEnv:ANTHROPIC_API_KEY}'}
if ssh_auth_sock:
    remote_env['SSH_AUTH_SOCK'] = '/ssh-agent'
obj['remoteEnv']         = remote_env
obj['postCreateCommand'] = 'bash .devcontainer/setup.sh'
obj['forwardPorts']      = forward_ports

if is_compose:
    obj.pop('workspaceMount', None)
    obj['workspaceFolder'] = f'/workspaces/{project}'
else:
    obj['workspaceMount']  = 'source=${localWorkspaceFolder},target=/workspace,type=bind'
    obj['workspaceFolder'] = '/workspace'

features = obj.get('features', {})
if remote_user == 'vscode':
    features['ghcr.io/devcontainers/features/common-utils:1'] = {}
features['ghcr.io/devcontainers-extra/features/claude-code:1'] = {}
for fid in extra_features:
    features[fid] = {}
obj['features'] = features

obj['customizations'] = {'vscode': {'settings': {'terminal.integrated.defaultProfile.linux': 'zsh'}}}

with open(dc_path, 'w') as f:
    json.dump(obj, f, indent=2)
    f.write('\n')
PYEOF

  is_compose=0
  [[ -f ".devcontainer/docker-compose.yml" ]] && is_compose=1

  python3 "$tmpdir/patch.py" \
    "$PWD/.devcontainer/devcontainer.json" \
    "$project" \
    "$extra_features" \
    "$forward_ports" \
    "$is_compose" \
    "${SSH_AUTH_SOCK:-}"

  # ─── Step 4: Generate setup.sh ──────────────────────────────────────────────

  print "→ Generating setup.sh…" >&2

  p=$(make_prompt setup \
"Generate a setup.sh script for a devcontainer postCreateCommand.
Output ONLY the raw shell script — no markdown fences, no explanations, no commentary.

Rules:
- Shebang: #!/usr/bin/env bash
- set -euo pipefail
- Always install system tools first:
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends ripgrep fd-find
    sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
- After apt installs, symlink .claude into the container user home if not already
  there (bind-mount lands at host path e.g. /home/cosmin/.claude, but container
  user may differ e.g. node with HOME=/home/node):
    if [[ ! -e \"\$HOME/.claude\" ]]; then
      for _d in /home/*/.claude; do
        [[ -d \"\$_d\" ]] || continue
        ln -sf \"\$_d\" \"\$HOME/.claude\"
        ln -sf \"\${_d}.json\" \"\$HOME/.claude.json\" 2>/dev/null || true
        break
      done
    fi
- Then install project dependencies using EXACTLY ONE package manager.
  Check lockfiles in this priority order and stop at the first match:
  1. pnpm-lock.yaml present → ensure pnpm available (sudo corepack enable pnpm 2>/dev/null || sudo npm i -g pnpm), then pnpm install
  2. package-lock.json present → npm ci
  3. yarn.lock present → yarn install
  4. Cargo.toml present → cargo fetch
  5. go.mod present → go mod download
  6. Gemfile present → bundle install
  7. pyproject.toml present → uv sync
  8. requirements.txt only → uv pip install -r requirements.txt
  9. none matched → echo 'No package manager detected' and skip
  IMPORTANT: pick exactly ONE. Do NOT run multiple package managers.
- After deps, symlink claude binary to native installer path for current user:
    mkdir -p \"\$HOME/.local/bin\"
    claude_bin=\$(command -v claude 2>/dev/null || true)
    if [[ -n \"\$claude_bin\" && \"\$claude_bin\" != \"\$HOME/.local/bin/claude\" ]]; then
      ln -sf \"\$claude_bin\" \"\$HOME/.local/bin/claude\"
    fi
- Print '✓ deps installed' at the end.
- Do NOT install Claude Code (handled by the claude-code devcontainer feature).
- Do NOT write ~/.claude/settings.json (host ~/.claude is bind-mounted).")

  cat > "$tmpdir/extract_sh.py" << 'PYEOF'
import sys, re
text = sys.stdin.read()
tick3 = chr(96) * 3
m = re.search(tick3 + r'(?:bash|sh|shell)?\n(.*?)\n' + tick3, text, re.DOTALL)
if m:
    block = m.group(1)
    i = block.find('#!')
    print(block[i:].rstrip() if i >= 0 else block.rstrip())
else:
    i = text.find('#!')
    if i >= 0:
        print(text[i:].rstrip())
PYEOF

  run_claude "$p" | python3 "$tmpdir/extract_sh.py" > .devcontainer/setup.sh
  chmod +x .devcontainer/setup.sh

  print "\n✓ .devcontainer/ created (template: ${template_id})" >&2

fi

# ─── Start container + launch Claude Code ────────────────────────────────────

container_id=$(docker ps --filter "label=devcontainer.local_folder=$PWD" --format '{{.ID}}' 2>/dev/null | head -1)
if (( reset )) || [[ -z "$container_id" ]]; then
  devcontainer up ${reset:+--remove-existing-container} --workspace-folder .
else
  print "→ Container already running ($container_id), skipping devcontainer up." >&2
fi

devcontainer exec --workspace-folder . claude --dangerously-skip-permissions --continue
