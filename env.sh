#!/usr/bin/env bash
# env.sh — composable env helpers for just-foundry
# Usage: source lib/just-foundry/env.sh

_NETWORK_ENV="lib/just-foundry/.env"
_SKIP_KEYS="^(NETWORK_NAME|CHAIN_ID|VERIFIER)$"
_MASK_PATTERN="(KEY|PRIVATE|SECRET|JWT|PASSWORD)"

_require_network() {
    [ -f "$_NETWORK_ENV" ] || { echo "No network selected. Run: just switch <network>"; return 1; }
}

# --- Loading ---

# Source the network .env symlink into the current shell (public config only)
load_network_env() {
    _require_network || return 1
    set -a && source "$_NETWORK_ENV" && set +a
}

# Source the fully resolved env (network config + secrets) into the current shell
load_env() {
    local profile="${1:-}"
    load_network_env || return 1
    local resolved_profile="${profile:-${NETWORK_NAME:-}}"
    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
        if [[ -n "$resolved_profile" ]] && grep -qE "^\s+${resolved_profile}:" .vars.yaml 2>/dev/null; then
            >&2 echo "vars profile: $resolved_profile"
        fi
        eval "$(_emit_env "$resolved_profile")"
    elif [ -f .env ]; then
        set -a && source .env && set +a
    fi
}

# --- Core resolver ---

# Emit resolved export statements to stdout.
# Pipes the network file + root .env into vars resolve (store takes priority).
# Only passes -p <profile> if that profile is actually defined in .vars.yaml.
# Any extra args are forwarded to vars resolve (e.g. --origins).
_emit_env() {
    local profile="${1:-}"; shift 2>/dev/null || true
    local profile_flag=""
    if [[ -n "$profile" ]] && [ -f .vars.yaml ] && grep -qE "^\s+${profile}:" .vars.yaml 2>/dev/null; then
        profile_flag="-p $profile"
    fi
    (cat "$_NETWORK_ENV"; [ -f .env ] && cat .env || true) | \
        vars resolve --partial ${profile_flag} "$@"
}

# --- Display helpers ---

_mask_value() {
    local key="$1" value="$2"
    if [[ "$key" =~ $_MASK_PATTERN ]] && [[ -n "$value" ]]; then
        echo "${value:0:6}****"
    else
        echo "$value"
    fi
}

_print_var() {
    local key="$1" value="$2" source="${3:-}"
    value=$(_mask_value "$key" "$value")
    if [[ -n "$source" ]]; then
        printf "  %-10s %-38s %s\n" "[$source]" "$key" "$value"
    else
        printf "  %-10s %s\n" "" "$key"
    fi
}

# Parse `vars resolve --origins` output and print formatted lines
_display_resolved() {
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
            [[ "$key" =~ $_SKIP_KEYS ]] && continue
            [[ -n "$allowed" ]] && [[ ! "$key" =~ ^($allowed)$ ]] && continue
            after_eq="${line#*=\'}"
            value="${after_eq%\'*}"
            _print_var "$key" "$value" "$source"
        elif [[ "$line" =~ ^#\ ([A-Z_][A-Z0-9_]*)\ +not\ set ]]; then
            key="${BASH_REMATCH[1]}"
            [[ "$key" =~ $_SKIP_KEYS ]] && continue
            [[ -n "$allowed" ]] && [[ ! "$key" =~ ^($allowed)$ ]] && continue
            printf "  %-10s %s\n" "[not set]" "$key"
        fi
    done
}

# Fallback display when vars is not installed: reads a raw .env file
_display_raw() {
    local file="$1"
    [ -f "$file" ] || return
    while IFS='=' read -r key rest; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ "$key" =~ $_SKIP_KEYS ]] && continue
        value="${rest#\"}" ; value="${value%\"}"
        value="${value#\'}" ; value="${value%\'}"
        _print_var "$key" "$value"
    done < "$file"
}

# --- Show ---

# Print the effective environment (header + all vars with source attribution)
show_env() {
    _require_network || return 1
    set -a && source "$_NETWORK_ENV" && set +a

    echo "Network:  $NETWORK_NAME ($CHAIN_ID)"
    echo "Verifier: $VERIFIER"
    echo ""

    if command -v vars &>/dev/null && [ -f .vars.yaml ]; then
        local ALLOWED MANIFEST
        ALLOWED=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$_NETWORK_ENV" | cut -d= -f1 | tr '\n' '|' | sed 's/|$//')
        MANIFEST=$(grep -E '^ *- [A-Z_]' .vars.yaml | sed 's/^ *- //' | sed 's/ .*//' | tr '\n' '|' | sed 's/|$//')
        [ -n "$MANIFEST" ] && ALLOWED="$ALLOWED|$MANIFEST"
        _emit_env "${NETWORK_NAME:-}" --origins | _display_resolved "$ALLOWED"
    else
        _display_raw "$_NETWORK_ENV"
        _display_raw .env
    fi
}
