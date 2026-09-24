#!/usr/bin/env bash
# Sync address values in networks/*.env from artifacts-hub JSONs.
#
# Usage: sync-addresses.sh [--dry-run] [--force] [hub-path]
#   hub-path defaults to ../artifacts-hub (sibling of the just-foundry checkout).
#
# Reads canonical addresses from <hub>/addresses/<network>.json and writes them
# (EIP-55 checksummed) into networks/<network>.env. New *_PLUGIN_REPO_ADDRESS
# keys discovered in JSON are inserted grouped with existing plugin-repo lines.
#
# Existing values are NEVER overwritten with a different address unless --force
# is passed — a conflict is reported and that network is left untouched. Safe
# additions still apply on other networks.
#
# Requires: bash 3.2+, jq, cast (foundry).

set -uo pipefail

HUB=""
DRY_RUN=""
FORCE=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1   ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            echo "Error: unknown flag '$arg'" >&2
            exit 1
            ;;
        *)
            [ -n "$HUB" ] && { echo "Error: too many positional args" >&2; exit 1; }
            HUB="$arg"
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HUB="${HUB:-$(cd "$REPO_ROOT/.." 2>/dev/null && pwd)/artifacts-hub}"

if [ ! -d "$HUB/addresses" ]; then
    echo "Error: artifacts-hub not found at '$HUB' (expected <hub>/addresses/)" >&2
    echo "       Pass a path: just sync-addresses /path/to/artifacts-hub" >&2
    exit 1
fi
command -v jq   >/dev/null || { echo "Error: jq is required"   >&2; exit 1; }
command -v cast >/dev/null || { echo "Error: cast (foundry) is required" >&2; exit 1; }

# --- Ordered list of core env keys we sync from osx/management sections. ---
CORE_KEY_ORDER=(
    DAO_FACTORY_ADDRESS
    PLUGIN_REPO_FACTORY_ADDRESS
    PLUGIN_SETUP_PROCESSOR_ADDRESS
    MANAGEMENT_DAO_ADDRESS
    MANAGEMENT_DAO_MULTISIG_ADDRESS
)

# jq expression to extract each core key's value from a network JSON.
# (Bash 3.2 has no associative arrays, so this is a case function.)
core_jq() {
    case "$1" in
        DAO_FACTORY_ADDRESS)             printf '%s' '.osx.versions | map(select(.current))[0].core.daoFactory // empty' ;;
        PLUGIN_REPO_FACTORY_ADDRESS)     printf '%s' '.osx.versions | map(select(.current))[0].core.pluginRepoFactory // empty' ;;
        PLUGIN_SETUP_PROCESSOR_ADDRESS)  printf '%s' '.osx.versions | map(select(.current))[0].core.pluginSetupProcessor // empty' ;;
        MANAGEMENT_DAO_ADDRESS)          printf '%s' '.management.dao // empty' ;;
        MANAGEMENT_DAO_MULTISIG_ADDRESS) printf '%s' '.management.daoMultisig // empty' ;;
        *) return 1 ;;
    esac
}

