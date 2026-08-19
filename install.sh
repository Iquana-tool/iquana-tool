#!/usr/bin/env bash
#
# IQUANA installer.
#
# Clones (or updates) every IQUANA repository next to this script, asks for the
# ports, the release channel, CUDA support and the tokens that need wiring up,
# writes the per-service .env files, installs the dependencies with uv/bun and
# offers to start the tool.
#
# Re-running it is the supported way to update: it checks every repository for
# new commits first, then asks whether to apply them and restart the services.
#
#   ./install.sh              interactive install or update
#   ./install.sh --yes        accept every stored/default answer (no prompts)
#   ./install.sh --reconfigure  go through the configuration questions again
#   ./install.sh --no-start   set everything up but do not start the services
#
# Prerequisites: git, uv (>= 0.10), bun, and Docker (or podman) for the
# postgres and redis containers, which cannot run without a container runtime.

set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# iquana.sh is sourced as a library here: it owns the service definitions,
# process handling and container logic, so the installer and the control script
# can never disagree about what "the backend" is or which port it listens on.
# shellcheck disable=SC1091
. "$INSTALL_ROOT/iquana.sh"

# uv < 0.10 cannot install the PyTorch CUDA wheels the ai-service pins:
# download.pytorch.org publishes no `#sha256=` fragment for some of its wheels,
# so uv records them hash-less in uv.lock, and older uv then validates the
# download against the *union* of the other hashes in that entry and fails with
# a bogus "Hash mismatch for torchvision==...". Fixed in 0.10.0.
MIN_UV_VERSION="0.10.0"

# name|url
REPOS="
backend|https://github.com/Iquana-tool/backend.git
frontend-react|https://github.com/Iquana-tool/frontend-react.git
ai-service|https://github.com/Iquana-tool/ai-service.git
"

# uv projects to sync, in order. frontend-react is handled separately (bun).
UV_PROJECTS="backend ai-service"

ASSUME_YES=no
FORCE_RECONFIGURE=no
NO_START=no

# --- prompting -------------------------------------------------------------

# `curl ... | bash` leaves stdin pointing at the pipe, so every prompt would
# swallow a line of the script itself. Read from the terminal explicitly.
open_tty() {
    if [ -t 0 ]; then TTY_IN="/dev/stdin"
    elif [ -r /dev/tty ]; then TTY_IN="/dev/tty"
    else TTY_IN=""
    fi
}

ask() {
    local prompt="$1" default="${2:-}" reply
    if [ "$ASSUME_YES" = yes ] || [ -z "$TTY_IN" ]; then
        printf '%s\n' "$default"; return
    fi
    if [ -n "$default" ]; then
        printf '%s %s[%s]%s ' "$prompt" "$C_DIM" "$default" "$C_RESET" >&2
    else
        printf '%s ' "$prompt" >&2
    fi
    IFS= read -r reply < "$TTY_IN" || reply=""
    printf '%s\n' "${reply:-$default}"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" reply hint
    [ "$default" = y ] && hint="[Y/n]" || hint="[y/N]"
    if [ "$ASSUME_YES" = yes ] || [ -z "$TTY_IN" ]; then
        [ "$default" = y ]; return
    fi
    while true; do
        printf '%s %s%s%s ' "$prompt" "$C_DIM" "$hint" "$C_RESET" >&2
        IFS= read -r reply < "$TTY_IN" || reply=""
        reply="$(printf '%s' "${reply:-$default}" | tr '[:upper:]' '[:lower:]')"
        case "$reply" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) printf '    please answer y or n\n' >&2 ;;
        esac
    done
}

# Secrets are read without echo and only ever shown masked, so a token cannot
# end up in a screenshot or a shoulder-surfer's view during setup.
ask_secret() {
    local prompt="$1" current="${2:-}" reply
    if [ "$ASSUME_YES" = yes ] || [ -z "$TTY_IN" ]; then
        printf '%s\n' "$current"; return
    fi
    if [ -n "$current" ]; then
        printf '%s %s[stored: %s -- press Enter to keep]%s ' "$prompt" "$C_DIM" "$(mask "$current")" "$C_RESET" >&2
    else
        printf '%s %s[leave empty to skip]%s ' "$prompt" "$C_DIM" "$C_RESET" >&2
    fi
    IFS= read -rs reply < "$TTY_IN" || reply=""
    printf '\n' >&2
    printf '%s\n' "${reply:-$current}"
}

