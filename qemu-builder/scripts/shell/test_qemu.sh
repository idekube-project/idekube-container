#!/usr/bin/env bash
#
# test_qemu.sh — smoke test of a built QEMU runtime image.
#
#   make qemu-test BRANCH=featured/base        (or featured/kathara)
#   QEMU_TEST_IMAGE=<ref> to test another tag than the one build_qemu.sh made
#
# The pytest suite (tests/) drives containers through docker exec and their
# own ports, so it does not cover QEMU images; this script is their test.
# It boots the image three times on one volume, the way a Pod restarts:
#   1. invalid configuration is refused before anything touches the disk;
#   2. first boot: nginx auth, landing page, proxied services, SSH (key only,
#      through the loopback relay), hardening, locked password, KVM;
#      kathara: Docker on its own address ranges, containers reach the net;
#   3. docker stop right after writing a file: the guest powers off cleanly,
#      and the next boot (IDEKUBE_VM_RESET_DISK=false) still has the file;
#   4. IDEKUBE_VM_RESET_DISK=true replaces the disk; kathara: the Docker
#      address ranges follow IDEKUBE_VM_DOCKER_* from the environment.
# Needs docker, a usable /dev/kvm, ssh, ssh-keygen, curl and jq (sshpass
# optional). Exit status is the number of failed checks (capped at 100).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/qemu_common.sh"
IMAGE="${QEMU_TEST_IMAGE:-${IMAGE_REF}}"
KATHARA=0
[[ "${BRANCH}" == featured/kathara ]] && KATHARA=1

NAME="idekube-qemu-test-$$"
VOLUME="${NAME}-data"
WORK=$(mktemp -d)
KEY="${WORK}/id_ed25519"
TOKEN="Smoke.Test_123"
TOKEN_RE=${TOKEN//./\\.}          # as authn.sh writes it into the nginx map
SHUTDOWN_TIMEOUT=25
PASS=0
FAIL=0

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1
    docker volume rm -f "${VOLUME}" >/dev/null 2>&1
    rm -rf "${WORK}"
}
trap cleanup EXIT

ok()  { echo "PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
check() {
    local description=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "${description}"; else bad "${description}"; fi
}

for tool in docker ssh ssh-keygen curl jq; do
    command -v "${tool}" >/dev/null || { echo "Error: ${tool} is required" >&2; exit 100; }
done
if ! ( exec 3<>/dev/kvm ) 2>/dev/null; then
    echo "Error: /dev/kvm is not usable; the smoke test needs KVM" >&2
    exit 100
fi
docker image inspect "${IMAGE}" >/dev/null 2>&1 || { echo "Error: image ${IMAGE} not found (make qemu-image BRANCH=${BRANCH})" >&2; exit 100; }
ssh-keygen -q -t ed25519 -N '' -f "${KEY}"
echo "Testing ${IMAGE}"

BASE_ENV=(
    -e IDEKUBE_VM_MEMORY=4G -e IDEKUBE_VM_CPU=2
    -e "IDEKUBE_ACCESS_TOKEN=${TOKEN}"
    -e "IDEKUBE_AUTHORIZED_KEYS=$(base64 -w0 "${KEY}.pub")"
    -e IDEKUBE_VM_REQUIRE_KVM=true
    -e "IDEKUBE_VM_SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT}"
)

start_vm() {
    docker rm -f "${NAME}" >/dev/null 2>&1
    docker run -d --name "${NAME}" --device /dev/kvm \
        -p 127.0.0.1::22 -p 127.0.0.1::80 \
        -v "${VOLUME}:/var/lib/data" \
        "${BASE_ENV[@]}" "$@" "${IMAGE}" >/dev/null || return 1
    SSH_PORT=$(docker port "${NAME}" 22/tcp | head -n1 | cut -d: -f2)
    WEB="http://127.0.0.1:$(docker port "${NAME}" 80/tcp | head -n1 | cut -d: -f2)"
}
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }
vssh() {
    ssh -i "${KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes idekube@127.0.0.1 "$@"
}
# Wait for /health 200 and for key SSH (vm-init.sh installs the key).
wait_vm() {
    local t0=${SECONDS}
    until [[ $(code "${WEB}/health") == 200 ]] && vssh true 2>/dev/null; do
        if ! docker ps -q -f "name=^${NAME}$" | grep -q .; then
            echo "  container exited:"; docker logs --tail 30 "${NAME}" 2>&1 | sed 's/^/    /'
            return 1
        fi
        (( SECONDS - t0 > 300 )) && return 1
        sleep 3
    done
    echo "  up after $((SECONDS - t0))s"
}
all_healthy() {
    curl -s -m 10 "${WEB}/health" | jq -e '[.services[] | .healthy] | all' >/dev/null
}

