#!/usr/bin/env bash
# env.sh — composable env helpers for just-foundry
# Usage: source lib/just-foundry/env.sh
#
# Public API:
#   env_load_network       source static network .env into the current shell
#   env_load               source network config + resolved secrets into the current shell
#   env_show               print the resolved environment with source attribution

_NETWORK_ENV="lib/just-foundry/.env"
_ENV_SKIP="^(NETWORK_NAME|CHAIN_ID|VERIFIER)$"
_ENV_MASK="(KEY|PRIVATE|SECRET|JWT|PASSWORD)"

# --- Public API ---

# Source the network .env symlink into the current shell (public config only)
env_load_network() {
    _env_require_network || return 1
    set -a && source "$_NETWORK_ENV" && set +a
}

# Source the fully resolved env (network config + secrets) into the current shell
env_load() {
    env_load_network || return 1
    _env_apply_secrets "$NETWORK_NAME"
}

# Print the effective environment (header + all vars with source attribution)
env_show() {
    _env_require_network || return 1
    set -a && source "$_NETWORK_ENV" && set +a

    echo "Network:  $NETWORK_NAME ($CHAIN_ID)"
    echo "Verifier: $VERIFIER"
    echo ""

    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
        local ALLOWED MANIFEST
        ALLOWED=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$_NETWORK_ENV" | cut -d= -f1 | tr '\n' '|' | sed 's/|$//')
        MANIFEST=$(grep -E '^ *- [A-Z_]' .vars.yaml | sed 's/^ *- //' | sed 's/ .*//' | tr '\n' '|' | sed 's/|$//')
        [ -n "$MANIFEST" ] && ALLOWED="$ALLOWED|$MANIFEST"
        _env_exports "${NETWORK_NAME:-}" --origin | _env_display_origin "$ALLOWED"
    else
        _env_display_raw "$_NETWORK_ENV"
        _env_display_raw .env
    fi
}

# --- Core emitter (single source of resolved values) ---

# Emit resolved export statements to stdout.
# Pipes network file + root .env into vars resolve (store takes priority over files).
# Only passes -p <profile> if that profile is defined in .vars.yaml.
# Any extra args are forwarded to vars resolve (e.g. --origin).
_env_exports() {
    local profile="${1:-}"; shift 2>/dev/null || true
    local profile_flag=""
    if [[ -n "$profile" ]] && [ -f .vars.yaml ] && grep -qE "^\s+${profile}:" .vars.yaml 2>/dev/null; then
        profile_flag="-p $profile"
    fi
    # Inject the local .env files to vars (if present) and resolve the secrets
    (cat "$_NETWORK_ENV"; [ -f .env ] && cat .env || true) | \
        vars resolve --partial ${profile_flag} "$@"
}

# --- Guards ---

_env_require_network() {
    [ -f "$_NETWORK_ENV" ] || { echo "No network selected. Run: just switch <network>"; return 1; }
}

# --- Private helpers ---

# Eval _env_exports into the current shell; print active profile to stderr.
# Requires env_load_network to have run first (NETWORK_NAME must be set).
_env_apply_secrets() {
    local profile="${1:-}"
    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
        if [[ -n "$profile" ]] && grep -qE "^\s+${profile}:" .vars.yaml 2>/dev/null; then
            >&2 echo "vars profile: $profile"
        fi
        local exports
        exports=$(_env_exports "$profile") || return 1
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
        _env_print "$key" "$value" "dotenv"
    done < "$file"
}
