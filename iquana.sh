#!/usr/bin/env bash
#
# IQUANA service control.
#
#   ./iquana.sh start [service ...]    start everything (or just the named services)
#   ./iquana.sh stop  [service ...]    stop everything (or just the named services)
#   ./iquana.sh restart [service ...]  stop, then start
#   ./iquana.sh status                 what is running, on which port, at which commit
#   ./iquana.sh logs <service> [-f]    show (and optionally follow) a service log
#
# Services: postgres redis mlflow ai-service ai-worker backend backend-worker frontend
#
# Configuration lives in iquana.conf next to this script and is written by
# install.sh -- run that first. This file is also sourced *as a library* by
# install.sh, so everything below is a function definition; the dispatcher at
# the bottom only runs when the script is executed directly.

set -euo pipefail

IQUANA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IQUANA_CONF="$IQUANA_ROOT/iquana.conf"
RUN_DIR="$IQUANA_ROOT/.run"
LOG_DIR="$IQUANA_ROOT/logs"
# MLflow resolves its stores relative to the current directory, so both are
# pinned to absolute paths here. Otherwise the tracking db and hundreds of MB of
# artifacts land inside whichever service checkout mlflow happened to start in.
MLFLOW_HOME="$IQUANA_ROOT/.mlflow"

# Start order. Infrastructure first: the backend opens its database pool during
# startup and dies on a refused connection, so postgres has to be accepting
# clients before it launches.
SERVICES="postgres redis mlflow ai-service ai-worker backend backend-worker frontend"

# Image names are fully qualified on purpose. Docker silently expands a bare
# `redis:7-alpine` to Docker Hub; podman refuses to guess and fails with
# "short-name ... did not resolve to an alias and no unqualified-search
# registries are defined". The docker.io/ prefix is valid for both runtimes, so
# spelling it out costs nothing and keeps podman working without the user
# having to write a registries.conf.
PG_CONTAINER="iquana-pg"
PG_IMAGE="docker.io/pgvector/pgvector:pg16"   # not plain postgres: the cross-image concept store needs the `vector` extension
PG_VOLUME="iquana-pg-data"          # named, so removing the container does not take the database with it
REDIS_CONTAINER="iquana-redis"
REDIS_IMAGE="docker.io/library/redis:7-alpine"

# --- output ----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s warning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# --- configuration ---------------------------------------------------------

# Fills in anything an iquana.conf written by an older installer does not have
# yet, so a stale config file can never trip `set -u`. install.sh calls this too
# -- CUDA is deliberately not defaulted here, because the installer treats
# "unset" as "ask, and detect the GPU for the default answer".
apply_conf_defaults() {
    : "${IQUANA_CHANNEL:=stable}"
    : "${IQUANA_HOST:=localhost}"
    : "${FRONTEND_PORT:=3000}"
    : "${BACKEND_PORT:=8000}"
    : "${AI_SERVICE_PORT:=8004}"
    : "${MLFLOW_PORT:=5000}"
    : "${POSTGRES_PORT:=5432}"
    : "${REDIS_PORT:=6379}"
    : "${POSTGRES_USER:=iquana}"
    : "${POSTGRES_DB:=iquana}"
}

load_conf() {
    [ -f "$IQUANA_CONF" ] || die "no iquana.conf found in $IQUANA_ROOT -- run ./install.sh first."
    # shellcheck disable=SC1090
    . "$IQUANA_CONF"
    apply_conf_defaults
    : "${CUDA:=no}"
    : "${POSTGRES_PASSWORD:=}"
}

# --- container runtime -----------------------------------------------------

# Docker is the documented prerequisite, but podman is CLI-compatible for
# everything used here, so it is accepted as a drop-in.
#
# An explicit CONTAINER_RUNTIME always wins. Failing that, prefer a runtime that
# actually answers `info` over the first one merely present on PATH: a docker
# that is installed but unusable -- daemon down, or the user not in the `docker`
# group, which is the common case under WSL -- would otherwise mask a perfectly
# healthy podman and send people off debugging the wrong runtime entirely. When
# none of them respond we still report the first one installed, so the caller
# can say "installed but not responding" rather than "not installed".
detect_runtime() {
    if [ -n "${CONTAINER_RUNTIME:-}" ] && command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
        RUNTIME="$CONTAINER_RUNTIME"
        export RUNTIME
        return 0
    fi

    local candidate installed=
    for candidate in docker podman; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        [ -n "$installed" ] || installed="$candidate"
        if "$candidate" info >/dev/null 2>&1; then
            RUNTIME="$candidate"
            export RUNTIME
            return 0
        fi
    done

    [ -n "$installed" ] || return 1
    RUNTIME="$installed"
    export RUNTIME
}

