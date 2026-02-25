#!/usr/bin/env bash

# Check health of the three main Docker containers that ArgoCD orchestrates for HaloArchives.com  

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

die()   { echo -e "${RED}Error:${RESET} $*" >&2; exit 1; }
info()  { echo -e "${CYAN}ℹ${RESET}  $*"; }
ok()    { echo -e "${GREEN}✔${RESET}  $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET}  $*"; }
fail()  { echo -e "${RED}✖${RESET}  $*"; }

command -v docker &>/dev/null || die "docker is not installed or not in PATH."
docker info &>/dev/null 2>&1  || die "Cannot connect to Docker daemon. Is it running?"

hr() { printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '─'; }

check_container() {
    local cid="$1"

    local inspect
    inspect=$(docker inspect "$cid" 2>/dev/null) || { fail "Container ${BOLD}$cid${RESET} not found."; return 1; }

    local name state status health pid cpu_pct mem_usage mem_pct restarts image created
    name=$(echo "$inspect"     | jq -r '.[0].Name'                         | sed 's|^/||')
    image=$(echo "$inspect"    | jq -r '.[0].Config.Image')
    state=$(echo "$inspect"    | jq -r '.[0].State.Status')
    pid=$(echo "$inspect"      | jq -r '.[0].State.Pid')
    restarts=$(echo "$inspect" | jq -r '.[0].RestartCount')
    created=$(echo "$inspect"  | jq -r '.[0].Created' | cut -dT -f1)
    health=$(echo "$inspect"   | jq -r '.[0].State.Health.Status // "none"')

    local state_color="$RED"
    [[ "$state" == "running" ]] && state_color="$GREEN"
    [[ "$state" == "paused" ]]  && state_color="$YELLOW"

    local health_color="$DIM"
    case "$health" in
        healthy)   health_color="$GREEN" ;;
        unhealthy) health_color="$RED" ;;
        starting)  health_color="$YELLOW" ;;
    esac

    local cpu_str="n/a" mem_str="n/a" net_str="n/a"
    if [[ "$state" == "running" ]]; then
        local stats
        stats=$(docker stats "$cid" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}' 2>/dev/null || true)
        if [[ -n "$stats" ]]; then
            cpu_str=$(echo "$stats" | cut -d'|' -f1)
            mem_str="$(echo "$stats" | cut -d'|' -f2) ($(echo "$stats" | cut -d'|' -f3))"
            net_str=$(echo "$stats" | cut -d'|' -f4)
        fi
    fi

    local ports
    ports=$(echo "$inspect" | jq -r '
        [.[0].NetworkSettings.Ports // {} | to_entries[] |
         select(.value != null) |
         "\(.value[0].HostPort) → \(.key)"] | join(", ")' 2>/dev/null)
    [[ -z "$ports" ]] && ports="none"

    echo ""
    echo -e "${BOLD}  Container: ${CYAN}${name}${RESET}"
    hr
    printf "  %-14s %b\n" "Image:"    "$image"
    printf "  %-14s %b\n" "Created:"  "$created"
    printf "  %-14s %b\n" "State:"    "${state_color}${state}${RESET}"
    printf "  %-14s %b\n" "Health:"   "${health_color}${health}${RESET}"
    printf "  %-14s %s\n" "PID:"      "$pid"
    printf "  %-14s %s\n" "Restarts:" "$restarts"
    printf "  %-14s %s\n" "CPU:"      "$cpu_str"
    printf "  %-14s %s\n" "Memory:"   "$mem_str"
    printf "  %-14s %s\n" "Net I/O:"  "$net_str"
    printf "  %-14s %s\n" "Ports:"    "$ports"

    if [[ "$health" == "unhealthy" ]]; then
        local last_log
        last_log=$(echo "$inspect" | jq -r '.[0].State.Health.Log[-1].Output // "no output"' | head -5)
        echo ""
        warn "Last healthcheck output:"
        echo -e "  ${DIM}${last_log}${RESET}"
    fi

    case "$state" in
        running)
            [[ "$health" == "unhealthy" ]] && return 2
            return 0 ;;
        *)
            return 1 ;;
    esac
}

main() {
    local targets=()
    local total=0 healthy=0 warnings=0 problems=0

    if [[ $# -gt 0 ]]; then
        targets=("$@")
    else
        mapfile -t targets < <(docker ps -q)
        [[ ${#targets[@]} -eq 0 ]] && { info "No running containers found."; exit 0; }
    fi

    echo ""
    echo -e "${BOLD}🐳 Docker Container Health Report${RESET}"
    echo -e "${DIM}   $(date '+%Y-%m-%d %H:%M:%S')${RESET}"

    for cid in "${targets[@]}"; do
        total=$((total + 1))
        local rc=0
        check_container "$cid" || rc=$?
        case $rc in
            0) healthy=$((healthy + 1)) ;;
            2) warnings=$((warnings + 1)) ;;
            *) problems=$((problems + 1)) ;;
        esac
    done
    
    echo ""
    hr
    echo -e "${BOLD}  Summary:${RESET} ${total} container(s) checked"
    [[ $healthy  -gt 0 ]] && ok  "${healthy} healthy"
    [[ $warnings -gt 0 ]] && warn "${warnings} unhealthy (running but failing health checks)"
    [[ $problems -gt 0 ]] && fail "${problems} not running"
    echo ""

    [[ $problems -gt 0 || $warnings -gt 0 ]] && exit 1
    exit 0
}

main "$@"
