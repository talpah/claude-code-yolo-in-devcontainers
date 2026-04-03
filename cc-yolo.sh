#!/usr/bin/env sh
# cc-yolo.sh — set up and launch Claude Code in YOLO mode inside a devcontainer.
# Usage: cd /path/to/project && cc-yolo.sh [--reset]
set -eu

# ─── Guards ───────────────────────────────────────────────────────────────────

for cmd in claude devcontainer docker jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || { printf '%s\n' "$cmd not found." >&2; exit 1; }
done

reset=0
[ "${1:-}" = "--reset" ] && reset=1

if [ "$reset" -eq 1 ]; then
  printf '%s\n' "→ Resetting .devcontainer…" >&2
  rm -rf .devcontainer
fi

# ─── Setup (skipped if .devcontainer already exists) ─────────────────────────

if [ ! -d ".devcontainer" ]; then

  project=$(basename "$PWD")
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  ctx="$tmpdir/ctx.txt"

  {
    printf "=== Project: %s ===\n\n" "$project"
    printf "=== Root directory listing ===\n%s\n\n" "$(ls -1 | head -60)"

    for f in package.json pyproject.toml Cargo.toml go.mod Gemfile \
              requirements.txt setup.py setup.cfg composer.json build.gradle.kts \
              .nvmrc .node-version .tool-versions .python-version \
              Dockerfile docker-compose.yml; do
      [ -f "$f" ] && printf "=== %s ===\n%s\n\n" "$f" "$(head -100 "$f")"
    done
  } > "$ctx"

  # ─── Fetch templates + features index ──────────────────────────────────────

  printf '%s\n' "→ Fetching devcontainer templates + features index…" >&2

  # Wrapper: adds GITHUB_TOKEN auth header when set, keeping all curl calls consistent.
  _curl_gh() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -sf --max-time 10 -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
    else
      curl -sf --max-time 10 "$@"
    fi
  }

  _fetch_ids() {
    _curl_gh "https://api.github.com/repos/$1/$2/contents/src" 2>/dev/null \
      | jq -r '.[] | select(.type == "dir") | .name' 2>/dev/null || true
  }

  _fetch_ids devcontainers templates > "$tmpdir/template_names.txt"

  while IFS= read -r name; do
    curl -sf --max-time 5 \
      "https://raw.githubusercontent.com/devcontainers/templates/main/src/${name}/devcontainer-template.json" \
      -o "$tmpdir/tmeta_${name}.json" 2>/dev/null &
  done < "$tmpdir/template_names.txt"
  wait

  {
    printf "=== Available devcontainer TEMPLATES ===\n"
    printf "(choose one as base; use its exact name in the OCI reference)\n\n"
    while IFS= read -r name; do
      if [ -f "$tmpdir/tmeta_${name}.json" ]; then
        jq -r --arg id "ghcr.io/devcontainers/templates/${name}" '
          $id
          + " | " + .name
          + " | " + (.description // "")
          + if .options.imageVariant then
              " [imageVariant proposals: " + (.options.imageVariant.proposals | join(", ")) + "]"
            else "" end
        ' "$tmpdir/tmeta_${name}.json" 2>/dev/null \
          || printf "ghcr.io/devcontainers/templates/%s\n" "$name"
      else
        printf "ghcr.io/devcontainers/templates/%s\n" "$name"
      fi
    done < "$tmpdir/template_names.txt"
  } >> "$ctx"

  {
    printf "\n=== Available devcontainer FEATURES ===\n"
    printf "# official\n"
    _fetch_ids devcontainers features \
      | while IFS= read -r n; do printf "ghcr.io/devcontainers/features/%s:1\n" "$n"; done
    printf "# extra\n"
    _fetch_ids devcontainers-extra features \
      | while IFS= read -r n; do printf "ghcr.io/devcontainers-extra/features/%s:1\n" "$n"; done
    printf "# oven (bun)\nghcr.io/oven-sh/bun/devcontainer/features/bun:1\n"
    printf "\n"
  } >> "$ctx"

  count=$(grep -c '^ghcr\.io/' "$ctx" 2>/dev/null || printf '0')
  printf '%s\n' "  ${count} IDs loaded" >&2

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
if start == -1:
    print('extract_json: no JSON object found in Claude output:', file=sys.stderr)
    print(content, file=sys.stderr)
    sys.exit(1)
obj, _ = json.JSONDecoder().raw_decode(content[start:])
print(json.dumps(obj, indent=2))
"
  }

  # ─── Step 1: Claude picks template + features ───────────────────────────────

  printf '%s\n' "→ Selecting template and features…" >&2

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
  if [ -z "$template_id" ] || [ "$template_id" = "null" ]; then
    printf '%s\n' "✗ Claude selection missing template_id." >&2; exit 1
  fi
  template_args=$(printf '%s' "$selection" | jq -c '.template_args // {}')
  extra_features=$(printf '%s' "$selection" | jq -c '.extra_features // []')
  forward_ports=$(printf '%s' "$selection" | jq -c '.forward_ports // []')
  template_name="${template_id##*/}"

  printf '%s' "$template_name" | grep -qE '^[a-z0-9_-]+$' || {
    printf '%s\n' "✗ Invalid template name from Claude: ${template_name}" >&2; exit 1
  }

  # Validate template_id against the fetched allowlist (guards against prompt injection
  # causing Claude to return a template we never fetched from GitHub).
  grep -qxF "$template_name" "$tmpdir/template_names.txt" || {
    printf '%s\n' "✗ Claude returned an unknown template: ${template_id}" >&2
    printf '  Allowed: %s\n' "$(tr '\n' ' ' < "$tmpdir/template_names.txt")" >&2
    exit 1
  }

  # Filter extra_features to known registry prefixes only. Any feature referencing
  # an unknown registry is dropped here before OCI validation or container install.
  extra_features=$(printf '%s' "$extra_features" | jq -c '
    [ .[] | select(
        startswith("ghcr.io/devcontainers/features/") or
        startswith("ghcr.io/devcontainers-extra/features/") or
        startswith("ghcr.io/oven-sh/bun/devcontainer/features/")
    )]
  ')

  printf '%s\n' "  template:  $template_id" >&2
  printf '%s\n' "  args:      $template_args" >&2
  printf '%s\n' "  features:  $extra_features" >&2
  printf '%s\n' "  ports:     $forward_ports" >&2

  # ─── Step 1b: Validate features against OCI registry ───────────────────────

  printf '%s\n' "→ Validating features…" >&2

  printf '%s' "$extra_features" | jq -r '.[]' > "$tmpdir/fids.txt"

  # Probe OCI registry directly via HTTP (no Docker daemon required, ~10x faster).
  # ref format: ghcr.io/org/repo/name:tag
  # Called in a background subshell so variables don't need to be local.
  _check_oci() {
    oci_ref="$1"
    oci_out="$2"
    oci_registry="${oci_ref%%/*}"
    oci_image="${oci_ref#*/}"
    oci_name="${oci_image%%:*}"
    oci_tag="${oci_image##*:}"
    oci_token=$(curl -sf --max-time 5 \
      "https://${oci_registry}/token?scope=repository:${oci_name}:pull" \
      | jq -r '.token // .access_token // ""') || { printf 'bad' > "$oci_out"; return; }
    oci_status=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Authorization: Bearer $oci_token" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
      "https://${oci_registry}/v2/${oci_name}/manifests/${oci_tag}") \
      || { printf 'bad' > "$oci_out"; return; }
    [ "$oci_status" = "200" ] && printf 'ok' > "$oci_out" || printf 'bad' > "$oci_out"
  }

  while IFS= read -r fid; do
    [ -z "$fid" ] && continue
    key=$(printf '%s' "$fid" | tr -c 'a-zA-Z0-9' '_')
    _check_oci "$fid" "$tmpdir/fcheck_${key}.txt" &
  done < "$tmpdir/fids.txt"
  wait

  > "$tmpdir/valid_features.txt"
  while IFS= read -r fid; do
    [ -z "$fid" ] && continue
    key=$(printf '%s' "$fid" | tr -c 'a-zA-Z0-9' '_')
    result=''
    [ -f "$tmpdir/fcheck_${key}.txt" ] && result=$(cat "$tmpdir/fcheck_${key}.txt")
    if [ "$result" = "ok" ]; then
      printf '%s\n' "$fid" >> "$tmpdir/valid_features.txt"
    else
      printf '%s\n' "  ⚠ dropping unavailable feature: $fid" >&2
    fi
  done < "$tmpdir/fids.txt"

  if [ -s "$tmpdir/valid_features.txt" ]; then
    extra_features=$(jq -R . < "$tmpdir/valid_features.txt" | jq -s .)
  else
    extra_features='[]'
  fi
  printf '%s\n' "  validated: $extra_features" >&2

  # ─── Step 2: Apply template ─────────────────────────────────────────────────

  printf '%s\n' "→ Applying template…" >&2
  mkdir -p .devcontainer

  _curl_gh \
    "https://api.github.com/repos/devcontainers/templates/contents/src/${template_name}/.devcontainer" \
    | jq -r '.[].name' 2>/dev/null > "$tmpdir/template_files.txt" || {
    printf '%s\n' "⚠ Could not list template files for '${template_name}' (set GITHUB_TOKEN to avoid rate limits)." >&2
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

  while IFS= read -r fname; do
    if ! printf '%s' "$fname" | grep -qE '^[a-zA-Z0-9_.-]+$'; then
      printf '%s\n' "  ⚠ Skipping suspicious filename from GitHub API: ${fname}" >&2; continue
    fi
    case "$fname" in
      *..*) printf '%s\n' "  ⚠ Skipping suspicious filename from GitHub API: ${fname}" >&2; continue;;
    esac
    raw=$(curl -sf --max-time 10 \
      "https://raw.githubusercontent.com/devcontainers/templates/main/src/${template_name}/.devcontainer/${fname}") || {
      printf '%s\n' "  ⚠ Could not fetch ${fname}" >&2; continue
    }
    printf '%s' "$raw" | python3 "$tmpdir/apply_tmpl.py" "$template_args" > ".devcontainer/${fname}"
    printf '%s\n' "  wrote .devcontainer/${fname}" >&2
  done < "$tmpdir/template_files.txt"

  # ─── Step 3: Patch devcontainer.json ────────────────────────────────────────

  printf '%s\n' "→ Patching devcontainer.json…" >&2

  cat > "$tmpdir/patch.py" << 'PYEOF'