# What to tell someone whose runtime is installed but not answering. `podman
# machine` only exists where podman needs its own Linux VM (macOS, native
# Windows); under WSL and on Linux podman runs natively, there is no machine,
# and the command can only ever fail with "VM does not exist" -- so never offer
# it there.
runtime_start_hint() {
    local in_wsl=no
    [ -n "${WSL_DISTRO_NAME:-}" ] && in_wsl=yes
    [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] && in_wsl=yes

    case "${RUNTIME:-docker}" in
        *podman*)
            if [ "$in_wsl" = yes ] || [ "$(uname -s)" = Linux ]; then
                printf 'podman runs natively here, so there is no VM to start -- run `podman info` to see the underlying error.'
            else
                printf 'start its VM with `podman machine start`.'
            fi
            ;;
        *)
            if [ "$in_wsl" = yes ]; then
                printf 'start Docker Desktop with WSL integration enabled for this distro; or, if dockerd runs inside WSL, check your user is in the `docker` group -- `sudo usermod -aG docker $USER`, then reopen the shell. If you have podman installed and working, `CONTAINER_RUNTIME=podman` will use that instead.'
            else
                printf 'start Docker Desktop, or the docker daemon.'
            fi
            ;;
    esac
}

runtime_ready() {
    detect_runtime || return 1
    "$RUNTIME" info >/dev/null 2>&1
}

# Starts a container, reusing it if it already exists so its volume (and for
# postgres, its data) survives restarts. $ready is polled until it succeeds --
# a container that is "up" is not necessarily accepting connections yet, and
# services crash on a refused connection.
ensure_container() {
    local name="$1" ready="$2"; shift 2
    local existing
    existing="$("$RUNTIME" ps -a --filter "name=^${name}$" --format '{{.Names}}' 2>/dev/null || true)"
    if [ "$existing" = "$name" ]; then
        "$RUNTIME" start "$name" >/dev/null || die "could not start the '$name' container."
    else
        info "creating container '$name' ..."
        "$RUNTIME" run -d --name "$name" "$@" >/dev/null || die "could not create the '$name' container."
    fi

    local i
    for i in $(seq 1 120); do
        if eval "$ready" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    die "container '$name' did not become ready in 60s. Check: $RUNTIME logs $name"
}

# --- background processes --------------------------------------------------

pid_file() { printf '%s/%s.pid\n' "$RUN_DIR" "$1"; }
log_file() { printf '%s/%s.log\n' "$LOG_DIR" "$1"; }

process_running() {
    local pidfile; pidfile="$(pid_file "$1")"
    [ -f "$pidfile" ] || return 1
    local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

# The recorded pid is the `bash -c` wrapper. Deliberately no setsid: it forks,
# so `$!` would be the pid of a process that exits immediately, leaving the real
# service unkillable. Signalling the whole process *group* is not an option
# either without setsid -- that group also contains this script. So the wrapper
# is recorded and stop_process walks its descendants (uv -> python, bun -> node).
run_bg() {
    local name="$1" workdir="$2" cmd="$3"
    mkdir -p "$RUN_DIR" "$LOG_DIR"
    if process_running "$name"; then
        info "$name is already running (pid $(cat "$(pid_file "$name")"))"
        return 0
    fi
    local log; log="$(log_file "$name")"
    : > "$log"
    ( cd "$workdir" && nohup bash -c "$cmd" >>"$log" 2>&1 & echo $! > "$(pid_file "$name")" )
}

# pgrep is present on every supported platform, but ps is the universal
# fallback: without a descendant list, killing the wrapper would orphan the
# python/node process that actually holds the port.
children_of() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -P "$1" 2>/dev/null || true
    else
        ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$1" '$2 == parent {print $1}'
    fi
}

descendants() {
    local child
    for child in $(children_of "$1"); do
        descendants "$child"   # deepest first, so a parent cannot respawn them
        printf '%s\n' "$child"
    done
}

