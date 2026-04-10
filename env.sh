#!/usr/bin/env bash
# env.sh — composable env helpers for just-foundry
# Usage: source lib/just-foundry/env.sh
#
# How network resolution works:
#   1. The symlink lib/just-foundry/.env → networks/<name>.env is the single
#      source of truth for which network is active.  NETWORK_NAME is derived
#      from the symlink target filename: it is NOT read from any .env file.
#   2. If a local override .env.<network> exists at the project root, its
#      values are used instead of the upstream template.  The symlink still
#      determines the network name.
#   3. Secrets from .env and/or `vars` are layered on top.
#
# Public API:
#   env_network_name       print the active network name (no sourcing)
#   env_load               source network config + secrets into the current shell
#   env_show               print the resolved environment with source attribution

_NETWORK_SYMLINK="lib/just-foundry/.env"
_ENV_SKIP="^(NETWORK_NAME|CHAIN_ID|VERIFIER)$"
_ENV_MASK="(KEY|PRIVATE|SECRET|JWT|PASSWORD)"

# --- Network resolution ---

# Derive the network name from the symlink target filename.
# e.g. lib/just-foundry/.env → networks/sepolia.env → "sepolia"
_env_network_name() {
    [ -L "$_NETWORK_SYMLINK" ] || { echo "No network selected (symlink missing). Run: just switch <network>" >&2; return 1; }
    local target
    target=$(readlink "$_NETWORK_SYMLINK")
    # Strip path prefix and .env suffix: "networks/sepolia.env" → "sepolia"
    target="${target##*/}"
    target="${target%.env}"
    echo "$target"
}

# Return the file to source: local override (.env.<network>) if it exists,
# otherwise the symlink target.
_env_network_file() {
    local network
    network=$(_env_network_name) || return 1
    local override=".env.$network"
    if [ -f "$override" ]; then
        echo "$override"
    else
        echo "$_NETWORK_SYMLINK"
    fi
}

# --- Public API ---

# Print the active network name (lightweight — no file sourcing).
env_network_name() {
    _env_network_name || return 1
}

# Source network config + resolved secrets into the current shell.
# Exports NETWORK_NAME (derived from symlink, not from the env file).
# Pass --verbose to print a status line to stderr.
env_load() {
    local verbose=false
    [ "${1:-}" = "--verbose" ] && verbose=true

    local network network_file
    network=$(_env_network_name) || return 1
    network_file=$(_env_network_file) || return 1
    set -a && source "$network_file" && set +a
    export NETWORK_NAME="$network"
    _env_apply_secrets

    if $verbose; then
        local status="$network"
        [ -f ".env.$network" ] && status="$status (override: .env.$network)"
        if command -v vars &>/dev/null && [ -f .vars.yaml ] && grep -qE "^\s+${network}:" .vars.yaml 2>/dev/null; then
            status="$status (vars: $network)"
        fi
        >&2 echo "[env] $status"
    fi
}

# Print the effective environment (header + all vars with source attribution)
env_show() {
    local network network_file
    network=$(_env_network_name) || return 1
    network_file=$(_env_network_file) || return 1
    set -a && source "$network_file" && set +a
    export NETWORK_NAME="$network"

    echo "Network:  $NETWORK_NAME ($CHAIN_ID)"
    echo "Verifier: ${VERIFIER:-<not set>}"
    [ -f ".env.$network" ] && echo "Override: .env.$network"
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
}

# --- Core emitter (single source of resolved values) ---

# Emit resolved export statements to stdout.
# Pipes network file + root .env into vars resolve (store takes priority over files).
# Only passes -p <profile> if that profile is defined in .vars.yaml.
# Any extra args are forwarded to vars resolve (e.g. --origin).
_env_exports() {
    local network_file
    network_file=$(_env_network_file) || return 1
    local profile
    profile=$(_env_network_name) || return 1
    local profile_flag=""
    if [ -f .vars.yaml ] && grep -qE "^\s+${profile}:" .vars.yaml 2>/dev/null; then
        profile_flag="-p $profile"
    fi
    (cat "$network_file"; [ -f .env ] && cat .env || true) | \
        vars resolve --partial ${profile_flag} "$@"
}

# --- Private helpers ---

# Eval _env_exports into the current shell.
_env_apply_secrets() {
    local profile
    profile=$(_env_network_name) || return 1
    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
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
        echo "${value:0:4}******"
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