# ---------------------------------------------------------------------------
echo "== 1. invalid configuration is refused"
refused() {
    local description=$1 expect=$2
    shift 2
    local out rc
    out=$(timeout 120 docker run --rm "${BASE_ENV[@]}" "$@" "${IMAGE}" 2>&1)
    rc=$?
    if (( rc != 0 )) && grep -q -- "${expect}" <<< "${out}"; then
        ok "${description}"
    else
        bad "${description} (exit ${rc}: $(tail -n1 <<< "${out}"))"
    fi
}
refused "IDEKUBE_VM_RESET_DISK=maybe" "IDEKUBE_VM_RESET_DISK='maybe' is not a boolean" -e IDEKUBE_VM_RESET_DISK=maybe
refused "IDEKUBE_INIT_HOME=ture" "IDEKUBE_INIT_HOME='ture' is not a boolean" -e IDEKUBE_INIT_HOME=ture
refused "REQUIRE_KVM together with DISABLE_KVM" "are both true" -e IDEKUBE_VM_DISABLE_KVM=1
refused "IDEKUBE_VM_SHUTDOWN_TIMEOUT=soon" "is not a non-negative integer" -e IDEKUBE_VM_SHUTDOWN_TIMEOUT=soon
refused "IDEKUBE_VM_DOCKER_BIP without prefix" "IDEKUBE_VM_DOCKER_BIP='172.17.0.1' is not" -e IDEKUBE_VM_DOCKER_BIP=172.17.0.1
refused "IDEKUBE_VM_DOCKER_ADDRESS_POOLS without size" "is not base/len:size" -e IDEKUBE_VM_DOCKER_ADDRESS_POOLS=10.214.0.0/16

# ---------------------------------------------------------------------------
echo "== 2. first boot (empty values as a template would render them)"
start_vm -e IDEKUBE_VM_RESET_DISK=false -e IDEKUBE_INIT_HOME= -e IDEKUBE_VM_DOCKER_BIP= || { bad "container start"; exit 1; }
if ! wait_vm; then
    bad "first boot: /health and key SSH"
    exit "$(( FAIL > 100 ? 100 : FAIL ))"
fi
for _ in $(seq 1 36); do all_healthy && break; sleep 5; done
echo "  health: $(curl -s -m 10 "${WEB}/health" | jq -c .)"
check "/health reports every service healthy" all_healthy
check "KVM in use (IDEKUBE_VM_REQUIRE_KVM=true)" bash -c "docker logs '${NAME}' 2>&1 | grep -q 'Acceleration:  -accel kvm'"