stop_process() {
    local name="$1" pidfile pid p
    pidfile="$(pid_file "$name")"
    [ -f "$pidfile" ] || return 0
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    rm -f "$pidfile"
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    local tree; tree="$(descendants "$pid") $pid"
    for p in $tree; do kill -TERM "$p" 2>/dev/null || true; done

    local i
    for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    for p in $tree; do kill -KILL "$p" 2>/dev/null || true; done
}

# --- ports -----------------------------------------------------------------

# bash's /dev/tcp is used instead of lsof/ss/netstat: those are named
# differently (or missing) across the distros and macOS this has to run on.
port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_for_port() {
    local port="$1" name="$2" timeout="${3:-90}" i
    for i in $(seq 1 $((timeout * 2))); do
        port_open "$port" && return 0
        process_running "$name" || {
            warn "$name exited during startup -- last lines of $(log_file "$name"):"
            tail -n 20 "$(log_file "$name")" >&2 || true
            return 1
        }
        sleep 0.5
    done
    warn "$name did not open port $port within ${timeout}s (it may still be starting; see ./iquana.sh logs $name)"
    return 1
}

# --- services --------------------------------------------------------------

start_service() {
    local name="$1"
    case "$name" in
        postgres)
            ensure_container "$PG_CONTAINER" \
                "$RUNTIME exec $PG_CONTAINER pg_isready -U $POSTGRES_USER -d $POSTGRES_DB" \
                -p "${POSTGRES_PORT}:5432" \
                -v "${PG_VOLUME}:/var/lib/postgresql/data" \
                -e "POSTGRES_USER=$POSTGRES_USER" \
                -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
                -e "POSTGRES_DB=$POSTGRES_DB" \
                "$PG_IMAGE"
            ok "postgres ready on port $POSTGRES_PORT"
            ;;
        redis)
            ensure_container "$REDIS_CONTAINER" \
                "$RUNTIME exec $REDIS_CONTAINER redis-cli ping" \
                -p "${REDIS_PORT}:6379" \
                "$REDIS_IMAGE"
            ok "redis ready on port $REDIS_PORT"
            ;;
        mlflow)
            mkdir -p "$MLFLOW_HOME/mlartifacts"
            run_bg mlflow "$IQUANA_ROOT" \
                "uv run --directory '$IQUANA_ROOT/backend' --frozen mlflow server \
                    --host 127.0.0.1 --port $MLFLOW_PORT \
                    --backend-store-uri 'sqlite:///$MLFLOW_HOME/mlflow.db' \
                    --artifacts-destination 'file://$MLFLOW_HOME/mlartifacts'"
            wait_for_port "$MLFLOW_PORT" mlflow 120 && ok "mlflow ready on http://localhost:$MLFLOW_PORT"
            ;;
        ai-service)
            run_bg ai-service "$IQUANA_ROOT" \
                "uv run --directory '$IQUANA_ROOT/ai-service' --frozen fastapi run main.py --host 127.0.0.1 --port $AI_SERVICE_PORT"
            # First start imports torch and builds the model registry, which is
            # slow on a cold HuggingFace cache -- hence the generous timeout.
            wait_for_port "$AI_SERVICE_PORT" ai-service 300 && ok "ai-service ready on http://localhost:$AI_SERVICE_PORT"
            ;;
        ai-worker)
            local pool="prefork"
            # On macOS, forking a process that has already imported torch is
            # unreliable (the Objective-C runtime aborts in the child), so the
            # worker runs single-process there instead.
            [ "$(uname -s)" = "Darwin" ] && pool="solo"
            # -Q ai.training,celery: training jobs are routed to the ai.training
            # queue, so the worker must consume it alongside the default one.
            # Concurrency stays at 1 on purpose: training is GPU-bound and two
            # concurrent jobs would fight over the same device.
            run_bg ai-worker "$IQUANA_ROOT" \
                "export REDIS_URL='redis://localhost:$REDIS_PORT'; \
                 uv run --directory '$IQUANA_ROOT/ai-service' --frozen celery -A celery_app worker \
                    -Q ai.training,celery --pool=$pool --concurrency=1 --loglevel=info"
            sleep 2
            process_running ai-worker && ok "ai-worker started" || warn "ai-worker exited immediately -- see ./iquana.sh logs ai-worker"
            ;;
        backend)
            run_bg backend "$IQUANA_ROOT" \
                "uv run --directory '$IQUANA_ROOT/backend' --frozen fastapi run main.py --host 0.0.0.0 --port $BACKEND_PORT"
            wait_for_port "$BACKEND_PORT" backend 180 && ok "backend ready on http://${IQUANA_HOST}:$BACKEND_PORT (docs at /docs)"
            ;;
        backend-worker)
            # Batch inference: the backend's own Celery app, walking one dataset-wide
            # inference run image by image. It lives here rather than in the ai-service
            # because every unit reads and writes the gateway's database; the GPU work is
            # still an HTTP call into the ai-service.
            #
            # -Q backend.jobs, and NOT the default "celery" queue: ai-worker above consumes
            # that one as a fallback, and both apps share this Redis. A message landing on
            # the shared queue is whichever worker grabs it first -- and the ai-service has
            # no inference.* task registered, so it would discard it and the run would stop
            # dead with nothing to retry it. Keep these two -Q lists disjoint.
            #
            # Concurrency 1 for the same reason as ai-worker: every unit ends up on the one
            # GPU behind the ai-service, so a second worker buys contention, not throughput.
            #
            # solo on macOS, same as ai-worker. The backend never runs a model, but torch
            # still lands in its venv transitively (via iquana-toolbox -> mlflow), and
            # forking a process that has imported torch aborts in the child on Darwin.
            local backend_pool="prefork"
            [ "$(uname -s)" = "Darwin" ] && backend_pool="solo"
            run_bg backend-worker "$IQUANA_ROOT" \
                "export REDIS_URL='redis://localhost:$REDIS_PORT'; \
                 uv run --directory '$IQUANA_ROOT/backend' --frozen celery -A app.services.celery_app worker \
                    -Q backend.jobs --pool=$backend_pool --concurrency=1 --loglevel=info"
            sleep 2
            process_running backend-worker && ok "backend-worker started" || warn "backend-worker exited immediately -- see ./iquana.sh logs backend-worker"
            ;;
        frontend)
            # BROWSER=none stops react-scripts from trying to open a browser on
            # a headless machine; PORT is how it picks its listen port.
            run_bg frontend "$IQUANA_ROOT" \
                "export PORT=$FRONTEND_PORT BROWSER=none; cd '$IQUANA_ROOT/frontend-react' && bun run dev"
            wait_for_port "$FRONTEND_PORT" frontend 180 && ok "frontend ready on http://${IQUANA_HOST}:$FRONTEND_PORT"
            ;;
        *)
            die "unknown service '$name'. Known services: $SERVICES"
            ;;
    esac
}

