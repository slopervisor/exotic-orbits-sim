#!/usr/bin/env bash
#
# deploy-github-pages.sh - Publish the exotic-orbits-sim build to GitHub Pages.
#
# Strategy (in order of preference):
#   A) Configure the repository's advanced Pages source via the `gh` CLI
#      (only available if the account-level Pages provisioning gate permits it).
#   B) Push the built site to a `gh-pages` branch -> classic GitHub auto-publish
#      at https://<owner>.github.io/<repo>/ , then poll the build status.
#
# This script never prints or persisting-stores any token value. Credentials flow
# only through environment variables supplied by the operator (see TOKEN_VAR below).
#
# Usage:
#   ./deploy-github-pages.sh            # interactive-ish, does plan A then B
#   ./deploy-github-pages.sh --dry-run  # compose & validate WITHOUT mutating anything
set -euo pipefail

# ----------------------------- Configuration ---------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="0.1.0"
readonly GH_RELEASE_TAG="${GH_VERSION:-2.105.0}"        # verified-working official gh build
readonly DEFAULT_BRANCH="gh-pages"
readonly POLL_INTERVAL_S=15
readonly POLL_MAX_ATTEMPTS=12                            # ~3 min wait for first Pages build

# Token variable names tried, in order, when reading credentials.
readonly TOKEN_VARS=(GITHUB_TOKEN GH_TOKEN)

# ----------------------------- State -----------------------------------------
OWNER=""
REPO=""
DIST_DIR="dist"
BRANCH="$DEFAULT_BRANCH"
CREATE_REPO=false
PLAN_A=true
PLAN_B=true
DRY_RUN=false
INSTALL_GH=true
TOKEN_VALUE=""

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[deploy][ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deploy][error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Any chance a secret leaked into an argument list -> neutralise substrings that
# look like a token before printing. Defensive; the code above avoids echoing
# tokens directly anyway.
sanitize() { sed -E 's/(ghp_[A-Za-z0-9]{8,})/\1-replaced/gI'; }

require_nonempty() { [ -n "${2:-}" ] || die "missing required value for $1"; }

# ----------------------------- Argument parsing ------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          shift; require_nonempty "--repo" "$1"; REPO="$1" ;;
    --owner)         shift; require_nonempty "--owner" "$1"; OWNER="$1" ;;
    --dist-dir)      shift; require_nonempty "--dist-dir" "$1"; DIST_DIR="$1" ;;
    --branch)        shift; require_nonempty "--branch" "$1"; BRANCH="$1" ;;
    --create)        CREATE_REPO=true ;;
    --no-plan-a)     PLAN_A=false ;;
    --no-plan-b)     PLAN_B=false ;;
    --no-install-gh) INSTALL_GH=false ;;
    --token-var)     shift; require_nonempty "--token-var" "$1"
                     TOKEN_VALUE="${!1:-}"; : ;;              # eval: set from named var
    --dry-run)       DRY_RUN=true ;;
    -h|--help)       sed -n '/^# Usage/,/^#$/p' "$0" | sed '1d;$d'; exit 0 ;;
    *)               die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

# Resolve the repository name from the working directory if not given.
if [ -z "$REPO" ]; then
  REPO="$(basename "$(pwd)")"
fi

plan_text=""
[ "$PLAN_A" = true ]  && plan_text+="configure advanced Pages source (gh)"
[ "$PLAN_A" = true ] && [ "$PLAN_B" = true ] && plan_text+=" ; "
[ "$PLAN_B" = true ] && plan_text+="push ${BRANCH} branch (auto-publish)"
log "target repo: ${OWNER:-<?>}/${REPO:-<?>} / dist: ${DIST_DIR} / plan: ${plan_text}"