import sys, json, re, os

cfg = json.loads(sys.argv[1])
dc_path        = cfg['dc_path']
project        = cfg['project']
extra_features = cfg['extra_features']
forward_ports  = cfg['forward_ports']
is_compose     = bool(cfg['is_compose'])
ssh_auth_sock  = cfg.get('ssh_auth_sock', '')
projects_dir   = cfg.get('projects_dir', '')

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
    'source=${localEnv:HOME}/.gitconfig,target=${localEnv:HOME}/.gitconfig,type=bind,consistency=cached',
]
if projects_dir:
    if not re.match(r'^[/\w\-. ]+$', projects_dir) or '..' in projects_dir:
        print(f'ERROR: CC_YOLO_PROJECTS_DIR contains invalid characters: {projects_dir!r}', file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(projects_dir):
        print(f'WARNING: CC_YOLO_PROJECTS_DIR is not a directory, skipping mount: {projects_dir}', file=sys.stderr)
    else:
        mounts.append(f'source={projects_dir},target={projects_dir},type=bind,consistency=cached')
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
  [ -f ".devcontainer/docker-compose.yml" ] && is_compose=1

  ssh_sock=''
  [ -S "${SSH_AUTH_SOCK:-}" ] && ssh_sock="$SSH_AUTH_SOCK"

  # Validate CC_YOLO_PROJECTS_DIR before passing to patch.py.
  # Commas break devcontainer mount spec syntax; missing dirs cause confusing errors.
  if [ -n "${CC_YOLO_PROJECTS_DIR:-}" ]; then
    case "$CC_YOLO_PROJECTS_DIR" in
      *,*) printf '%s\n' "✗ CC_YOLO_PROJECTS_DIR must not contain commas: ${CC_YOLO_PROJECTS_DIR}" >&2; exit 1;;
    esac
    if [ ! -d "$CC_YOLO_PROJECTS_DIR" ]; then
      printf '%s\n' "  ⚠ CC_YOLO_PROJECTS_DIR does not exist, skipping mount: ${CC_YOLO_PROJECTS_DIR}" >&2
      CC_YOLO_PROJECTS_DIR=''
    fi
  fi

  patch_config=$(jq -n \
    --arg     dc_path        "$PWD/.devcontainer/devcontainer.json" \
    --arg     project        "$project" \
    --argjson extra_features "$extra_features" \
    --argjson forward_ports  "$forward_ports" \
    --argjson is_compose     "$is_compose" \
    --arg     ssh_auth_sock  "${ssh_sock:-}" \
    --arg     projects_dir   "${CC_YOLO_PROJECTS_DIR:-}" \
    '{dc_path:$dc_path,project:$project,extra_features:$extra_features,
      forward_ports:$forward_ports,is_compose:$is_compose,
      ssh_auth_sock:$ssh_auth_sock,projects_dir:$projects_dir}')
  python3 "$tmpdir/patch.py" "$patch_config"

  # ─── Step 4: Generate setup.sh ──────────────────────────────────────────────

  printf '%s\n' "→ Generating setup.sh…" >&2

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
  there (bind-mount lands at host path e.g. /home/user/.claude, but container
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
  8. Pipfile present → pip install pipenv && pipenv install
  9. requirements.txt present → uv venv && uv pip install -r requirements.txt
  10. none matched → echo 'No package manager detected' and skip
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

  if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck -s bash .devcontainer/setup.sh; then
      printf '%s\n' "  ✗ shellcheck failed on generated setup.sh — refusing to continue" >&2
      exit 1
    fi
    printf '%s\n' "  shellcheck: setup.sh OK" >&2
  fi

  printf '\n%s\n' "✓ .devcontainer/ created (template: ${template_id})" >&2

fi

# ─── Start container + launch Claude Code ────────────────────────────────────

_container_for_pwd() {
  docker ps --filter "label=devcontainer.local_folder=$PWD" --format '{{.ID}}' 2>/dev/null | head -1
}

container_id=$(_container_for_pwd)
if [ "$reset" -eq 1 ] || [ -z "$container_id" ]; then
  if [ "$reset" -eq 1 ]; then
    devcontainer up --remove-existing-container --workspace-folder .
  else
    devcontainer up --workspace-folder .
  fi
  container_id=$(_container_for_pwd)
  [ -z "$container_id" ] && { printf '%s\n' "✗ No running container found for $PWD after devcontainer up." >&2; exit 1; }
else
  printf '%s\n' "→ Container already running ($container_id), skipping devcontainer up." >&2
fi

printf '%s\n' "→ Attaching to container $container_id ($PWD)" >&2
devcontainer exec --workspace-folder . claude --dangerously-skip-permissions
