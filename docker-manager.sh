#!/usr/bin/env bash
# =============================================================================
#  Docker Stack Manager - Rootless Docker
#  Target: CachyOS (Arch), NVIDIA GPU, Docker Compose v2
# =============================================================================

export DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$UID/docker.sock}"

APP_VERSION="2.5"
CONFIG_DIR="$HOME/.config"
REGISTRY_FILE="$CONFIG_DIR/docker-registry.txt"
LOG_FILE="$HOME/.local/state/docker-manager.log"
CDI_DIR="/etc/cdi"
CDI_SPEC="$CDI_DIR/nvidia.json"   # the spec this manager writes
CDI_DIRS=("/etc/cdi" "/var/run/cdi" "${XDG_CONFIG_HOME:-$HOME/.config}/cdi")  # every place specs are read from
DRIVER_RE='[0-9]{3}\.[0-9]{2,3}\.[0-9]{2}'
# Launch errors that mean the NVIDIA CDI spec is stale or points at missing files.
NVIDIA_ERR_RE='libEGL_nvidia|libnvidia|nvidia-container-cli|unresolvable CDI devices|failed to fulfil mount request.*nvidia'
WIDTH=76

# ----- colours (real escape bytes, safe inside printf arguments) -----
RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'; GRY=$'\033[90m'

# ----- runtime state -----
COMPOSE=()
COMPOSE_NAME="?"
COMPOSE_VERSION="?"
DOCKER_VERSION="?"
GPU_DRIVER="not detected"
ENTRIES=()
CONTAINERS=()
VIEW=()
declare -A RUNNING=()
declare -A CREATED=()
PS_OK=1
PS_ERR=""
BAD_COUNT=0
ANS=""
ST_TEXT=""
ST_COLOR=""
SEL_LINE=""; SEL_NAME=""; SEL_PATH=""
SEL_CID=""; SEL_CNAME=""; SEL_STATE=""; SEL_PROJECT=""

# =============================================================================
# Output helpers
# =============================================================================

ok()   { printf '  %s✓ %s%s\n' "$GRN" "$*" "$RST"; }
err()  { printf '  %s✗ %s%s\n' "$RED$BOLD" "$*" "$RST"; }
warn() { printf '  %s! %s%s\n' "$YEL" "$*" "$RST"; }
info() { printf '  %s› %s%s\n' "$CYN" "$*" "$RST"; }
dim()  { printf '  %s%s%s\n' "$GRY" "$*" "$RST"; }

repeat() { local s="$1" n="$2" i; for ((i = 0; i < n; i++)); do printf '%s' "$s"; done; }
rule()   { printf '%s' "$GRY"; repeat '─' "$WIDTH"; printf '%s\n' "$RST"; }

trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

trunc() {
    local s="$1" n="$2"
    if (( ${#s} > n )); then printf '%s…' "${s:0:n-1}"; else printf '%s' "$s"; fi
}

short_path() {
    if [[ "$1" == "$HOME"/* ]]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi
}

state_color() {
    case "$1" in
        running|restarting) printf '%s' "$GRN" ;;
        created|paused)     printf '%s' "$YEL" ;;
        dead)               printf '%s' "$RED" ;;
        exited)             printf '%s' "$GRY" ;;
        *)                  printf '%s' "$RST" ;;
    esac
}

# Prompt and read into ANS. Exits cleanly on EOF so the menu cannot spin.
ask() {
    printf '%s%s%s' "$BOLD" "$1" "$RST"
    IFS= read -r ANS || { echo; exit 0; }
    ANS=$(trim "$ANS")
}

confirm() {
    ask "$1 [y/N] "
    [[ "$ANS" =~ ^[Yy]$ ]]
}

pause() {
    printf '\n%sPress Enter to continue...%s' "$DIM" "$RST"
    { IFS= read -r _ </dev/tty; } 2>/dev/null || true
    echo
}

# Pipe text into less when on a terminal, otherwise print and pause.
show_text() {
    if command -v less >/dev/null 2>&1 && [ -t 1 ]; then
        less -R +G
    else
        cat
        pause
    fi
}

on_interrupt() {
    printf '\n  %sInterrupted.%s\n' "$DIM" "$RST"
    exit 130
}

# =============================================================================
# Logging and startup
# =============================================================================

init_log() {
    if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
        return
    fi
    LOG_FILE="/tmp/docker-manager-$UID.log"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
}

log() {
    local lvl="$1"; shift
    [ -n "$LOG_FILE" ] || return 0
    printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >> "$LOG_FILE" 2>/dev/null
}

fatal() {
    err "$1"
    log ERROR "$1"
    printf '\n%sPress Enter to exit...%s' "$DIM" "$RST"
    { IFS= read -r _ </dev/tty; } 2>/dev/null || true
    echo
    exit 1
}

init_registry() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null || fatal "Cannot create $CONFIG_DIR."
    touch "$REGISTRY_FILE" 2>/dev/null || fatal "Cannot write registry: $REGISTRY_FILE"
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
        COMPOSE_NAME="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
        COMPOSE_NAME="docker-compose (legacy)"
    else
        return 1
    fi
    COMPOSE_VERSION=$("${COMPOSE[@]}" version --short 2>/dev/null)
    COMPOSE_VERSION="${COMPOSE_VERSION:-?}"
}

init() {
    init_log
    init_registry
    command -v docker >/dev/null 2>&1 || fatal "'docker' is not installed or not in PATH."
    command -v systemctl >/dev/null 2>&1 || fatal "'systemctl' not found."
    systemctl --user is-active --quiet docker \
        || fatal "Rootless Docker is not active. Start it with your panel toggle first."
    detect_compose || fatal "Neither 'docker compose' nor 'docker-compose' is available."
    docker info >/dev/null 2>&1 \
        || fatal "Cannot reach the Rootless Docker socket ($DOCKER_HOST)."

    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    DOCKER_VERSION="${DOCKER_VERSION:-?}"

    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
            | head -n1 | tr -d '[:space:]')
        GPU_DRIVER="${GPU_DRIVER:-not detected}"
    fi

    log INFO "Manager started (v$APP_VERSION)"
}

# =============================================================================
# Registry
# =============================================================================

load_entries() {
    mapfile -t ENTRIES < <(awk -F'|' 'NF == 2 && $1 != "" && $2 != ""' "$REGISTRY_FILE" 2>/dev/null)
}

# Adds each comma-separated config path in $2 to the counting map named $1.
add_counts() {
    local -n _map="$1"
    local cfg="$2" p
    local -a parts
    IFS=',' read -ra parts <<< "$cfg"
    for p in "${parts[@]}"; do
        p=$(trim "$p")
        [ -n "$p" ] && _map[$p]=$(( ${_map[$p]:-0} + 1 ))
    done
}

# Reads every container once. Fills CONTAINERS, RUNNING, CREATED, BAD_COUNT.
load_containers() {
    local out rc line id name state status image project cfg
    CONTAINERS=()
    RUNNING=()
    CREATED=()
    BAD_COUNT=0

    out=$(docker ps -a --format '{{.ID}}|{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.config_files"}}' 2>&1)
    rc=$?
    if (( rc != 0 )); then
        PS_OK=0
        PS_ERR=$(printf '%s' "$out" | head -n1)
        log WARN "docker ps failed: $PS_ERR"
        return 1
    fi
    PS_OK=1
    PS_ERR=""

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        line=${line//<no value>/}
        CONTAINERS+=("$line")
        IFS='|' read -r id name state status image project cfg <<< "$line"
        case "$state" in
            running|restarting) add_counts RUNNING "$cfg" ;;
            created)            add_counts CREATED "$cfg"; BAD_COUNT=$((BAD_COUNT + 1)) ;;
            dead)               BAD_COUNT=$((BAD_COUNT + 1)) ;;
        esac
    done <<< "$out"
    return 0
}

stack_status() {
    local path="$1" r c
    if [ ! -f "$path" ]; then
        ST_TEXT="MISSING FILE"; ST_COLOR="$RED"; return
    fi
    if (( PS_OK == 0 )); then
        ST_TEXT="UNKNOWN"; ST_COLOR="$YEL"; return
    fi
    r=${RUNNING[$path]:-0}
    c=${CREATED[$path]:-0}
    if (( r > 0 )); then
        ST_TEXT="ACTIVE ($r running)"; ST_COLOR="$GRN"
    elif (( c > 0 )); then
        ST_TEXT="BROKEN ($c created)"; ST_COLOR="$YEL"
    else
        ST_TEXT="INACTIVE"; ST_COLOR="$GRY"
    fi
}

# =============================================================================
# Selection
# =============================================================================

# Return codes: 0 selected, 1 error (already shown), 2 cancelled.
pick_stack() {
    load_entries
    local count=${#ENTRIES[@]} n
    if (( count == 0 )); then
        warn "No stacks registered yet. Use option 4 first."
        return 1
    fi
    ask "  Stack # (blank to cancel): "
    n="$ANS"
    [ -z "$n" ] && return 2
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( 10#$n < 1 || 10#$n > count )); then
        err "Invalid choice. Enter a number from 1 to $count."
        return 1
    fi
    SEL_LINE="${ENTRIES[$((10#$n - 1))]}"
    IFS='|' read -r SEL_NAME SEL_PATH <<< "$SEL_LINE"
    return 0
}

print_container_table() {
    local n=0 idx id name state status image project _
    local sc sn ss si
    printf '  %s%-4s %-12s %-22s %-11s %-28s %s%s\n' \
        "$BOLD" "#" "ID" "NAME" "STATE" "IMAGE" "STACK" "$RST"
    rule
    for idx in "${VIEW[@]}"; do
        n=$((n + 1))
        IFS='|' read -r id name state status image project _ <<< "${CONTAINERS[$idx]}"
        sc=$(state_color "$state")
        printf -v sn '%-22s' "$(trunc "$name" 22)"
        printf -v ss '%-11s' "$state"
        printf -v si '%-28s' "$(trunc "$image" 28)"
        printf '  %-4s %-12s %s %s%s%s %s %s\n' \
            "$n." "${id:0:12}" "$sn" "$sc" "$ss" "$RST" "$si" "${project:--}"
    done
    echo ""
}

# Return codes: 0 selected, 1 error, 2 cancelled, 3 nothing to pick.
pick_container() {
    local filter="$1" i state n
    local _id _name _status _image _project _cfg
    VIEW=()
    load_containers || { err "Cannot query Docker: $PS_ERR"; return 1; }

    for i in "${!CONTAINERS[@]}"; do
        IFS='|' read -r _id _name state _status _image _project _cfg <<< "${CONTAINERS[$i]}"
        if [ "$filter" = stopped ]; then
            case "$state" in created|exited|dead) ;; *) continue ;; esac
        fi
        VIEW+=("$i")
    done

    if (( ${#VIEW[@]} == 0 )); then
        dim "No matching containers."
        return 3
    fi

    echo ""
    print_container_table
    ask "  Container # (blank to cancel): "
    n="$ANS"
    [ -z "$n" ] && return 2
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( 10#$n < 1 || 10#$n > ${#VIEW[@]} )); then
        err "Invalid choice. Enter a number from 1 to ${#VIEW[@]}."
        return 1
    fi
    load_selected "${VIEW[$((10#$n - 1))]}"
    return 0
}

load_selected() {
    local line="${CONTAINERS[$1]}"
    local _status _image _cfg
    IFS='|' read -r SEL_CID SEL_CNAME SEL_STATE _status _image SEL_PROJECT _cfg <<< "$line"
}

# =============================================================================
# NVIDIA CDI checks
# =============================================================================

# Prints each hostPath in one CDI spec file that does not exist on this machine.
# Works for both JSON ("hostPath": "/x") and YAML (hostPath: /x) specs.
spec_missing_paths() {
    local f="$1" p
    [ -r "$f" ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || printf '%s\n' "$p"
    done < <(grep -oE 'hostPath"?[[:space:]]*:[[:space:]]*"?[^",[:space:]}]+' "$f" 2>/dev/null \
             | sed -E 's/^hostPath"?[[:space:]]*:[[:space:]]*"?//' | sort -u)
}

# Prints every NVIDIA spec file in any directory Docker or the CDI tools read.
all_nvidia_specs() {
    local d f
    shopt -s nullglob
    for d in "${CDI_DIRS[@]}"; do
        for f in "$d"/nvidia.*; do
            [ -e "$f" ] && printf '%s\n' "$f"
        done
    done
    shopt -u nullglob
}

# Prints "file: path" for every missing host file referenced by any NVIDIA spec.
missing_cdi_mounts() {
    local f
    while IFS= read -r f; do
        spec_missing_paths "$f" | sed "s|^|$f: |"
    done < <(all_nvidia_specs)
}

# Prints the NVIDIA specs that must be removed for driver $1:
#  - every spec other than the one this manager writes (stale, or a duplicate
#    that would register the GPU twice), and
#  - this manager's own spec, if it pins a different driver version.
find_stale_cdi() {
    local driver="$1" f v
    while IFS= read -r f; do
        if [ "$f" != "$CDI_SPEC" ]; then
            printf '%s\n' "$f"
            continue
        fi
        [ -r "$f" ] || continue
        v=$(grep -oE "$DRIVER_RE" "$f" 2>/dev/null | sort -u | grep -vxF -- "$driver")
        [ -n "$v" ] && printf '%s\n' "$f"
    done < <(all_nvidia_specs)
}

# Deletes every spec find_stale_cdi reports. No prompt: these are NVIDIA specs
# this manager owns, and leaving them in place lets Docker use stale mounts.
remove_stale_cdi() {
    local driver="$1" f
    local -a stale=()
    while IFS= read -r f; do
        [ -n "$f" ] && stale+=("$f")
    done < <(find_stale_cdi "$driver")

    (( ${#stale[@]} > 0 )) || return 0

    warn "Removing ${#stale[@]} NVIDIA CDI spec(s) that do not match driver $driver:"
    for f in "${stale[@]}"; do
        if [ -w "$f" ] && [ -w "$(dirname -- "$f")" ]; then
            rm -f -- "$f"
        else
            sudo rm -f -- "$f"
        fi
        if [ -e "$f" ]; then
            err "Could not delete $f"
            log ERROR "Failed to delete CDI spec $f"
        else
            ok "Deleted $f"
            log WARN "Deleted stale CDI spec $f"
        fi
    done
}

# Set to 1 when a launch-time repair ran, so containers are recreated.
CDI_REPAIRED=0

# Before a launch: if any NVIDIA spec is stale, duplicated or points at missing
# files, regenerate and clean up first. Returns 1 only when a repair failed.
ensure_cdi_current() {
    local issues
    CDI_REPAIRED=0
    command -v nvidia-ctk >/dev/null 2>&1 || return 0
    [[ "$GPU_DRIVER" =~ ^[0-9.]+$ ]] || return 0

    issues=$( { find_stale_cdi "$GPU_DRIVER"; missing_cdi_mounts; } )
    [ -z "$issues" ] && return 0

    warn "NVIDIA CDI config is out of date for driver $GPU_DRIVER. Repairing it before launch."
    log WARN "Preflight found stale or missing NVIDIA CDI config"
    regenerate_cdi_core || return 1
    CDI_REPAIRED=1
    return 0
}

# True if a captured `up` output contains an NVIDIA/CDI launch error.
is_nvidia_spec_error() {
    [ -s "$1" ] || return 1
    # Strip terminal escape codes first: the captured output comes from a pseudo-terminal.
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$1" | grep -qE -- "$NVIDIA_ERR_RE"
}

# Warns if the GPU runtime does not advertise any NVIDIA devices after the restart.
verify_cdi_devices() {
    if nvidia-ctk cdi list 2>/dev/null | grep -q 'nvidia.com/gpu='; then
        ok "CDI lists NVIDIA GPU devices."
        log INFO "CDI verification passed"
    else
        warn "CDI does not list any nvidia.com/gpu devices. Check: nvidia-ctk cdi list"
        log WARN "CDI verification found no nvidia.com/gpu devices"
    fi
}

# =============================================================================
# Display
# =============================================================================

kv() { printf '  %s%-10s%s %s\n' "$BOLD" "$1" "$RST" "$2"; }

draw_header() {
    local title="Docker Stack Manager"
    local right="rootless  v$APP_VERSION"
    local gap=$(( WIDTH - 6 - ${#title} - ${#right} ))
    (( gap < 1 )) && gap=1
    printf '%s╭' "$CYN"; repeat '─' $((WIDTH - 2)); printf '╮%s\n' "$RST"
    printf '%s│%s  %s%s%s%*s%s%s%s  %s│%s\n' \
        "$CYN" "$RST" "$BOLD$MAG" "$title" "$RST" "$gap" "" "$GRY" "$right" "$RST" "$CYN" "$RST"
    printf '%s╰' "$CYN"; repeat '─' $((WIDTH - 2)); printf '╯%s\n' "$RST"
}

draw_status() {
    local dot
    if (( PS_OK )); then
        dot="${GRN}● connected${RST}"
    else
        dot="${RED}● unreachable${RST}"
    fi
    echo ""
    kv "Docker"  "$dot  ${GRY}v${DOCKER_VERSION}${RST}"
    kv "Compose" "$COMPOSE_NAME  ${GRY}v${COMPOSE_VERSION}${RST}"
    kv "GPU"     "$GPU_DRIVER"
    kv "Log"     "$(short_path "$LOG_FILE")"
    if (( PS_OK == 0 )); then
        printf '  %s! Docker query failed: %s%s\n' "$RED" "$PS_ERR" "$RST"
    fi
}

draw_stacks() {
    local i=0 line name path s_name s_stat
    load_entries
    echo ""
    printf '  %sSTACKS%s  %s(%d registered)%s\n' "$BOLD$CYN" "$RST" "$GRY" "${#ENTRIES[@]}" "$RST"
    rule
    if (( ${#ENTRIES[@]} == 0 )); then
        printf '  %sNo stacks registered. Choose 4 to add a compose file.%s\n' "$YEL" "$RST"
        return
    fi
    printf '  %s%-4s %-22s %-22s %s%s\n' "$BOLD" "ID" "NAME" "STATUS" "PATH" "$RST"
    for line in "${ENTRIES[@]}"; do
        i=$((i + 1))
        IFS='|' read -r name path <<< "$line"
        stack_status "$path"
        printf -v s_name '%-22s' "$(trunc "$name" 22)"
        printf -v s_stat '%-22s' "$ST_TEXT"
        printf '  %-4s %s %s%s%s %s\n' \
            "$i." "$s_name" "$ST_COLOR" "$s_stat" "$RST" "$(short_path "$path")"
    done
}

# NVIDIA problems come first: they are the usual cause of stuck containers.
draw_alerts() {
    local first stale
    first=$(missing_cdi_mounts | head -n1)
    if [ -n "$first" ]; then
        echo ""
        warn "The NVIDIA CDI spec points at files that are not on this system (e.g. ${first#*: })."
        warn "Use option 10 to regenerate it."
    fi

    if [[ "$GPU_DRIVER" =~ ^[0-9.]+$ ]]; then
        stale=$(find_stale_cdi "$GPU_DRIVER")
        if [ -n "$stale" ]; then
            echo ""
            warn "NVIDIA CDI config is stale or duplicated. It will be repaired before the next launch, or use option 10 now."
        fi
    fi

    if (( BAD_COUNT > 0 )); then
        echo ""
        warn "$BAD_COUNT container(s) are stuck in 'created' or 'dead' state. Use option 8 to clean up."
    fi
}

# Two side-by-side columns. Left column is $w visible characters wide.
menu_grid() {
    local t1="$1" t2="$3" w=40 r rows lk ll rk rl pl
    local -n a1="$2"
    local -n a2="$4"

    printf '  %s' "$BOLD$CYN"
    printf '%-*s' $((w - 2)) "$t1"
    printf '%s%s%s\n' "$BOLD$CYN" "$t2" "$RST"

    rows=${#a1[@]}
    (( ${#a2[@]} > rows )) && rows=${#a2[@]}

    for ((r = 0; r < rows; r++)); do
        if (( r < ${#a1[@]} )); then
            IFS='|' read -r lk ll <<< "${a1[r]}"
            printf -v pl '%-*s' $((w - 6)) "$ll"
            printf '  %s%2s)%s %s' "$BOLD" "$lk" "$RST" "$pl"
        else
            printf '%*s' "$w" ''
        fi
        if (( r < ${#a2[@]} )); then
            IFS='|' read -r rk rl <<< "${a2[r]}"
            printf '  %s%2s)%s %s' "$BOLD" "$rk" "$RST" "$rl"
        fi
        echo
    done
}

draw_menu() {
    local -a stack_items=("1|Launch stack" "2|Stop stack" "3|Restart stack" "4|Register stack" "5|Deregister stack")
    local -a cont_items=("6|List containers" "7|Remove a container" "8|Clean up stopped" "9|View logs")
    local -a tool_items=("10|Regenerate NVIDIA CDI" "11|Open lazydocker")
    local -a sys_items=("12|View manager log" "q|Quit")
    echo ""
    menu_grid "STACKS" stack_items "CONTAINERS" cont_items
    echo ""
    menu_grid "TOOLS" tool_items "SYSTEM" sys_items
    echo ""
}

draw_screen() {
    load_containers
    clear
    draw_header
    draw_status
    draw_stacks
    draw_alerts
    draw_menu
}

# =============================================================================
# Stack actions
# =============================================================================

# Runs a compose command inside a pseudo-terminal so its live progress display works,
# saving the output to $1. Falls back to a plain run if 'script' is not installed.
run_compose_tty() {
    local logf="$1"; shift
    if command -v script >/dev/null 2>&1; then
        script -qefc "$(printf '%q ' "$@")" "$logf"
    else
        "$@"
    fi
}

# Relaunches a stack after regenerating the NVIDIA spec. Returns 0 on success.
nvidia_launch_recovery() {
    local path="$1" rc
    warn "The launch error matches a stale NVIDIA CDI spec. Regenerating it usually fixes this."
    confirm "Regenerate the NVIDIA spec and retry the launch now?" || return 1

    echo ""
    if ! regenerate_cdi_core; then
        err "Spec regeneration did not complete. The launch was not retried."
        log ERROR "CDI regeneration during launch of '$SEL_NAME' did not complete"
        return 1
    fi

    info "Retrying launch of $SEL_NAME..."
    log INFO "Retrying launch of '$SEL_NAME' after CDI regeneration"
    run_compose_tty /dev/null "${COMPOSE[@]}" -f "$path" up -d --force-recreate
    rc=$?
    echo ""

    if (( rc == 0 )); then
        ok "Launch complete after regenerating the spec: $SEL_NAME"
        log INFO "Launch of '$SEL_NAME' succeeded after CDI regeneration"
        return 0
    fi
    err "Retry failed (exit $rc). See the output above."
    log ERROR "Retry of '$SEL_NAME' failed after CDI regeneration (exit $rc)"
    return 1
}

# $1 = up | down | restart    $2 = label used in messages
run_stack_cmd() {
    local action="$1" label="$2" rc outlog=""
    pick_stack; rc=$?
    (( rc == 2 )) && return
    if (( rc != 0 )); then pause; return; fi

    if [ ! -f "$SEL_PATH" ]; then
        err "Compose file is missing: $SEL_PATH"
        log ERROR "$label failed: missing compose file for '$SEL_NAME' ($SEL_PATH)"
        pause; return
    fi

    if [ "$action" = down ]; then
        confirm "Stop '$SEL_NAME'? This removes its containers (volumes are kept)." \
            || { warn "Cancelled."; sleep 1; return; }
    fi

    if [ "$action" = up ] && ! ensure_cdi_current; then
        err "Launch cancelled: the NVIDIA configuration could not be repaired."
        log ERROR "Launch of '$SEL_NAME' cancelled: CDI repair failed"
        pause; return
    fi

    local -a recreate=()
    (( CDI_REPAIRED )) && recreate=(--force-recreate)

    echo ""
    info "${label}ing $SEL_NAME..."
    log INFO "$label '$SEL_NAME' ($SEL_PATH)"

    case "$action" in
        up)
            # Docker Compose only draws its live progress on a real terminal, so run it
            # inside a pseudo-terminal (script) while keeping a copy of the output.
            outlog=$(mktemp "${TMPDIR:-/tmp}/docker-manager-up.XXXXXX" 2>/dev/null) || outlog=""
            run_compose_tty "${outlog:-/dev/null}" "${COMPOSE[@]}" -f "$SEL_PATH" up -d "${recreate[@]}"
            rc=$?
            ;;
        down)    "${COMPOSE[@]}" -f "$SEL_PATH" down;    rc=$? ;;
        restart) "${COMPOSE[@]}" -f "$SEL_PATH" restart; rc=$? ;;
    esac
    echo ""

    if (( rc == 0 )); then
        ok "$label complete: $SEL_NAME"
        log INFO "$label succeeded for '$SEL_NAME'"
    else
        err "$label failed for '$SEL_NAME' (exit $rc). See the output above."
        log ERROR "$label failed for '$SEL_NAME' (exit $rc)"
        if [ "$action" = up ]; then
            if [ -n "$outlog" ] && is_nvidia_spec_error "$outlog" \
                && nvidia_launch_recovery "$SEL_PATH"; then
                :  # relaunched successfully after regenerating the spec
            else
                offer_cleanup_created "$SEL_PATH"
            fi
        fi
    fi

    [ -n "$outlog" ] && rm -f -- "$outlog"
    pause
}

register_stack() {
    local name path line n p
    echo ""
    info "Register a compose stack"
    echo ""
    ask "  Stack name (e.g. LanguageTool): "; name="$ANS"
    ask "  Path to docker-compose.yml: ";     path="$ANS"
    path="${path/#\~/$HOME}"

    if [ -z "$name" ]; then
        err "Stack name cannot be empty."; pause; return
    fi
    if [[ "$name$path" == *"|"* ]]; then
        err "Names and paths cannot contain '|'."; pause; return
    fi
    if [ ! -f "$path" ]; then
        err "File not found: $path"; pause; return
    fi
    path=$(realpath -e -- "$path") || { err "Could not resolve the absolute path."; pause; return; }

    load_entries
    for line in "${ENTRIES[@]}"; do
        IFS='|' read -r n p <<< "$line"
        if [ "$n" = "$name" ]; then
            err "A stack named '$name' already exists."; pause; return
        fi
        if [ "$p" = "$path" ]; then
            err "That compose file is already registered as '$n'."; pause; return
        fi
    done

    # Make sure the last existing line ends in a newline before appending.
    if [ -s "$REGISTRY_FILE" ] && [ -n "$(tail -c1 "$REGISTRY_FILE")" ]; then
        printf '\n' >> "$REGISTRY_FILE"
    fi

    if printf '%s|%s\n' "$name" "$path" >> "$REGISTRY_FILE"; then
        ok "Registered '$name'."
        log INFO "Registered '$name' -> $path"
        sleep 1
    else
        err "Could not write to $REGISTRY_FILE."
        log ERROR "Failed to write registry entry for '$name'"
        pause
    fi
}

deregister_stack() {
    local tmp g
    pick_stack; local rc=$?
    (( rc == 2 )) && return
    if (( rc != 0 )); then pause; return; fi

    confirm "Remove '$SEL_NAME' from the registry? Its containers are not touched." \
        || { warn "Cancelled."; sleep 1; return; }

    if ! grep -qxF -- "$SEL_LINE" "$REGISTRY_FILE"; then
        err "That entry changed on disk. Nothing was removed."; pause; return
    fi

    tmp=$(mktemp "$CONFIG_DIR/.registry.XXXXXX") || { err "Could not create a temp file."; pause; return; }
    grep -vxF -- "$SEL_LINE" "$REGISTRY_FILE" > "$tmp"
    g=$?
    if (( g > 1 )); then
        rm -f "$tmp"
        err "Could not update the registry. Nothing was changed."
        log ERROR "grep failed while deregistering '$SEL_NAME'"
        pause; return
    fi

    cat "$tmp" > "$REGISTRY_FILE"
    rm -f "$tmp"
    ok "Removed '$SEL_NAME' from the registry."
    log INFO "Deregistered '$SEL_NAME' ($SEL_PATH)"
    sleep 1
}

# =============================================================================
# Container actions
# =============================================================================

list_containers_screen() {
    local i
    load_containers || { err "Cannot query Docker: $PS_ERR"; pause; return; }
    if (( ${#CONTAINERS[@]} == 0 )); then
        dim "No containers exist on this Docker daemon."; pause; return
    fi
    echo ""
    VIEW=("${!CONTAINERS[@]}")
    print_container_table
    pause
}

bulk_remove() {
    local idx id name _ removed=0 failed=0 out
    for idx in "$@"; do
        IFS='|' read -r id name _ <<< "${CONTAINERS[$idx]}"
        if out=$(docker rm "$id" 2>&1); then
            removed=$((removed + 1))
            log INFO "Removed container '$name' ($id)"
        else
            failed=$((failed + 1))
            err "Could not remove '$name': $(printf '%s' "$out" | head -n1)"
            log ERROR "Failed to remove '$name' ($id): $out"
        fi
    done
    ok "Removed $removed container(s)."
    (( failed > 0 )) && err "$failed removal(s) failed. See the log for details."
    return 0
}

remove_container() {
    local out force=()
    pick_container all; local rc=$?
    (( rc == 2 )) && return
    if (( rc != 0 )); then pause; return; fi

    case "$SEL_STATE" in
        running|restarting|paused)
            warn "'$SEL_CNAME' is $SEL_STATE. It can only be removed by force (this kills it)."
            confirm "Force remove '$SEL_CNAME'?" || { warn "Cancelled."; sleep 1; return; }
            force=(-f)
            ;;
        *)
            confirm "Remove '$SEL_CNAME' (state: $SEL_STATE)?" || { warn "Cancelled."; sleep 1; return; }
            ;;
    esac

    if [ -n "$SEL_PROJECT" ]; then
        warn "This container belongs to compose project '$SEL_PROJECT'. Prefer stopping its stack (option 2)."
    fi

    if out=$(docker rm "${force[@]}" "$SEL_CID" 2>&1); then
        ok "Removed '$SEL_CNAME'."
        log INFO "Removed container '$SEL_CNAME' ($SEL_CID)"
    else
        err "Could not remove '$SEL_CNAME': $(printf '%s' "$out" | head -n1)"
        log ERROR "Failed to remove '$SEL_CNAME' ($SEL_CID): $out"
    fi
    pause
}

cleanup_stopped() {
    local i state list=() _id _name _status _image _project _cfg
    load_containers || { err "Cannot query Docker: $PS_ERR"; pause; return; }

    for i in "${!CONTAINERS[@]}"; do
        IFS='|' read -r _id _name state _status _image _project _cfg <<< "${CONTAINERS[$i]}"
        case "$state" in
            created|exited|dead) list+=("$i") ;;
        esac
    done

    if (( ${#list[@]} == 0 )); then
        ok "Nothing to clean up. No created, exited, or dead containers."
        pause; return
    fi

    echo ""
    info "Containers that can be removed:"
    VIEW=("${list[@]}")
    print_container_table
    confirm "Remove these ${#list[@]} container(s)? Named volumes are kept." \
        || { warn "Cancelled."; sleep 1; return; }

    bulk_remove "${list[@]}"
    pause
}

# Offers to remove 'created' containers, optionally only those for one compose file.
offer_cleanup_created() {
    local filter="${1:-}" i state cfg list=() _id _name _status _image _project
    load_containers || return 0

    for i in "${!CONTAINERS[@]}"; do
        IFS='|' read -r _id _name state _status _image _project cfg <<< "${CONTAINERS[$i]}"
        [ "$state" = created ] || continue
        if [ -n "$filter" ] && [[ ",$cfg," != *",$filter,"* ]]; then
            continue
        fi
        list+=("$i")
    done

    (( ${#list[@]} == 0 )) && return 0

    echo ""
    warn "${#list[@]} container(s) are stuck in the 'created' state. They can block a clean launch."
    VIEW=("${list[@]}")
    print_container_table
    confirm "Remove them now?" || return 0
    bulk_remove "${list[@]}"
}

show_logs_for_container() {
    local tail_n out
    pick_container all; local rc=$?
    (( rc == 2 )) && return
    if (( rc != 0 )); then pause; return; fi

    ask "  Lines to show [200]: "
    tail_n="${ANS:-200}"
    if ! [[ "$tail_n" =~ ^[0-9]+$ ]]; then
        err "Enter a whole number."; pause; return
    fi

    if confirm "  Follow live output? (Ctrl+C returns to the menu)"; then
        echo ""
        info "Following '$SEL_CNAME'. Press Ctrl+C to stop."
        trap ':' INT
        docker logs -f --tail "$tail_n" "$SEL_CID"
        trap on_interrupt INT
        echo ""
        pause
        return
    fi

    out=$(docker logs --tail "$tail_n" "$SEL_CID" 2>&1)
    if [ -z "$out" ]; then
        warn "No log output for '$SEL_CNAME' (state: $SEL_STATE)."
        pause; return
    fi
    printf '%s\n' "$out" | show_text
}

# =============================================================================
# Tools
# =============================================================================

open_lazydocker() {
    if ! command -v lazydocker >/dev/null 2>&1; then
        err "lazydocker is not installed. Install it with: sudo pacman -S lazydocker"
        log WARN "lazydocker not found"
        pause; return
    fi
    lazydocker
}

view_manager_log() {
    if [ ! -s "$LOG_FILE" ]; then
        warn "The log is empty or missing: $LOG_FILE"
        pause; return
    fi
    show_text < "$LOG_FILE"
}

restart_rootless_docker() {
    local i
    info "Restarting Rootless Docker..."
    log INFO "Restarting rootless Docker"

    if ! systemctl --user restart docker; then
        err "systemctl restart failed. Check: systemctl --user status docker"
        log ERROR "Rootless Docker restart failed"
        return 1
    fi

    for i in $(seq 1 20); do
        if docker info >/dev/null 2>&1; then
            ok "Rootless Docker is back up."
            log INFO "Rootless Docker restarted successfully"
            return 0
        fi
        sleep 1
    done

    err "Docker did not respond within 20 seconds. Check: systemctl --user status docker"
    log ERROR "Rootless Docker did not respond within 20 seconds"
    return 1
}

# Generates, validates and installs the NVIDIA CDI spec, then restarts Docker.
# Returns 0 on success, 1 on any failure. Does not pause or print a header.
regenerate_cdi_core() {
    local tool driver running tmp gen_log missing
    for tool in nvidia-smi nvidia-ctk; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            err "'$tool' not found. Install the NVIDIA driver and nvidia-container-toolkit."
            log ERROR "$tool not found"
            return 1
        fi
    done

    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
        | head -n1 | tr -d '[:space:]')
    if [ -z "$driver" ]; then
        err "Could not read the driver version. Is the NVIDIA driver loaded?"
        log ERROR "Driver version unreadable"
        return 1
    fi
    ok "Installed driver: $driver"

    running=$(docker ps -q 2>/dev/null | grep -c .)
    if (( running > 0 )); then
        warn "$running container(s) are running. Restarting Docker will stop them."
        confirm "Continue?" || {
            warn "Cancelled. Nothing was changed."
            log INFO "CDI regeneration cancelled"
            return 1
        }
    fi

    info "Authenticating sudo once..."
    if ! sudo -v; then
        err "sudo authentication failed. Nothing was changed."
        log ERROR "sudo authentication failed"
        return 1
    fi

    # .json suffix so nvidia-ctk writes the same format as $CDI_SPEC.
    tmp=$(mktemp "${TMPDIR:-/tmp}/nvidia-cdi.XXXXXX.json") || { err "Could not create a temp file."; return 1; }
    gen_log="${TMPDIR:-/tmp}/nvidia-cdi-gen.log"

    info "Generating spec into a temporary file..."
    if ! sudo nvidia-ctk cdi generate --output="$tmp" >"$gen_log" 2>&1; then
        err "nvidia-ctk failed. The live spec was not changed. Details: $gen_log"
        log ERROR "nvidia-ctk cdi generate failed (see $gen_log)"
        sudo rm -f -- "$tmp"
        return 1
    fi

    # nvidia-ctk writes as root; take ownership so the checks below can read it.
    sudo chown "$(id -u):$(id -g)" "$tmp" 2>/dev/null

    if [ ! -s "$tmp" ] || ! grep -qF -- "$driver" "$tmp"; then
        err "Generated spec does not reference driver $driver. Nothing was installed."
        err "Generator output: $gen_log"
        log ERROR "Generated spec does not reference driver $driver (kept $tmp, log $gen_log)"
        return 1
    fi
    ok "Generated spec references driver $driver."

    # The spec is only useful if every file it mounts exists on this machine.
    missing=$(spec_missing_paths "$tmp")
    if [ -n "$missing" ]; then
        err "Generated spec points at files that are not on this system. The NVIDIA driver libraries may be incomplete. Nothing was installed."
        printf '%s\n' "$missing" | head -n 5 | sed 's/^/      /'
        err "Generated spec kept for inspection: $tmp"
        log ERROR "Generated spec references missing files (kept $tmp): $(printf '%s' "$missing" | tr '\n' ' ')"
        return 1
    fi
    ok "Every file the spec mounts exists."

    if ! { sudo install -d -m 0755 "$CDI_DIR" && sudo install -m 0644 "$tmp" "$CDI_SPEC"; }; then
        err "Could not install the spec into $CDI_DIR. Docker was NOT restarted."
        log ERROR "Failed to install CDI spec to $CDI_SPEC"
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
    ok "Spec written to $CDI_SPEC"
    log INFO "CDI spec written for driver $driver"

    # Remove stale specs before restarting, so Docker loads only the new one.
    remove_stale_cdi "$driver"

    restart_rootless_docker || return 1
    verify_cdi_devices
    return 0
}

# Menu entry for option 10.
regenerate_cdi() {
    echo ""
    info "Regenerate NVIDIA CDI spec"
    echo ""
    if regenerate_cdi_core; then
        offer_cleanup_created
    fi
    pause
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [ ! -t 0 ]; then
        echo "This manager needs an interactive terminal." >&2
        exit 1
    fi

    trap on_interrupt INT
    trap 'printf "%s" "$RST"' EXIT

    init

    while true; do
        draw_screen
        ask "  › Select an option: "
        case "${ANS,,}" in
            1)  run_stack_cmd up      Launch ;;
            2)  run_stack_cmd down    Stop ;;
            3)  run_stack_cmd restart Restart ;;
            4)  register_stack ;;
            5)  deregister_stack ;;
            6)  list_containers_screen ;;
            7)  remove_container ;;
            8)  cleanup_stopped ;;
            9)  show_logs_for_container ;;
            10) regenerate_cdi ;;
            11) open_lazydocker ;;
            12) view_manager_log ;;
            q|quit|exit) break ;;
            "") ;;
            *)  err "Unknown option: $ANS"; sleep 1 ;;
        esac
    done

    printf '\n  %sGoodbye.%s\n\n' "$DIM" "$RST"
}

# Run main only when executed directly, so the functions can be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