mask() {
    local s="$1" n=${#1}
    if [ "$n" -le 8 ]; then printf '%s\n' '********'
    else printf '%s...%s\n' "${s:0:4}" "${s: -4}"; fi
}

# Asks for a port and assigns it to the variable named by $4. It assigns rather
# than echoes on purpose: a `$(...)` call would run in a subshell, and the
# already-taken list it builds up would be discarded after every question.
#
# Re-prompts until the answer is a valid number, not already picked for another
# IQUANA service, and either free or held by the IQUANA service that owns it.
ask_port() {
    local label="$1" default="$2" owner="$3" varname="$4" reply
    while true; do
        reply="$(ask "    $label port?" "$default")"
        if ! printf '%s' "$reply" | grep -qE '^[0-9]+$' || [ "$reply" -lt 1 ] || [ "$reply" -gt 65535 ]; then
            warn "'$reply' is not a valid port number."
            [ "$ASSUME_YES" = yes ] && die "invalid port for $label in non-interactive mode."
            continue
        fi
        if printf '%s\n' $CHOSEN_PORTS | grep -qx "$reply"; then
            warn "port $reply is already used by another IQUANA service."
            [ "$ASSUME_YES" = yes ] && die "duplicate port $reply in non-interactive mode."
            continue
        fi
        if port_open "$reply" && ! process_running "$owner"; then
            warn "something is already listening on port $reply."
            [ "$ASSUME_YES" = yes ] && break
            ask_yes_no "    use it anyway?" n && break || continue
        fi
        break
    done
    CHOSEN_PORTS="$CHOSEN_PORTS $reply"
    printf -v "$varname" '%s' "$reply"
}

# --- prerequisites ---------------------------------------------------------

version_ge() {
    # returns 0 if $1 >= $2, comparing dotted version numbers field by field
    local a b i
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        local x="${a[i]:-0}" y="${b[i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        [ "${x:-0}" -gt "${y:-0}" ] && return 0
        [ "${x:-0}" -lt "${y:-0}" ] && return 1
    done
    return 0
}

check_prerequisites() {
    step "Checking prerequisites"
    local missing=no

    if command -v git >/dev/null 2>&1; then
        ok "git $(git --version | awk '{print $3}')"
    else
        warn "git is not installed -- see https://git-scm.com/downloads"; missing=yes
    fi

    if command -v uv >/dev/null 2>&1; then
        local uv_version
        uv_version="$(uv --version 2>/dev/null | awk '{print $2}')"
        if version_ge "$uv_version" "$MIN_UV_VERSION"; then
            ok "uv $uv_version"
        else
            warn "uv $uv_version is too old -- IQUANA needs at least $MIN_UV_VERSION (older uv rejects the PyTorch wheels). Upgrade with: uv self update"
            missing=yes
        fi
    else
        warn "uv is not installed -- install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"; missing=yes
    fi

    if command -v bun >/dev/null 2>&1; then
        ok "bun $(bun --version)"
    else
        warn "bun is not installed -- install it with: curl -fsSL https://bun.sh/install | bash"; missing=yes
    fi

    if runtime_ready; then
        ok "$RUNTIME (container runtime)"
    elif detect_runtime; then
        warn "$RUNTIME is installed but not responding. Start Docker Desktop (or 'podman machine start') and run this script again."
        missing=yes
    else
        warn "no container runtime found. Docker is a prerequisite: the postgres database and the redis broker run as containers and cannot be started without it. See https://docs.docker.com/get-docker/"
        missing=yes
    fi

    [ "$missing" = no ] || die "please install the missing prerequisites and run ./install.sh again."
}

# --- configuration ---------------------------------------------------------

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

configure() {
    step "Configuration"
    CHOSEN_PORTS=""

    say ""
    info "Release channel:"
    info "  stable  -- the 'main' branch of every repository (recommended)"
    info "  dev     -- the 'dev' branch where available; newer features, expect breakage"
    local channel
    while true; do
        channel="$(ask "    channel (stable/dev)?" "${IQUANA_CHANNEL:-stable}" | tr '[:upper:]' '[:lower:]')"
        case "$channel" in stable|dev) break ;; *) warn "please answer 'stable' or 'dev'." ;; esac
    done
    IQUANA_CHANNEL="$channel"

    say ""
    info "Hostname other machines use to reach this installation. Keep 'localhost'"
    info "unless you want to open IQUANA to your network -- it is baked into the"
    info "frontend's API URL and into the backend's allowed CORS origins."
    IQUANA_HOST="$(ask "    hostname or IP?" "${IQUANA_HOST:-localhost}")"

    say ""
    # Only worth asking when other people will sign in: a single-researcher
    # install on localhost needs none of it, and the sign-in page reads fine
    # with every one of these left empty.
    info "If other people will sign in to this installation, you can name it and"
    info "say who to ask for an account. Both appear on the sign-in page."
    local brand_default
    brand_default="$([ -n "${INSTANCE_NAME:-}${INSTANCE_CONTACT:-}" ] && echo y || echo n)"
    if ask_yes_no "    identify this instance to its users?" "$brand_default"; then
        info "    e.g. 'HIFMB Reef Lab' -- shown as 'Welcome to ...'"
        INSTANCE_NAME="$(ask "    instance name?" "${INSTANCE_NAME:-}")"
        info "    e.g. 'the Helmholtz Institute for Functional Marine Biodiversity'"
        info "    -- shown as 'hosted by ...', so phrase it to follow that"
        INSTANCE_ORG="$(ask "    hosting organisation?" "${INSTANCE_ORG:-}")"
        info "    where people without an account should ask for one"
        INSTANCE_CONTACT="$(ask "    access contact (email)?" "${INSTANCE_CONTACT:-}")"
        info "    optional one-line notice under the sign-in form, e.g. usage terms"
        INSTANCE_NOTICE="$(ask "    notice?" "${INSTANCE_NOTICE:-}")"
    else
        INSTANCE_NAME=""; INSTANCE_ORG=""; INSTANCE_CONTACT=""; INSTANCE_NOTICE=""
    fi

    say ""
    # Off by default: an instance reachable from the network should not accept
    # strangers because nobody thought to say otherwise. The backend still lets
    # the *first* account be created regardless, so a fresh install can always
    # be signed into -- see register_user in the backend.
    info "Self-registration lets anyone who can reach IQUANA create their own"
    info "account. With it off, you create accounts and hand them out. The first"
    info "account can always be created either way, so you are never locked out."
    if ask_yes_no "    allow self-registration?" \
        "$([ "${INSTANCE_ALLOW_REGISTRATION:-false}" = true ] && echo y || echo n)"; then
        INSTANCE_ALLOW_REGISTRATION=true
    else
        INSTANCE_ALLOW_REGISTRATION=false
    fi

    say ""
    info "Ports (press Enter to accept the default):"
    ask_port "frontend (web UI)"       "${FRONTEND_PORT:-3000}"   frontend   FRONTEND_PORT
    ask_port "backend (API)"           "${BACKEND_PORT:-8000}"    backend    BACKEND_PORT
    ask_port "ai-service"              "${AI_SERVICE_PORT:-8004}" ai-service AI_SERVICE_PORT
    ask_port "mlflow (model tracking)" "${MLFLOW_PORT:-5000}"     mlflow     MLFLOW_PORT
    ask_port "postgres (database)"     "${POSTGRES_PORT:-5432}"   postgres   POSTGRES_PORT
    ask_port "redis (task broker)"     "${REDIS_PORT:-6379}"      redis      REDIS_PORT

    say ""
    # On macOS the ai-service pyproject already routes torch to the default PyPI
    # wheels (its CUDA index is marked for linux/win only), so there is nothing
    # to ask -- there are no CUDA builds for macOS.
    if [ "$(uname -s)" = "Darwin" ]; then
        CUDA=no
        info "macOS detected -- installing the CPU/MPS build of PyTorch."
    else
        local cuda_default="${CUDA:-}"
        if [ -z "$cuda_default" ]; then
            if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
                cuda_default=y
                info "An NVIDIA GPU was detected."
            else
                cuda_default=n
                info "No NVIDIA GPU was detected."
            fi
        else
            [ "$CUDA" = yes ] && cuda_default=y || cuda_default=n
        fi
        info "With CUDA the ai-service runs models on the GPU (several GB of extra"
        info "downloads). Without it everything still works, but inference and"
        info "training fall back to the CPU and are much slower."
        if ask_yes_no "    install with CUDA support?" "$cuda_default"; then CUDA=yes; else CUDA=no; fi
    fi

    say ""
    info "A HuggingFace access token lets the ai-service download gated model"
    info "weights (SAM, DINOv3, ...). Create one at https://huggingface.co/settings/tokens"
    info "-- a read token is enough. You can leave this empty and add it later."
    HF_ACCESS_TOKEN="$(ask_secret "    HuggingFace token?" "${HF_ACCESS_TOKEN:-}")"

    say ""
    info "Optional: an LLM API key enables the 'describe your label space' assistant"
    info "in the frontend. Without it, label spaces are created manually."
    if ask_yes_no "    configure the label-space assistant?" "$([ -n "${LABEL_SPACE_LLM_API_KEY:-}" ] && echo y || echo n)"; then
        info "    model names follow LiteLLM's '<provider>/<model>' form,"
        info "    e.g. anthropic/claude-opus-4-8, openai/gpt-4o, ollama/llama3"
        LABEL_SPACE_LLM_MODEL="$(ask "    LLM model?" "${LABEL_SPACE_LLM_MODEL:-anthropic/claude-opus-4-8}")"
        LABEL_SPACE_LLM_API_KEY="$(ask_secret "    LLM API key?" "${LABEL_SPACE_LLM_API_KEY:-}")"
    else
        LABEL_SPACE_LLM_MODEL="${LABEL_SPACE_LLM_MODEL:-anthropic/claude-opus-4-8}"
        LABEL_SPACE_LLM_API_KEY=""
    fi

    # Generated once and then kept: rotating the secret key would invalidate
    # every issued login token, and changing the database password would lock
    # the backend out of the existing postgres volume.
    POSTGRES_USER="${POSTGRES_USER:-iquana}"
    POSTGRES_DB="${POSTGRES_DB:-iquana}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(random_secret)}"
    SECRET_KEY="${SECRET_KEY:-$(random_secret)}"
}