slug_to_env_prefix() {
    # token-voting -> TOKEN_VOTING
    printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

# --- Target-map helpers. Backed by parallel indexed arrays TK/TV. ---
TK=()
TV=()
# tk_index KEY: prints the 0-based index of KEY in TK, or empty if absent.
tk_index() {
    local needle="$1" i=0 k
    if [ "${#TK[@]}" -eq 0 ]; then return 1; fi
    for k in "${TK[@]}"; do
        [ "$k" = "$needle" ] && { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}
tv_get() {
    local idx
    idx=$(tk_index "$1") || return 1
    printf '%s' "${TV[$idx]}"
}
tv_set() {
    local idx
    if idx=$(tk_index "$1"); then
        TV[$idx]="$2"
    else
        TK+=("$1")
        TV+=("$2")
    fi
}

sync_one() {
    local env_file="$1"
    local name json
    name=$(basename "$env_file" .env)
    json="$HUB/addresses/$name.json"

    if [ ! -f "$json" ]; then
        echo "== $name =="
        echo "  [skip] no $json"
        return 0
    fi

    echo "== $name =="

    # Skip chains marked deprecated in artifacts-hub.
    if [ "$(jq -r '.deprecated // false' "$json")" = "true" ]; then
        echo "  [skip] chain marked deprecated in artifacts-hub"
        return 0
    fi

    # Sanity: CHAIN_ID in env must match chainId in JSON.
    local env_chain json_chain
    env_chain=$(bash -c "set -a; source '$env_file' >/dev/null 2>&1; printf '%s' \"\${CHAIN_ID:-}\"")
    json_chain=$(jq -r '.chainId' "$json")
    if [ -z "$env_chain" ]; then
        echo "  ERROR: CHAIN_ID not set in $env_file" >&2
        return 1
    fi
    if [ "$env_chain" != "$json_chain" ]; then
        echo "  ERROR: CHAIN_ID mismatch (env=$env_chain, json=$json_chain)" >&2
        return 1
    fi

    # Build the target map: env-key -> checksummed address.
    TK=()
    TV=()
    local key val checksum jq_expr

    for key in "${CORE_KEY_ORDER[@]}"; do
        jq_expr=$(core_jq "$key")
        val=$(jq -r "$jq_expr" "$json")
        if [ -n "$val" ]; then
            if ! checksum=$(cast to-checksum "$val" 2>&1); then
                echo "  ERROR: cast to-checksum failed for $key=$val: $checksum" >&2
                return 1
            fi
            tv_set "$key" "$checksum"
        fi
    done

    local slug env_key
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        env_key="$(slug_to_env_prefix "$slug")_PLUGIN_REPO_ADDRESS"
        val=$(jq -r --arg s "$slug" '.plugins[$s].repo // empty' "$json")
        if [ -n "$val" ]; then
            if ! checksum=$(cast to-checksum "$val" 2>&1); then
                echo "  ERROR: cast to-checksum failed for $env_key=$val: $checksum" >&2
                return 1
            fi
            tv_set "$env_key" "$checksum"
        fi
    done < <(jq -r '.plugins | keys[]' "$json")

    # First pass: detect conflicts (existing key whose value differs from JSON).
    # Compare case-insensitively so pure re-checksumming isn't flagged.
    local conflicts=()
    local existing_val target_val target_lower existing_lower line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\"?([^\"[:space:]]*)\"? ]]; then
            key="${BASH_REMATCH[1]}"
            existing_val="${BASH_REMATCH[2]}"
            if target_val=$(tv_get "$key") && [ -n "$existing_val" ]; then
                target_lower=$(printf '%s' "$target_val" | tr '[:upper:]' '[:lower:]')
                existing_lower=$(printf '%s' "$existing_val" | tr '[:upper:]' '[:lower:]')
                if [ "$target_lower" != "$existing_lower" ]; then
                    conflicts+=("$key|$existing_val|$target_val")
                fi
            fi
        fi
    done < "$env_file"

    if [ "${#conflicts[@]}" -gt 0 ] && [ -z "$FORCE" ]; then
        echo "  CONFLICT: JSON would overwrite ${#conflicts[@]} existing value(s) — skipping (pass --force to apply):"
        local c k rest old new
        for c in "${conflicts[@]}"; do
            k="${c%%|*}"; rest="${c#*|}"
            old="${rest%%|*}"; new="${rest#*|}"
            echo "    $k"
            echo "      current = $old"
            echo "      new     = $new"
        done
        return 2
    fi

    # Walk env file, update existing keys in place, track last plugin-repo line.
    local tmp new_line
    tmp=$(mktemp)
    local seen=" "
    local last_plugin_line=0
    local out_line=0

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            if target_val=$(tv_get "$key"); then
                new_line="${key}=\"${target_val}\""
                if [ "$line" != "$new_line" ]; then
                    echo "  update $key"
                fi
                line="$new_line"
                seen="${seen}${key} "
            fi
            if [[ "$key" == *_PLUGIN_REPO_ADDRESS ]]; then
                last_plugin_line=$((out_line + 1))
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
        out_line=$((out_line + 1))
    done < "$env_file"

    # Warn on core/plugin-repo env keys with no value in JSON.
    for key in "${CORE_KEY_ORDER[@]}"; do
        if grep -qE "^${key}=" "$env_file" && ! tv_get "$key" >/dev/null; then
            echo "  WARN: $key present in env but missing in JSON — kept as-is"
        fi
    done
    while IFS= read -r existing_env_key; do
        [[ "$existing_env_key" == *_PLUGIN_REPO_ADDRESS ]] || continue
        if ! tv_get "$existing_env_key" >/dev/null; then
            echo "  WARN: $existing_env_key present in env but missing in JSON — kept as-is"
        fi
    done < <(grep -oE '^[A-Z_][A-Z0-9_]*_PLUGIN_REPO_ADDRESS' "$env_file" || true)

    # Insert new plugin-repo keys grouped with existing ones (after last such line).
    local to_insert=()
    local i=0
    while [ "$i" -lt "${#TK[@]}" ]; do
        key="${TK[$i]}"
        if [[ "$seen" != *" $key "* ]] && [[ "$key" == *_PLUGIN_REPO_ADDRESS ]]; then
            to_insert+=("$key")
            echo "  add    $key = ${TV[$i]}"
        fi
        i=$((i + 1))
    done

    if [ "${#to_insert[@]}" -gt 0 ]; then
        local insert_at=$last_plugin_line
        [ "$insert_at" -eq 0 ] && insert_at=$out_line
        local tmp2
        tmp2=$(mktemp)
        head -n "$insert_at" "$tmp" > "$tmp2"
        for key in "${to_insert[@]}"; do
            printf '%s="%s"\n' "$key" "$(tv_get "$key")" >> "$tmp2"
        done
        if [ "$insert_at" -lt "$out_line" ]; then
            tail -n +$((insert_at + 1)) "$tmp" >> "$tmp2"
        fi
        mv "$tmp2" "$tmp"
    fi

    if diff -q "$env_file" "$tmp" >/dev/null 2>&1; then
        echo "  (no changes)"
        rm -f "$tmp"
        return 0
    fi

    if [ -n "$DRY_RUN" ]; then
        diff -u "$env_file" "$tmp" || true
        rm -f "$tmp"
    else
        mv "$tmp" "$env_file"
        echo "  wrote $env_file"
    fi
}

FAILED=0
CONFLICTED=0
shopt -s nullglob
for env_file in "$REPO_ROOT"/networks/*.env; do
    sync_one "$env_file"
    rc=$?
    case $rc in
        0) ;;
        2) CONFLICTED=$((CONFLICTED + 1)) ;;
        *) FAILED=$((FAILED + 1)) ;;
    esac
done
shopt -u nullglob

echo ""
if [ "$CONFLICTED" -gt 0 ]; then
    echo "Conflicts: $CONFLICTED network(s) skipped — verify the drift, then re-run with --force." >&2
fi
if [ "$FAILED" -gt 0 ]; then
    echo "Failed: $FAILED network(s). See errors above." >&2
fi
if [ "$FAILED" -gt 0 ] || [ "$CONFLICTED" -gt 0 ]; then
    exit 1
fi
