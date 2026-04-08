#!/usr/bin/env bash
# env.sh — composable env helpers for just-foundry
# Usage: source lib/just-foundry/env.sh
#
# Public API:
#   env_load_network       source static network .env into the current shell
#   env_load               source network config + resolved secrets into the current shell
#   env_show               print the resolved environment with source attribution

_JUST_DIR=".just"
_ACTIVE_NETWORK_FILE="$_JUST_DIR/.active-network"
_ENV_SKIP="^(NETWORK_NAME|CHAIN_ID|VERIFIER)$"
_ENV_MASK="(KEY|PRIVATE|SECRET|JWT|PASSWORD)"

# --- Network file resolution ---

_env_active_network() {
    [ -f "$_ACTIVE_NETWORK_FILE" ] || { echo "No network selected. Run: just switch <network>"; return 1; }
    cat "$_ACTIVE_NETWORK_FILE"
}

_env_network_file() {
    local network
    network=$(_env_active_network) || return 1
    echo ".env.$network"
}

# --- Public API ---

# Source the network .env file into the current shell (public config only)
env_load_network() {
    local network_file
    network_file=$(_env_network_file) || return 1
    [ -f "$network_file" ] || { echo "Network file '$network_file' not found. Run: just add-network <network>"; return 1; }
    set -a && source "$network_file" && set +a
}

# Source the fully resolved env (network config + secrets) into the current shell
env_load() {
    env_load_network || return 1
    _env_apply_secrets
}

# Print the effective environment (header + all vars with source attribution)
env_show() {
    local network_file
    network_file=$(_env_network_file) || return 1
    [ -f "$network_file" ] || { echo "Network file '$network_file' not found. Run: just add-network <network>"; return 1; }
    set -a && source "$network_file" && set +a

    echo "Network:  $NETWORK_NAME ($CHAIN_ID)"
    echo "Verifier: $VERIFIER"
    echo ""

    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
        local ALLOWED MANIFEST
        ALLOWED=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$network_file" | cut -d= -f1 | tr '\n' '|' | sed 's/|$//')
        MANIFEST=$(grep -E '^ *- [A-Z_]' .vars.yaml | sed 's/^ *- //' | sed 's/ .*//' | tr '\n' '|' | sed 's/|$//')
        [ -n "$MANIFEST" ] && ALLOWED="$ALLOWED|$MANIFEST"
        _env_exports --origin | _env_display_origin "$ALLOWED"
    else
        _env_display_raw "$network_file"
        _env_display_raw .env
    fi
    return 0
}

# --- Core emitter (single source of resolved values) ---

# Emit resolved export statements to stdout.
# Pipes network file + root .env into vars resolve (store takes priority over files).
# Only passes -p <profile> if that profile is defined in .vars.yaml.
# Any extra args are forwarded to vars resolve (e.g. --origin).
_env_exports() {
    local network_file
    network_file=$(_env_network_file) || return 1
    local profile="${NETWORK_NAME:-}"
    local profile_flag=""
    if [[ -n "$profile" ]] && [ -f .vars.yaml ] && grep -qE "^\s+${profile}:" .vars.yaml 2>/dev/null; then
        profile_flag="-p $profile"
    fi
    # Inject the local .env files to vars (if present) and resolve the secrets
    (cat "$network_file"; [ -f .env ] && cat .env || true) | \
        vars resolve --partial ${profile_flag} "$@"
}

# --- Private helpers ---

# Eval _env_exports into the current shell; print active profile to stderr.
# Requires env_load_network to have run first (NETWORK_NAME must be set).
_env_apply_secrets() {
    local profile="${NETWORK_NAME:-}"
    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
        if [[ -n "$profile" ]] && grep -qE "^\s+${profile}:" .vars.yaml 2>/dev/null; then
            >&2 echo "vars profile: $profile"
        fi
        local exports
        exports=$(_env_exports) || return 1
        eval "$exports"
    elif [ -f .env ]; then
        set -a && source .env && set +a
    fi
}

_env_mask() {
    local key="$1" value="$2"
    if [[ "$key" =~ $_ENV_MASK ]] && [[ -n "$value" ]]; then
        echo "${value:0:6}****"
    else
        echo "$value"
    fi
}

_env_print() {
    local key="$1" value="$2" source="${3:-}"
    value=$(_env_mask "$key" "$value")
    if [[ -n "$source" ]]; then
        printf "  %-10s %-38s %s\n" "[$source]" "$key" "$value"
    else
        printf "  %-10s %s\n" "" "$key"
    fi
}

# Parse `vars resolve --origin` output and print formatted lines
_env_display_origin() {
    local allowed="$1"
    while IFS= read -r line; do
        if [[ "$line" == export\ * ]]; then
            line="${line#export }"
            if [[ "$line" == *"  # "* ]]; then
                source="${line##*  # }"
                [[ "$source" == "stdin" ]] && source="dotenv"
            else
                source="dotenv"
            fi
            key="${line%%=*}"
            [[ "$key" =~ $_ENV_SKIP ]] && continue
            [[ -n "$allowed" ]] && [[ ! "$key" =~ ^($allowed)$ ]] && continue
            after_eq="${line#*=\'}"
            value="${after_eq%\'*}"
            _env_print "$key" "$value" "$source"
        elif [[ "$line" =~ ^#\ ([A-Z_][A-Z0-9_]*)\ +not\ set ]]; then
            key="${BASH_REMATCH[1]}"
            [[ "$key" =~ $_ENV_SKIP ]] && continue
            [[ -n "$allowed" ]] && [[ ! "$key" =~ ^($allowed)$ ]] && continue
            printf "  %-10s %s\n" "[not set]" "$key"
        fi
    done
}

# Fallback display when vars is not installed: reads a raw .env file
_env_display_raw() {
    local file="$1"
    [ -f "$file" ] || return
    while IFS='=' read -r key rest; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ "$key" =~ $_ENV_SKIP ]] && continue
        value="${rest#\"}" ; value="${value%\"}"
        value="${value#\'}" ; value="${value%\'}"
        _env_print "$key" "$value"
    done < "$file"
}