write_conf() {
    umask 077
    cat > "$IQUANA_CONF" <<EOF
# IQUANA installation settings -- written by install.sh.
# Contains secrets; keep it out of version control (it is gitignored).
# Edit by hand and re-run ./install.sh to apply, or run ./install.sh --reconfigure.

IQUANA_CHANNEL="$IQUANA_CHANNEL"
IQUANA_HOST="$IQUANA_HOST"

INSTANCE_NAME="$INSTANCE_NAME"
INSTANCE_ORG="$INSTANCE_ORG"
INSTANCE_CONTACT="$INSTANCE_CONTACT"
INSTANCE_NOTICE="$INSTANCE_NOTICE"
INSTANCE_ALLOW_REGISTRATION="$INSTANCE_ALLOW_REGISTRATION"

FRONTEND_PORT="$FRONTEND_PORT"
BACKEND_PORT="$BACKEND_PORT"
AI_SERVICE_PORT="$AI_SERVICE_PORT"
MLFLOW_PORT="$MLFLOW_PORT"
POSTGRES_PORT="$POSTGRES_PORT"
REDIS_PORT="$REDIS_PORT"

CUDA="$CUDA"
CONTAINER_RUNTIME="$RUNTIME"

POSTGRES_USER="$POSTGRES_USER"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
POSTGRES_DB="$POSTGRES_DB"

HF_ACCESS_TOKEN="$HF_ACCESS_TOKEN"
SECRET_KEY="$SECRET_KEY"
LABEL_SPACE_LLM_MODEL="$LABEL_SPACE_LLM_MODEL"
LABEL_SPACE_LLM_API_KEY="$LABEL_SPACE_LLM_API_KEY"
EOF
    chmod 600 "$IQUANA_CONF"
    ok "wrote iquana.conf"
}