[[ $(code "${WEB}/") == 401 ]] && ok "/ without token -> 401" || bad "/ without token -> $(code "${WEB}/")"
[[ $(code -H "X-IDEKube-Container-Access-Token: wrong" "${WEB}/") == 401 ]] && ok "wrong token -> 401" || bad "wrong token accepted"
[[ $(code -H "X-IDEKube-Container-Access-Token: ${TOKEN,,}" "${WEB}/") == 401 ]] && ok "token is case-sensitive" || bad "case-folded token accepted"
headers=$(curl -s -m 10 -D - -o /dev/null "${WEB}/coder/?idekube-container-access-token=${TOKEN}")
location=$(grep -i '^location:' <<< "${headers}" | tr -d '\r' | cut -d' ' -f2)
if grep -q '^HTTP/1.1 302' <<< "${headers}" && [[ "${location}" == /* && "${location}" != //* ]]; then
    ok "query token -> 302 to a relative path (${location})"
else
    bad "query token redirect: $(head -n1 <<< "${headers}") location=${location}"
fi
grep -i '^set-cookie:' <<< "${headers}" | grep -qi httponly && ok "token cookie is HttpOnly" || bad "token cookie flags"
COOKIE=(-b "idekube_container_access_token=${TOKEN}")
landing=$(curl -s -m 10 "${COOKIE[@]}" "${WEB}/")
[[ $(code "${COOKIE[@]}" "${WEB}/") == 200 ]] && ok "landing page with cookie -> 200" || bad "landing page with cookie"
version_found=0
for asset in $(grep -o 'assets/[^"]*\.js' <<< "${landing}"); do
    curl -s -m 10 "${COOKIE[@]}" "${WEB}/${asset}" | grep -qE 'v[0-9][^"]*-[0-9a-f]{7}' && version_found=1
done
(( version_found )) && ok "landing page is the IDEKube frontend with its build version" || bad "landing page has no build version (nginx default page?)"
[[ $(code "${COOKIE[@]}" "${WEB}/coder/") == 200 ]] && ok "/coder/ -> 200" || bad "/coder/ -> $(code "${COOKIE[@]}" "${WEB}/coder/")"
[[ $(code "${COOKIE[@]}" "${WEB}/vnc/vnc.html") == 200 ]] && ok "/vnc/vnc.html -> 200" || bad "/vnc/vnc.html"
[[ $(code -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -m 5 "${WEB}/ssh") == 101 ]] \
    && ok "/ssh websocket upgrade without token -> 101" || bad "/ssh websocket upgrade"
[[ $(code "${COOKIE[@]}" "${WEB}/no-such-page") == 302 ]] && ok "unknown path -> 302 home" || bad "unknown path"

ok "SSH with the injected key"
check "the guest sees forwarded connections from 10.0.2.2 (loopback relay)" bash -c "[[ \$(ssh -i '${KEY}' -p '${SSH_PORT}' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes idekube@127.0.0.1 'echo \${SSH_CLIENT%% *}') == 10.0.2.2 ]]"
if command -v sshpass >/dev/null; then
    check "password SSH is refused" bash -c "! sshpass -p idekube ssh -p '${SSH_PORT}' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no idekube@127.0.0.1 true"
fi
check "idekube's password is locked" bash -c "[[ \$(ssh -i '${KEY}' -p '${SSH_PORT}' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes idekube@127.0.0.1 'sudo passwd -S idekube' | cut -d' ' -f2) == L ]]"
check "no failed units; all IDE services active" vssh '! systemctl --failed --no-legend | grep -q . && for u in nginx ssh websocat turbovnc novnc code-server idekube-healthcheck; do systemctl is-active -q $u || exit 1; done && systemctl show -p Result idekube-authn | grep -q success'
check "nginx -t in the guest" vssh 'sudo nginx -t'
check "token map rendered (fail-closed default replaced)" vssh "sudo grep -qF -- '${TOKEN_RE}' /etc/nginx/conf.d/access_token.conf && ! sudo grep -q 'Fail-closed default' /etc/nginx/conf.d/access_token.conf"
check "token not in the nginx logs" vssh "! sudo grep -rqF -- '${TOKEN}' /var/log/nginx/"
check "code-server, noVNC and VNC listen on loopback only" vssh "! sudo ss -Hltn | awk '{print \$4}' | grep -E ':(3000|6081|5901)\$' | grep -vE '^(127\\.0\\.0\\.1|\\[::1\\]):'"
check "home directory is 750" vssh '[[ $(stat -c %a /home/idekube) == 750 ]]'
check "VNC desktop running (Xvnc + xfce4-session)" vssh 'pgrep -f Xvnc && pgrep -f xfce4-session'

if (( KATHARA )); then
    check "docker active in the VM" vssh 'systemctl is-active -q docker && sudo docker info'
    check "docker0 on the default 10.213.0.1/24" vssh "ip -br addr show docker0 | grep -q '10\\.213\\.0\\.1/24'"
    check "Docker networks default to 10.214.0.0/16:24" vssh "sudo jq -e '.\"default-address-pools\" == [{\"base\":\"10.214.0.0/16\",\"size\":24}]' /etc/docker/daemon.json"
    check "kathara CLI present" vssh 'command -v kathara && kathara --version'
    check "a container in the VM reaches the internet" vssh 'timeout 180 sudo docker run --rm alpine:3.24 wget -q -O /dev/null http://dl-cdn.alpinelinux.org/alpine/'
fi
# The original kathara failure: forwards died ~12 s into boot, once dockerd
# created docker0. Re-check both forwards well after that.
until (( $(vssh 'cut -d. -f1 /proc/uptime' 2>/dev/null || echo 999) >= 60 )); do sleep 5; done
check "SSH still forwarded after 60 s of uptime" vssh true
check "HTTP still forwarded after 60 s of uptime" bash -c "[[ \$(curl -s -m 10 -o /dev/null -w '%{http_code}' '${WEB}/health') == 200 ]]"

# ---------------------------------------------------------------------------
echo "== 3. docker stop right after a write: clean guest power-off, data kept"
vssh 'echo persisted > /home/idekube/persist-marker'          # no sync on purpose
(( KATHARA )) && vssh 'sudo docker create --name idekube-persist alpine:3.24 true >/dev/null'
t0=${SECONDS}
docker stop -t $((SHUTDOWN_TIMEOUT + 15)) "${NAME}" >/dev/null
stop_seconds=$((SECONDS - t0))
logs=$(docker logs "${NAME}" 2>&1)
grep -q 'reboot: Power down' <<< "${logs}" && ok "guest powered off cleanly on docker stop (${stop_seconds}s)" || bad "no clean guest power-off on docker stop (${stop_seconds}s)"
grep -q 'Guest powered off.' <<< "${logs}" && ok "run.sh waited for the guest" || bad "run.sh did not report the guest power-off"

start_vm -e IDEKUBE_VM_RESET_DISK=false || { bad "container restart"; exit 1; }
if wait_vm; then
    check "IDEKUBE_VM_RESET_DISK=false kept the disk; the file survived" vssh 'grep -qx persisted /home/idekube/persist-marker'
    check "no ext4 journal recovery after the stop" vssh "! sudo dmesg | grep -qE 'EXT4-fs .*(recovery complete|recovering journal)'"
    if (( KATHARA )); then
        check "docker active after the restart" vssh 'systemctl is-active -q docker'
        check "the container created before the stop is still there" vssh 'sudo docker inspect idekube-persist'
    fi
else
    bad "restart: /health and key SSH"
fi

# ---------------------------------------------------------------------------
echo "== 4. IDEKUBE_VM_RESET_DISK=TRUE replaces the disk"
docker stop -t $((SHUTDOWN_TIMEOUT + 15)) "${NAME}" >/dev/null
RESET_ENV=(-e IDEKUBE_VM_RESET_DISK=TRUE)
(( KATHARA )) && RESET_ENV+=(-e IDEKUBE_VM_DOCKER_BIP=10.99.0.1/24 -e "IDEKUBE_VM_DOCKER_ADDRESS_POOLS=10.100.0.0/16:24, 10.101.0.0/16:26")
start_vm "${RESET_ENV[@]}" || { bad "container restart"; exit 1; }
if wait_vm; then
    check "the reset disk no longer has the file" vssh '[[ ! -e /home/idekube/persist-marker ]]'
    if (( KATHARA )); then
        check "docker0 follows IDEKUBE_VM_DOCKER_BIP" vssh "ip -br addr show docker0 | grep -q '10\\.99\\.0\\.1/24'"
        check "address pools follow IDEKUBE_VM_DOCKER_ADDRESS_POOLS" vssh "sudo jq -e '.\"default-address-pools\" == [{\"base\":\"10.100.0.0/16\",\"size\":24},{\"base\":\"10.101.0.0/16\",\"size\":26}]' /etc/docker/daemon.json"
    fi
else
    bad "reset boot: /health and key SSH"
fi

echo "RESULT ${IMAGE}: ${PASS} passed, ${FAIL} failed"
exit $(( FAIL > 100 ? 100 : FAIL ))
