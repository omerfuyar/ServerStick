#!/usr/bin/env bash
# Join the tailnet with the baked-in auth key. Run by tailscale-autojoin.service.
# Every line goes to the journal: journalctl -u tailscale-autojoin
#
# Tunables (env, optional): SOCKET_TIMEOUT, NET_TIMEOUT, CLOCK_TIMEOUT, MAX_ATTEMPTS
set -uo pipefail

AUTHKEY_FILE=/etc/tailscale/authkey
SOCKET=/run/tailscale/tailscaled.sock
CONTROL_HOST=controlplane.tailscale.com
TS_HOSTNAME="${TS_HOSTNAME:-stickserver}"
SOCKET_TIMEOUT="${SOCKET_TIMEOUT:-90}"
NET_TIMEOUT="${NET_TIMEOUT:-300}"
CLOCK_TIMEOUT="${CLOCK_TIMEOUT:-30}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-8}"

# "<N>" prefixes set the journal priority (3=err, 4=warning, 5=notice, 6=info).
info() { echo "<6>$*"; }
note() { echo "<5>$*"; }
warn() { echo "<4>$*"; }
err()  { echo "<3>$*"; }

dump_network() {
    info "  ip addr:";  ip -br addr 2>&1 | sed 's/^/<6>    /'
    info "  routes:";   ip route 2>&1   | sed 's/^/<6>    /'
    info "  dns:";      resolvectl dns 2>&1 | sed 's/^/<6>    /'
}

backend_state() {
    tailscale status --json 2>/dev/null \
        | sed -n 's/^[[:space:]]*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

note "step 0/4: checking config (hostname=${TS_HOSTNAME})"
if [[ ! -s "$AUTHKEY_FILE" ]]; then
    err "auth key file $AUTHKEY_FILE is missing or empty; rebuild the ISO with TS_AUTHKEY in .env"
    exit 1
fi
if ! head -c 6 "$AUTHKEY_FILE" | grep -q '^tskey-'; then
    err "auth key in $AUTHKEY_FILE does not start with 'tskey-'"
    exit 1
fi
info "auth key file present ($(stat -c '%a %U' "$AUTHKEY_FILE"))"

note "step 1/4: waiting for tailscaled socket $SOCKET (timeout ${SOCKET_TIMEOUT}s)"
for ((i = 0; i < SOCKET_TIMEOUT; i++)); do
    [[ -S "$SOCKET" ]] && tailscale status --json >/dev/null 2>&1 && break
    sleep 1
done
if [[ ! -S "$SOCKET" ]]; then
    err "tailscaled socket did not appear after ${SOCKET_TIMEOUT}s; check: journalctl -u tailscaled"
    exit 1
fi
state="$(backend_state)"
info "tailscaled is up, backend state: ${state:-unknown}"
if [[ "$state" == "Running" ]]; then
    note "already joined, nothing to do"
    tailscale status 2>&1 | head -n 5 | sed 's/^/<6>  /'
    exit 0
fi

note "step 2/4: waiting for network (resolve $CONTROL_HOST, timeout ${NET_TIMEOUT}s)"
start=$SECONDS
last_log=-30
until getent ahosts "$CONTROL_HOST" >/dev/null 2>&1; do
    elapsed=$((SECONDS - start))
    if ((elapsed >= NET_TIMEOUT)); then
        err "cannot resolve $CONTROL_HOST after ${NET_TIMEOUT}s: no usable network/DNS"
        dump_network
        exit 1
    fi
    if ((elapsed - last_log >= 30)); then
        last_log=$elapsed
        info "still waiting for network (${elapsed}s)"
        ip -br addr 2>&1 | grep -v '^lo ' | sed 's/^/<6>    /'
    fi
    sleep 2
done
info "$CONTROL_HOST resolves to: $(getent ahosts "$CONTROL_HOST" | awk '{print $1}' | sort -u | tr '\n' ' ')"
dump_network

# A wrong clock breaks TLS. Give timesyncd a moment, but don't block on it.
for ((i = 0; i < CLOCK_TIMEOUT; i++)); do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
    sleep 1
done
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    info "clock synchronized: $(date -u '+%F %T UTC')"
else
    warn "clock NOT synchronized yet after ${CLOCK_TIMEOUT}s (now $(date -u '+%F %T UTC')); TLS may fail if it is far off"
fi

note "step 3/4: tailscale up (max ${MAX_ATTEMPTS} attempts)"
delay=5
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    info "attempt ${attempt}/${MAX_ATTEMPTS}: tailscale up --auth-key=file:${AUTHKEY_FILE} --ssh --hostname=${TS_HOSTNAME}"
    out="$(tailscale up --auth-key="file:${AUTHKEY_FILE}" --ssh --hostname="${TS_HOSTNAME}" --timeout=60s 2>&1)"
    rc=$?
    [[ -n "$out" ]] && sed 's/^/<6>  | /' <<<"$out"
    if ((rc == 0)); then
        break
    fi
    warn "tailscale up failed (exit $rc)"
    case "$out" in
        *invalid*key*|*expired*|*"not valid"*) warn "hint: the auth key looks invalid/expired/used-up; create a new reusable key and rebuild" ;;
        *tagOwners*|*"tags"*)                  warn "hint: tagged key needs tagOwners in the tailnet policy (see README)" ;;
        *x509*|*certificate*)                  warn "hint: TLS error; check the clock: $(date -u)" ;;
    esac
    if ((attempt == MAX_ATTEMPTS)); then
        err "giving up after ${MAX_ATTEMPTS} attempts (systemd will restart this unit)"
        exit 1
    fi
    info "retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2 > 60 ? 60 : delay * 2))
done

note "step 4/4: joined"
info "tailscale IPs: $(tailscale ip 2>/dev/null | tr '\n' ' ')"
tailscale status 2>&1 | head -n 10 | sed 's/^/<6>  /'
# The tailnet may hand out "<name>-1" if an old node with the same name still exists.
name="$(tailscale status --json 2>/dev/null \
    | python -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].split(".")[0])' 2>/dev/null)"
[[ -n "$name" && "$name" != "$TS_HOSTNAME" ]] \
    && warn "tailnet name is '$name' (not '$TS_HOSTNAME'): an older node with that name still exists"
note "done: connect with ssh root@${name:-$TS_HOSTNAME}"