# --- repositories ----------------------------------------------------------

repo_names() { printf '%s\n' $REPOS | awk -F'|' 'NF {print $1}'; }
repo_url()   { printf '%s\n' $REPOS | awk -F'|' -v n="$1" '$1 == n {print $2}'; }

# The dev channel tracks each repository's `dev` branch, but not every
# repository has one, so the branch is resolved against the remote and falls
# back to main.
resolve_branch() {
    local url="$1"
    [ "$IQUANA_CHANNEL" = dev ] || { printf 'main\n'; return; }
    if git ls-remote --heads "$url" dev 2>/dev/null | grep -q refs/heads/dev; then
        printf 'dev\n'
    else
        printf 'main\n'
    fi
}

clone_repos() {
    step "Fetching repositories ($IQUANA_CHANNEL channel)"
    local name url branch dir
    for name in $(repo_names); do
        url="$(repo_url "$name")"
        branch="$(resolve_branch "$url")"
        dir="$INSTALL_ROOT/$name"
        if [ -d "$dir/.git" ]; then
            update_repo "$name" "$branch"
        else
            info "cloning $name ($branch) ..."
            git clone --quiet --branch "$branch" "$url" "$dir" \
                || die "could not clone $url. Check your network connection."
            ok "$name @ $(git -C "$dir" rev-parse --short HEAD) ($branch)"
        fi
    done
}