stop_service() {
    local name="$1"
    case "$name" in
        # `stop`, never `rm`: the postgres data lives in a volume reachable
        # through this container, and removing it would orphan the database.
        postgres) "$RUNTIME" stop "$PG_CONTAINER" >/dev/null 2>&1 && ok "stopped postgres" || info "postgres was not running" ;;
        redis)    "$RUNTIME" stop "$REDIS_CONTAINER" >/dev/null 2>&1 && ok "stopped redis" || info "redis was not running" ;;
        *)
            if process_running "$name"; then
                stop_process "$name"; ok "stopped $name"
            else
                rm -f "$(pid_file "$name")"
                info "$name was not running"
            fi
            ;;
    esac
}

needs_runtime() {
    case "$1" in postgres|redis) return 0 ;; *) return 1 ;; esac
}

resolve_services() {
    if [ "$#" -eq 0 ]; then printf '%s\n' $SERVICES; return; fi
    local requested name known
    for requested in "$@"; do
        known=no
        for name in $SERVICES; do
            [ "$requested" = "$name" ] && known=yes
        done
        [ "$known" = yes ] || die "unknown service '$requested'. Known services: $SERVICES"
        printf '%s\n' "$requested"
    done
}

reverse_lines() { awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }'; }

# --- commands --------------------------------------------------------------

cmd_start() {
    load_conf
    local list; list="$(resolve_services "$@")"
    local name
    for name in $list; do
        if needs_runtime "$name"; then
            runtime_ready || die "no working container runtime found. Install Docker (https://docs.docker.com/get-docker/) and make sure the daemon is running -- postgres and redis cannot run without it."
            break
        fi
    done
    step "Starting IQUANA (${IQUANA_CHANNEL} channel)"
    for name in $list; do start_service "$name"; done
    say ""
    ok "IQUANA is up: ${C_BOLD}http://${IQUANA_HOST}:${FRONTEND_PORT}${C_RESET}"
    info "logs: ./iquana.sh logs <service>    status: ./iquana.sh status"
}

