# shellcheck shell=bash
# Parsing for IDEKUBE_* environment variables, sourced by bash scripts.
#
# Two identical copies (scripts/ci/tests/test_env_flags.py checks it):
#   artifacts/rootfs/usr/local/lib/idekube/env.sh         Docker images, QEMU guest
#   qemu-builder/artifacts/startup-scripts/idekube-env.sh QEMU container entrypoint
#
# The values usually come from Kubernetes manifests or Helm templates, so an
# empty value means "not set" and anything unrecognised is a configuration
# error: the caller is expected to stop instead of guessing. Every function
# prints the parsed value on stdout, or a message on stderr and returns 2.

_idekube_trim() {
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    printf '%s' "$v"
}

# idekube_bool NAME [DEFAULT]: print 1 or 0. true/false, 1/0, yes/no, on/off
# in any letter case; unset or empty gives DEFAULT (0).
idekube_bool() {
    local name=$1 default=${2:-0} value
    value=$(_idekube_trim "${!name:-}")
    if [[ -z "$value" ]]; then
        echo "$default"
        return 0
    fi
    case "${value,,}" in
        1|true|yes|on) echo 1 ;;
        0|false|no|off) echo 0 ;;
        *)
            echo "Error: ${name}='${value}' is not a boolean (use true/false, 1/0, yes/no or on/off)" >&2
            return 2
            ;;
    esac
}

# idekube_uint NAME DEFAULT: print a non-negative decimal integer.
idekube_uint() {
    local name=$1 default=$2 value
    value=$(_idekube_trim "${!name:-}")
    if [[ -z "$value" ]]; then
        echo "$default"
        return 0
    fi
    if [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
        echo $((10#$value))
        return 0
    fi
    echo "Error: ${name}='${value}' is not a non-negative integer" >&2
    return 2
}

# _idekube_ipv4_prefix VALUE MIN MAX: VALUE is a.b.c.d/len with MIN <= len <= MAX.
_idekube_ipv4_prefix() {
    local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$' i
    [[ "$1" =~ $re ]] || return 1
    for i in 1 2 3 4; do
        (( 10#${BASH_REMATCH[i]} <= 255 )) || return 1
    done
    (( 10#${BASH_REMATCH[5]} >= $2 && 10#${BASH_REMATCH[5]} <= $3 ))
}

# idekube_docker_bip NAME DEFAULT: Docker's "bip", the bridge's own address
# with its prefix length (e.g. 10.213.0.1/24), prefix 8-30.
idekube_docker_bip() {
    local name=$1 default=$2 value
    value=$(_idekube_trim "${!name:-}")
    if [[ -z "$value" ]]; then
        echo "$default"
        return 0
    fi
    if _idekube_ipv4_prefix "$value" 8 30; then
        echo "$value"
        return 0
    fi
    echo "Error: ${name}='${value}' is not an IPv4 address with a /8-/30 prefix (e.g. 10.213.0.1/24)" >&2
    return 2
}

# idekube_docker_pools NAME DEFAULT: Docker "default-address-pools" as
# comma-separated base/len:size items (e.g. 10.214.0.0/16:24), where every
# network Docker creates gets a /size out of base/len (len <= size <= 30).
idekube_docker_pools() {
    local name=$1 default=$2 value item base size
    local -a items
    value=$(_idekube_trim "${!name:-}")
    if [[ -z "$value" ]]; then
        echo "$default"
        return 0
    fi
    IFS=',' read -r -a items <<< "$value"
    for item in "${items[@]}"; do
        item=$(_idekube_trim "$item")
        base=${item%:*}
        size=${item##*:}
        if [[ "$item" != *:* ]] || [[ ! "$size" =~ ^[0-9]{1,2}$ ]] \
            || ! _idekube_ipv4_prefix "$base" 8 30 \
            || (( 10#$size < 10#${base##*/} || 10#$size > 30 )); then
            echo "Error: ${name}: '${item}' is not base/len:size with len <= size <= 30 (e.g. 10.214.0.0/16:24)" >&2
            return 2
        fi
    done
    printf '%s\n' "${value//[[:space:]]/}"
}