# Refuses to touch a checkout with local modifications: a developer working in
# one of these directories should not have their changes stomped by an update.
update_repo() {
    # Split declaration: bash expands every word of a `local` statement before
    # assigning any of them, so "$INSTALL_ROOT/$name" on this line would use the
    # caller's $name, not the parameter above it.
    local name="$1" branch="$2" current
    local dir="$INSTALL_ROOT/$name"
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        warn "$name has uncommitted local changes -- leaving it untouched."
        return
    fi
    git -C "$dir" fetch --quiet origin || { warn "could not fetch $name."; return; }
    current="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    if [ "$current" != "$branch" ]; then
        info "switching $name from $current to $branch ..."
        git -C "$dir" checkout --quiet "$branch" 2>/dev/null \
            || git -C "$dir" checkout --quiet -b "$branch" "origin/$branch" \
            || { warn "could not switch $name to $branch."; return; }
    fi
    git -C "$dir" merge --quiet --ff-only "origin/$branch" 2>/dev/null \
        || warn "$name could not be fast-forwarded to origin/$branch -- resolve it manually."
    ok "$name @ $(git -C "$dir" rev-parse --short HEAD) ($branch)"
}

# Returns 0 if at least one repository has new commits upstream. Only fetches;
# nothing is applied here, so the user still gets to decide.
check_for_updates() {
    step "Checking for updates"
    UPDATES_AVAILABLE=no
    local name url branch dir behind
    for name in $(repo_names); do
        dir="$INSTALL_ROOT/$name"
        if [ ! -d "$dir/.git" ]; then
            info "$name is not installed yet"
            UPDATES_AVAILABLE=yes
            continue
        fi
        url="$(repo_url "$name")"
        branch="$(resolve_branch "$url")"
        git -C "$dir" fetch --quiet origin 2>/dev/null || { warn "could not reach origin for $name."; continue; }
        behind="$(git -C "$dir" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
        if [ "$behind" -gt 0 ]; then
            printf '    %s%-22s %s new commit(s) on %s%s\n' "$C_YELLOW" "$name" "$behind" "$branch" "$C_RESET"
            UPDATES_AVAILABLE=yes
        else
            printf '    %-22s up to date\n' "$name"
        fi
    done
    [ "$UPDATES_AVAILABLE" = yes ]
}

# --- environment files -----------------------------------------------------

# Keeps a .bak of anything it replaces, so a hand-edited env file is never lost
# silently on the next run.
write_env() {
    local path="$1" content="$2"
    if [ ! -d "$(dirname "$path")" ]; then
        warn "$(basename "$(dirname "$path")") is not installed -- skipping its configuration."
        return
    fi
    if [ -f "$path" ] && [ "$(cat "$path")" != "$content" ]; then
        cp "$path" "$path.bak"
        info "kept the previous $(basename "$path") as $(basename "$path").bak"
    fi
    printf '%s' "$content" > "$path"
    chmod 600 "$path"
}

