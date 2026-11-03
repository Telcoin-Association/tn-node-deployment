#!/usr/bin/env bash
# =============================================================================
# V3 real-image proof with grafana/alloy:v1.5.1 (host with docker, python3, openssl).
#   F. `alloy fmt` accepts the rendered config (logs-only, metrics-only, both)
#   R1 --user 473:473 without --group-add: the 0640 root:<gid> token file is refused
#   R2 --user 473:473 with --group-add <gid>: read, the hub gets "Bearer <token>"
#   R3 the rendered sidecar flags (image user root, --cap-drop=ALL, --group-add): read
#   R4 a TLS 1.2-only hub: refused by min_version TLS13
#   Every run: the TLS server name comes from OBS_METRICS_PUSH_HOST (the URL host is
#   127.0.0.1, the certificate names only obs.test), and whether the container stays
#   running (what an is-active settle check sees) when the token cannot be read.
# Output: records/real-image.txt.   bash tasks/verify-fup/V3/real_image.sh
# =============================================================================
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
REPO="$PWD"; V="$REPO/tasks/verify-fup/V3"; OUT="$V/records/real-image.txt"
IMG=grafana/alloy:v1.5.1; GID=990
W="$(mktemp -d)"; chmod 0755 "$W"
cleanup() { docker rm -f v3-alloy >/dev/null 2>&1; [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null
    docker run --rm -v "$W:/d" ubuntu:24.04 rm -rf /d/cred /d/run.alloy /d/data0 /d/data1 /d/data2 /d/data3 /d/data4 >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
say "# real-image proof $(date -u +%FT%TZ) image $IMG ($(docker image inspect $IMG --format '{{.Id}}' | cut -c1-19)) default user='$(docker image inspect $IMG --format '{{.Config.User}}')'"
TOKEN="v3-real-token-$(date +%s)-0123456789abcdef"

# --- configs rendered by the library itself -----------------------------------------
for combo in "true true" "true false" "false true"; do
    set -- $combo
    bash -c 'source "$1/lib/common.sh"; set +e; ENABLE_OBSERVABILITY=$2; ENABLE_METRICS=$3
      chown() { :; }; obs_write_config_alloy "$4"' _ "$REPO" "$1" "$2" "$W/cfg-$1-$2.alloy" >/dev/null 2>&1
    docker run --rm -v "$W:/c:ro" $IMG fmt "/c/cfg-$1-$2.alloy" > "$W/fmt.out" 2>&1; rc=$?
    say "F  alloy fmt logs=$1 metrics=$2: rc=$rc $(grep -ci error "$W/fmt.out") error lines"
done
cp "$W/cfg-false-true.alloy" "$W/run-open.alloy"; chmod 0644 "$W/run-open.alloy"
cp "$W/cfg-false-true.alloy" "$W/run.alloy"   # production ownership: root:root 0640 (set below)

# --- a hub: TLS server on 127.0.0.1 with a cert for obs.test only -------------------
cd "$W" || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=v3-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj /CN=obs.test >/dev/null 2>&1
printf 'subjectAltName=DNS:obs.test\n' > ext.cnf
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile ext.cnf >/dev/null 2>&1
cat > hub.py <<'PY'
import http.server, ssl, sys
port, maxv, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0); self.rfile.read(n)
        with open(log, 'a') as f:
            f.write('POST %s auth=%s tls=%s\n' % (self.path, self.headers.get('Authorization'), self.connection.version()))
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain('srv.pem', 'srv.key')
if maxv == '1.2': ctx.maximum_version = ssl.TLSVersion.TLSv1_2
s = http.server.HTTPServer(('127.0.0.1', port), H); s.socket = ctx.wrap_socket(s.socket, server_side=True); s.serve_forever()
PY
cat /etc/ssl/certs/ca-certificates.crt ca.pem > bundle.pem 2>/dev/null || cp ca.pem bundle.pem
mkdir -p cred data0 data1 data2 data3 data4; printf '%s\n' "$TOKEN" > cred/ingest-token
docker run --rm -v "$W:/d" ubuntu:24.04 sh -c "chown 0:$GID /d/cred/ingest-token && chmod 0640 /d/cred/ingest-token && chmod 0777 /d/data0 /d/data1 /d/data2 && chown 0:0 /d/data3 /d/data4 && chmod 0750 /d/data3 /d/data4 && chown 0:0 /d/run.alloy && chmod 0640 /d/run.alloy"
say "token file on the host: $(stat -c '%a %u:%g' cred/ingest-token)"
printf 'TN_NODE=v3\nTN_REGION=eu\nTN_VALIDATOR_ADDRESS=\nTN_CHAIN=adiri\nTN_IMAGE_VERSION=x\nTN_METRICS_ADDR=127.0.0.1:12346\nOBS_METRICS_PUSH_URL=https://127.0.0.1:%s/api/v1/write\nOBS_METRICS_PUSH_HOST=obs.test\nCREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy\n' 18443 > env.tls13
sed 's/18443/18444/' env.tls13 > env.tls12
python3 hub.py 18443 1.3 hub13.log & SRV=$!
python3 hub.py 18444 1.2 hub12.log & SRV="$SRV $!"
sleep 1

runit() { # runit NAME CONFIG ENVFILE HUBLOG docker-flags...
    local name="$1" cfg="$2" envf="$3" hub="$4" dd="data${1#R}"; shift 4
    dd="${dd%% *}"
    : > "$hub"; docker rm -f v3-alloy >/dev/null 2>&1
    docker run -d --name v3-alloy --network=host "$@" --env-file "$W/$envf" \
        -v "$W/$cfg:/etc/alloy/config.alloy:ro" -v "$W/bundle.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
        --mount "type=bind,source=$W/cred/ingest-token,target=/run/credentials/telcoin-alloy/ingest-token,readonly" \
        -v "$W/$dd:/var/lib/telcoin-alloy" $IMG run --server.http.listen-addr=127.0.0.1:12346 \
        --storage.path=/var/lib/telcoin-alloy /etc/alloy/config.alloy >/dev/null
    sleep 40
    local running; running="$(docker inspect v3-alloy --format '{{.State.Running}} restarts={{.RestartCount}}')"
    local cat_rc; docker exec v3-alloy cat /run/credentials/telcoin-alloy/ingest-token >/dev/null 2>&1; cat_rc=$?
    say "$name: container running after 40 s: $running; cat of the token inside: rc=$cat_rc"
    say "$name: hub saw $(grep -c POST "$hub") pushes; with the token: $(grep -c "auth=Bearer $TOKEN tls=TLSv1.3" "$hub"); first: $(head -n 1 "$hub" | sed "s/$TOKEN/<token>/")"
    say "$name: first alloy error: $(docker logs v3-alloy 2>&1 | grep -E 'level=(warn|error)|^Error' | head -n 1 | sed -e "s/$TOKEN/<token>/g" -e 's/.*\(err=.*\)/\1/' | cut -c1-400)"
    docker logs v3-alloy 2>&1 | grep -c "$TOKEN" | sed "s/^/$name: log lines holding the token value: /" | tee -a "$OUT"
    docker inspect v3-alloy | grep -c "$TOKEN" | sed "s/^/$name: docker inspect lines holding the token value: /" | tee -a "$OUT"
}
say "config for R1/R2: 0644 (isolates the token file); R0/R3/R4: root:root 0640, as obs_render_config_alloy writes it for docker"
runit "R0 --user 473:473 --group-add $GID, production config" run.alloy env.tls13 hub13.log --user 473:473 --group-add $GID --cap-drop=ALL --security-opt=no-new-privileges
runit "R1 --user 473:473, no --group-add" run-open.alloy env.tls13 hub13.log --user 473:473 --cap-drop=ALL --security-opt=no-new-privileges
runit "R2 --user 473:473 --group-add $GID" run-open.alloy env.tls13 hub13.log --user 473:473 --group-add $GID --cap-drop=ALL --security-opt=no-new-privileges
runit "R3 rendered flags (image user, --cap-drop=ALL, --group-add $GID, --ulimit core=0)" run.alloy env.tls13 hub13.log --ulimit core=0 --cap-drop=ALL --security-opt=no-new-privileges --group-add $GID
runit "R4 TLS 1.2-only hub, rendered flags" run.alloy env.tls12 hub12.log --ulimit core=0 --cap-drop=ALL --security-opt=no-new-privileges --group-add $GID
say "commands: see runit() in tasks/verify-fup/V3/real_image.sh (docker run -d --network=host <flags> --env-file ... --mount type=bind,...,readonly $IMG run ...)"