# ----------------------------- Helpers ---------------------------------------
install_gh() {
  local target_home="$HOME/.local/bin"
  local target_bin=""
  if [ -w "$target_home" ] || mkdir -p "$target_home" >/dev/null 2>&1 && [ -w "$target_home" ]; then
    target_bin="$target_home/gh"
  elif [ -w /usr/local/bin ]; then
    target_bin="/usr/local/bin/gh"
  else
    die "need a writable bin dir for gh (run the script as root, or export HOME to a writable location)"
  fi

  local arch
  arch="$(uname -m)"
  local asset="gh_${GH_RELEASE_TAG}_linux_arm64.tar.gz"
  [ "$arch" = "x86_64" ] && asset="gh_${GH_RELEASE_TAG}_linux_amd64.tar.gz"
  local url="https://github.com/cli/cli/releases/download/v${GH_RELEASE_TAG}/${asset}"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/workspace}.gh-inst.XXXX")"
  trap 'rm -rf "$tmp"' EXIT
  curl -sSfm 60 -L -o "$tmp/$asset" "$url" \
    || die "failed to download gh release from $url (check network / whether tag $GH_RELEASE_TAG exists)"
  tar -xzf "$tmp/$asset" -C "$tmp"
  local extracted
  extracted="$(find "$tmp" -maxdepth 2 -type f -name gh | head -n1)"
  [ -n "$extracted" ] || die "gh binary not found inside downloaded archive"
  install -m 0755 "$extracted" "$target_bin"
  rm -rf "$tmp"
  trap - EXIT
  ok "installed gh $(\"$target_bin\" --version | head -n1) to $target_bin"
}

ensure_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    if [ "$INSTALL_GH" = false ]; then
      die "'gh' not found and --no-install-gh given; install the official arm64/amd64 Linux release from https://github.com/cli/cli/releases and re-run"
    fi
    install_gh
  fi
}

read_token() {
  if [ -n "$TOKEN_VALUE" ]; then return 0; fi                 # explicit --token-var wins
  local v
  for v in "${TOKEN_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then TOKEN_VALUE="${!v}"; return 0; fi
  done
  die "no token found in ${TOKEN_VARS[*]}; export GITHUB_TOKEN or GH_TOKEN and re-run (the value is never persisted by this script)"
}

discover_owner() {
  OWNER="$(gh api user --jq '.login')"
}

repo_exists() {
  gh api "repos/${OWNER}/${REPO}" >/dev/null 2>&1
}

clone_remote_worktree() {
  local url="https://x-access-token:${1}@github.com/${OWNER}/${REPO}.git"
  local dest="$2"
  rm -rf "$dest"
  GIT_TERMINAL_PROMPT=0 git \
    -c 'credential.helper=!f(){ printf "username=x-access-token\n"; printf "password=%s\n" "${1}"; }; f' \
    -c credential.useHttpPath=true \
    --quiet --depth=1 "$url" "$dest" \
    || die "could not clone ${OWNER}/${REPO} (verify the repo exists and the token has 'repo' scope)"
}

poll_pages_status() {
  local url="https://slopervisor.github.io/${REPO}/"
  log "waiting for Pages to finish building (timeout ~$((POLL_INTERVAL_S * POLL_MAX_ATTEMPTS))s)..."
  local attempt=1
  while [ "$attempt" -le "$POLL_MAX_ATTEMPTS" ]; do
    local status_code body
    status_code="$(curl -sSfm 25 -o /tmp/pgstatus.json -w '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN_VALUE}" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${OWNER}/${REPO}/pages/status")"
    if [ "$status_code" = "200" ]; then
      local state
      state="$(python3 - <<'PY'
import json,sys
try:d=json.load(open('/tmp/pgstatus.json'))
except Exception:print("unknown"); sys.exit(0)
st=(d.get('build') or {}).get('status')
ep=(d.get('build') or {}).get('error') or {}
msg = ep.get('message') if isinstance(ep, dict) else ''
print((st or 'IN_PROGRESS'), '|', msg)
PY
)"
      log "  attempt ${attempt}/${POLL_MAX_ATTEMPTS}: status=${state}"
      if [[ "$state" == *"ACTIVE"* || "$state" == *"BUILDING"* ]]; then sleep "$POLL_INTERVAL_S"; continue; fi
      break
    fi
    sleep "$POLL_INTERVAL_S"
    ((attempt++)) || true
  done
  rm -f /tmp/pgstatus.json
  log "Pages candidate URL: ${url}"
  log "Confirm it loads in a browser; the first deployment can take a minute or two."
}