write_env_files() {
    step "Writing service configuration"

    local origins="http://localhost:$FRONTEND_PORT"
    [ "$IQUANA_HOST" != "localhost" ] && origins="$origins,http://$IQUANA_HOST:$FRONTEND_PORT"

    write_env "$INSTALL_ROOT/backend/.env" "\
# Generated by install.sh -- edit iquana.conf and re-run the installer instead.
ALLOWED_ORIGINS=$origins
DATABASE_URL=postgresql+psycopg://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:$POSTGRES_PORT/$POSTGRES_DB
REDIS_URL=redis://localhost:$REDIS_PORT
MLFLOW_URL=http://localhost:$MLFLOW_PORT
AI_SERVICE_URL=http://localhost:$AI_SERVICE_PORT
SECRET_KEY=$SECRET_KEY
LABEL_SPACE_LLM_MODEL=$LABEL_SPACE_LLM_MODEL
LABEL_SPACE_LLM_API_KEY=$LABEL_SPACE_LLM_API_KEY
INSTANCE_NAME=$INSTANCE_NAME
INSTANCE_ORG=$INSTANCE_ORG
INSTANCE_CONTACT=$INSTANCE_CONTACT
INSTANCE_NOTICE=$INSTANCE_NOTICE
INSTANCE_ALLOW_REGISTRATION=$INSTANCE_ALLOW_REGISTRATION
"
    ok "backend/.env"

    write_env "$INSTALL_ROOT/ai-service/.env" "\
# Generated by install.sh -- edit iquana.conf and re-run the installer instead.
HF_ACCESS_TOKEN=$HF_ACCESS_TOKEN
REDIS_URL=redis://localhost:$REDIS_PORT
MLFLOW_URL=http://localhost:$MLFLOW_PORT
ALLOWED_ORIGINS=http://localhost:$BACKEND_PORT
"
    ok "ai-service/.env"

    # .env.local, not .env: Vite gives it precedence over the repository's own
    # .env and gitignores it by convention, so an update can never overwrite
    # these values.
    #
    # VITE_, not REACT_APP_: the frontend moved from create-react-app to Vite,
    # which only exposes variables carrying its own prefix. The old REACT_APP_
    # names were silently ignored, leaving src/api/config.js on its
    # http://localhost:8000 fallback no matter what hostname or port was chosen
    # here. Instance branding is deliberately absent -- Vite substitutes these at
    # build time, so it lives on the backend and is fetched at runtime instead.
    write_env "$INSTALL_ROOT/frontend-react/.env.local" "\
# Generated by install.sh -- edit iquana.conf and re-run the installer instead.
VITE_API_BASE_URL=http://$IQUANA_HOST:$BACKEND_PORT
VITE_WS_URL=ws://$IQUANA_HOST:$BACKEND_PORT
PORT=$FRONTEND_PORT
"
    ok "frontend-react/.env.local"
}

# --- dependencies ----------------------------------------------------------

install_dependencies() {
    step "Installing dependencies"
    info "This downloads several GB on a first install and can take a while."

    # Synced one project at a time, in this console: the services share git
    # dependencies, and two concurrent uv processes writing the same uv.lock is
    # what corrupts a lockfile into duplicate [[package]] blocks.
    #
    # A plain sync, never --upgrade: uv.lock is what pins iquana-toolbox and the
    # rest, and re-resolving would both leave the checkout dirty (which makes the
    # next update refuse to fast-forward it) and pull in upstream releases nobody
    # tested. New dependency versions arrive through a pulled uv.lock.
    local proj
    for proj in $UV_PROJECTS; do
        info "syncing $proj ..."
        uv sync --project "$INSTALL_ROOT/$proj" \
            || die "'uv sync' failed for $proj. The output above says why."
        ok "$proj"
    done

    if [ "$CUDA" != yes ] && [ "$(uname -s)" != "Darwin" ]; then
        # The ai-service pyproject pins torch to the CUDA index, and uv has no
        # project-level switch for that, so the CPU wheels are installed over
        # the synced environment afterwards. This has to be repeated after every
        # `uv sync`, which is why it lives here and not in a one-off step.
        info "replacing PyTorch with the CPU build (CUDA disabled) ..."
        uv pip install --python "$INSTALL_ROOT/ai-service/.venv/bin/python" \
            --torch-backend=cpu torch torchvision \
            || warn "could not install the CPU build of PyTorch -- the ai-service may pull in CUDA libraries."
        ok "PyTorch (CPU)"
    fi

    info "installing frontend packages ..."
    ( cd "$INSTALL_ROOT/frontend-react" && bun install --silent ) \
        || die "'bun install' failed for frontend-react."
    ok "frontend-react"
}