cmd_stop() {
    load_conf
    local list; list="$(resolve_services "$@" | reverse_lines)"
    local name uses_runtime=no
    for name in $list; do needs_runtime "$name" && uses_runtime=yes; done
    if [ "$uses_runtime" = yes ] && ! runtime_ready; then
        warn "no container runtime available -- skipping postgres/redis."
    fi
    step "Stopping IQUANA"
    for name in $list; do
        if needs_runtime "$name" && ! runtime_ready; then continue; fi
        stop_service "$name"
    done
}

cmd_restart() {
    cmd_stop "$@"
    say ""
    cmd_start "$@"
}

cmd_status() {
    load_conf
    step "IQUANA status"
    info "channel: $IQUANA_CHANNEL    host: $IQUANA_HOST    CUDA: $CUDA"
    say ""
    printf '    %-14s %-10s %-8s %s\n' SERVICE STATE PORT DETAIL
    local name state port detail
    for name in $SERVICES; do
        case "$name" in
            postgres) port="$POSTGRES_PORT" ;;
            redis)    port="$REDIS_PORT" ;;
            mlflow)   port="$MLFLOW_PORT" ;;
            ai-service) port="$AI_SERVICE_PORT" ;;
            backend)  port="$BACKEND_PORT" ;;
            frontend) port="$FRONTEND_PORT" ;;
            *)        port="-" ;;
        esac
        detail=""
        if needs_runtime "$name"; then
            local container; [ "$name" = postgres ] && container="$PG_CONTAINER" || container="$REDIS_CONTAINER"
            if runtime_ready && [ "$("$RUNTIME" ps --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null)" = "$container" ]; then
                state="running"; detail="$RUNTIME/$container"
            else
                state="stopped"
            fi
        elif process_running "$name"; then
            state="running"; detail="pid $(cat "$(pid_file "$name")")"
        else
            state="stopped"
        fi
        [ "$state" = running ] && printf '    %-14s %s%-10s%s %-8s %s\n' "$name" "$C_GREEN" "$state" "$C_RESET" "$port" "$detail" \
                               || printf '    %-14s %s%-10s%s %-8s %s\n' "$name" "$C_DIM" "$state" "$C_RESET" "$port" "$detail"
    done

    say ""
    info "checked-out revisions:"
    local repo
    for repo in backend frontend-react ai-service; do
        if [ -d "$IQUANA_ROOT/$repo/.git" ]; then
            printf '    %-22s %s (%s)\n' "$repo" \
                "$(git -C "$IQUANA_ROOT/$repo" rev-parse --short HEAD)" \
                "$(git -C "$IQUANA_ROOT/$repo" rev-parse --abbrev-ref HEAD)"
        else
            printf '    %-22s %s\n' "$repo" "not installed"
        fi
    done
}

cmd_logs() {
    load_conf
    local name="${1:-}"; shift || true
    [ -n "$name" ] || die "usage: ./iquana.sh logs <service> [-f]"
    if needs_runtime "$name"; then
        runtime_ready || die "no container runtime available."
        local container; [ "$name" = postgres ] && container="$PG_CONTAINER" || container="$REDIS_CONTAINER"
        "$RUNTIME" logs "$@" "$container"
        return
    fi
    local log; log="$(log_file "$name")"
    [ -f "$log" ] || die "no log for '$name' yet -- has it been started?"
    if [ "${1:-}" = "-f" ]; then tail -f "$log"; else tail -n 200 "$log"; fi
}

usage() {
    cat <<EOF
IQUANA service control

  ./iquana.sh start [service ...]    start everything (or only the named services)
  ./iquana.sh stop  [service ...]    stop everything (or only the named services)
  ./iquana.sh restart [service ...]  stop, then start
  ./iquana.sh status                 what is running, on which port, at which commit
  ./iquana.sh logs <service> [-f]    show (and optionally follow) a service log

Services: $SERVICES

Run ./install.sh to set up or update the installation.
EOF
}

# Only dispatch when executed directly -- install.sh sources this file for its
# service-control functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        start)   shift; cmd_start "$@" ;;
        stop)    shift; cmd_stop "$@" ;;
        restart) shift; cmd_restart "$@" ;;
        status)  shift; cmd_status "$@" ;;
        logs)    shift; cmd_logs "$@" ;;
        ""|-h|--help|help) usage ;;
        *) die "unknown command '$1'. Run ./iquana.sh --help." ;;
    esac
fi