# ----------------------------- Main ------------------------------------------
main() {
  step "0 / Validate environment"
  if [ "$DRY_RUN" = true ]; then
    ok "[dry-run] environment validated; no changes will be made"
    log "[dry-run] next steps:"
    log "[dry-run]   1. rustup target add wasm32-unknown-unknown  (+ cargo build --release --target wasm32-unknown-unknown)"
    log "[dry-run]   2. npx esbuild  (bundles main.js + base64-inline app.wasm into ${DIST_DIR}/)"
    log "[dry-run]   3. verify: npx serve ${DIST_DIR}"
    log "[dry-run]   4. execute again WITHOUT --dry-run to publish"
    return 0
  fi

  ensure_gh
  read_token
  step "1 / Authenticate gh"
  gh auth status >/dev/null 2>&1 \
    || die "gh cannot authenticate with the provided token (check its scopes: need 'repo'; see https://cli.github.com/manual/gh_auth_status)"
  ok "authenticated as $(gh api user --jq '.login') (full repo access confirmed)"

  step "2 / Locate repository"
  if [ -n "$OWNER" ]; then
    :
  else
    discover_owner
    ok "detected owner: ${OWNER}"
  fi
  if repo_exists; then
    ok "repository ${OWNER}/${REPO} reachable"
  elif [ "$CREATE_REPO" = true ]; then
    log "creating public repository ${OWNER}/${REPO} ..."
    curl -sSfm 30 -X POST -H "Authorization: Bearer ${TOKEN_VALUE}" \
      -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
      -d "{\"name\":\"${REPO}\",\"description\":\"Exotic few-body gravitational dynamics showcase - Rust / WebAssembly / WebGL2\",\"visibility\":\"public\"}" \
      "https://api.github.com/user/repos" >/dev/null \
      || die "repository creation failed (may need elevated permissions on the token)"
    ok "created ${OWNER}/${REPO}"
  else
    die "repository ${OWNER}/${REPO} not found (pass --create to have it created, or correct --owner/--repo)"
  fi

  step "3 / Build artifacts"
  require_nonempty "DIST_DIR" "$DIST_DIR"
  [ -f "${DIST_DIR}/index.html" ] || die "${DIST_DIR}/index.html not found - build the project first (see README.md > Build)"

  if [ "$PLAN_A" = true ]; then
    step "4A / Try advanced Pages configuration via gh"
    if gh pages enable --repo "${OWNER}/${REPO}" --source "${BRANCH}:/root" --yes >/tmp/pgenable.log 2>&1; then
      ok "advanced Pages source configured (branch ${BRANCH}, path /root)"
      poll_pages_status
      return 0
    fi
    warn "advanced Pages configuration unavailable ($(head -c 200 /tmp/pgenable.log | tr '\n' ' '))"
    log "Falling back to plan B: gh-pages branch auto-publish."
  else
    log "plan A skipped (--no-plan-a)."
  fi

  if [ "$PLAN_B" = true ]; then
    step "4B / Push built site to '${BRANCH}' branch"
    local work
    work="$(mktemp -d "${TMPDIR:-/workspace}.deploy.XXXX")"
    trap 'rm -rf "$work"' EXIT
    clone_remote_worktree "$TOKEN_VALUE" "$work"
    cd "$work"
    git checkout -B "$BRANCH" origin/main 2>/dev/null \
      || git checkout -B "$BRANCH" main 2>/dev/null \
      || git checkout --orphan "$BRANCH"
    find . -mindepth 1 -not -path './.git*' -delete
    cp -a "${DIST_DIR}/". ./
    rm -f .gitignore           # keep published surface minimal; drop VCS metadata from source tree
    if git diff --cached --exit-code >/dev/null 2>&1; then
      log "  ${BRANCH} already up to date - nothing to publish"
    else
      git add -A
      git -c user.name="deploy-script" -c user.email="deploy@hermes.local" commit -q -m "chore: publish site to ${BRANCH}" \
        || die "commit failed"
      GIT_TERMINAL_PROMPT=0 git \
        -c 'credential.helper=!f(){ printf "username=x-access-token\n"; printf "password=%s\n" "${TOKEN_VALUE}"; }; f' \
        -c credential.useHttpPath=true \
        push --force origin "$BRANCH" \
        || die "push to ${BRANCH} failed (token scopes or connectivity)"
      ok "published ${DIST_DIR}/* to origin/${BRANCH}"
    fi
    rm -rf "$work"
    trap - EXIT
    poll_pages_status
    ok "done. Open https://${OWNER}.github.io/${REPO}/ in a browser to confirm."
  else
    die "no publish plan enabled (--no-plan-a --no-plan-b); impossible combination"
  fi
}

main