# --- main ------------------------------------------------------------------

banner() {
    say ""
    say "${C_BOLD}  IQUANA installer${C_RESET}"
    say "${C_DIM}  interactive annotation and quantification${C_RESET}"
    say ""
}

summary() {
    say ""
    step "Ready"
    info "frontend   http://$IQUANA_HOST:$FRONTEND_PORT"
    info "backend    http://$IQUANA_HOST:$BACKEND_PORT  (API docs at /docs)"
    info "mlflow     http://localhost:$MLFLOW_PORT"
    say ""
    info "start / stop / status:   ./iquana.sh start | stop | status"
    info "logs:                    ./iquana.sh logs backend -f"
    info "update:                  ./install.sh"
    say ""
    if [ -z "$HF_ACCESS_TOKEN" ]; then
        warn "no HuggingFace token was configured -- gated model weights will fail to download. Re-run ./install.sh --reconfigure to add one."
    fi
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes) ASSUME_YES=yes ;;
            --reconfigure) FORCE_RECONFIGURE=yes ;;
            --no-start) NO_START=yes ;;
            # The header comment above is the help text: print it, stripped of
            # its leading '#', up to the first line of actual code.
            -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$INSTALL_ROOT/install.sh"; exit 0 ;;
            *) die "unknown option '$1'. Run ./install.sh --help." ;;
        esac
        shift
    done

    open_tty
    banner
    check_prerequisites

    local existing=no
    if [ -f "$IQUANA_CONF" ]; then
        existing=yes
        # shellcheck disable=SC1090
        . "$IQUANA_CONF"
        # A conf written by an older installer may not know about every setting.
        # CUDA is filled in here rather than in configure(), which treats an
        # unset value as "ask, defaulting to whether a GPU was detected".
        : "${CUDA:=no}"
    fi
    apply_conf_defaults
    : "${HF_ACCESS_TOKEN:=}"
    : "${LABEL_SPACE_LLM_MODEL:=anthropic/claude-opus-4-8}"
    : "${LABEL_SPACE_LLM_API_KEY:=}"
    : "${SECRET_KEY:=$(random_secret)}"
    : "${POSTGRES_PASSWORD:=$(random_secret)}"

    local apply_updates=yes
    if [ "$existing" = yes ]; then
        say ""
        info "Existing installation found ($IQUANA_CHANNEL channel)."
        if check_for_updates; then
            say ""
            ask_yes_no "Apply these updates?" y || apply_updates=no
        else
            say ""
            ok "everything is already up to date."
            apply_updates=no
        fi

        say ""
        if [ "$FORCE_RECONFIGURE" = yes ] || ask_yes_no "Change the configuration (ports, CUDA, tokens)?" n; then
            configure
        fi
    else
        configure
    fi

    write_conf

    if [ "$existing" = no ] || [ "$apply_updates" = yes ]; then
        clone_repos
        write_env_files
        install_dependencies
    else
        # Configuration may still have changed even when no code was updated.
        write_env_files
    fi

    summary

    [ "$NO_START" = no ] || return 0

    say ""
    local anything_running=no name
    for name in $SERVICES; do
        process_running "$name" && anything_running=yes
    done

    if [ "$anything_running" = yes ]; then
        if ask_yes_no "Restart the services now?" y; then
            say ""; cmd_restart
        else
            info "the running services still use the previous version -- restart with ./iquana.sh restart"
        fi
    else
        if ask_yes_no "Start IQUANA now?" y; then
            say ""; cmd_start
        else
            info "start it later with ./iquana.sh start"
        fi
    fi
}

main "$@"
