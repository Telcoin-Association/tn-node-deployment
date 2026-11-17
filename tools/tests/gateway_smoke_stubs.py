#!/usr/bin/env python3
"""tools/tests/gateway_smoke_stubs.py -- loopback stubs and a burst client for
tools/tests/gateway_smoke.sh. Python standard library only.

  python3 -I gateway_smoke_stubs.py serve DIR
      Binds three stub servers on free 127.0.0.1 ports in 18000-19999, picks
      three more free ports there for the gateway, writes DIR/ports
      (KEY=port lines: WORKER HEALTH QUERY LISTEN PROBE METRICS) and serves
      until killed.
        WORKER  JSON-RPC stub for the node's worker RPC. Logs every call to
                DIR/worker.log and answers "worker-stub" (eth_chainId 0x7e1,
                eth_sendRawTransaction a hash, eth_getTransactionCount 0x5).
        HEALTH  GET /health/workers; accepting_transactions is true only while
                DIR/accepting holds "true". Each poll goes to DIR/health.log.
        QUERY   JSON-RPC stub for --redirect-queries. Logs to DIR/query.log and
                answers "query-stub" (eth_chainId 0x7e1).
      A log line per call (one per element of a batch):
        id=<id> method=<method> batch=<0|1> xff=<X-Forwarded-For>
        xfp=<X-Forwarded-Proto> xtg=<X-TN-Gateway> xtgr=<X-TN-Gateway-Redirect>
      header values with spaces removed, "-" when absent.

  python3 -I gateway_smoke_stubs.py burst URL XFF_A N_A XFF_B N_B THREADS RATE BURST
      Sends N_A eth_blockNumber POSTs carrying X-Forwarded-For XFF_A over THREADS
      keep-alive connections and, at the same time, N_B carrying XFF_B over one
      more connection. A connection the gateway closed is reopened and the call
      sent again, at most twice. Prints one line of key=value pairs: answers by
      status for each client (acodes/bcodes: every status seen, err:<exception>
      for a call that failed three times, reconnects), t_a / t_b (seconds from
      the start to each client's last
      answer), bound (the most answers a RATE/s, BURST-token bucket can admit in
      t_a), certain (1 when N_A exceeds bound, so a working limiter must refuse
      some) and same_second (1 when client B finished within 1 s of the start).
"""

import http.client
import http.server
import json
import os
import random
import socket
import sys
import threading
import time
import urllib.parse

PORT_LO, PORT_HI = 18000, 19999
AVOID = {8545, 8546, 8655, 8656, 9655, 43174}
_LOG_LOCK = threading.Lock()


def _append(path, lines):
    with _LOG_LOCK:
        with open(path, "a", encoding="utf-8") as f:
            f.writelines(lines)


def _candidates(taken):
    for _ in range(2000):
        p = random.randint(PORT_LO, PORT_HI)
        if p not in taken and p not in AVOID:
            yield p


def _bind_server(handler, taken):
    for p in _candidates(taken):
        try:
            srv = http.server.ThreadingHTTPServer(("127.0.0.1", p), handler)
        except OSError:
            continue
        taken.add(p)
        return srv, p
    raise SystemExit("gateway_smoke_stubs: no free port in 18000-19999")


def _free_port(taken):
    for p in _candidates(taken):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", p))
        except OSError:
            continue
        finally:
            s.close()
        taken.add(p)
        return p
    raise SystemExit("gateway_smoke_stubs: no free port in 18000-19999")


class _Base(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    # The head and the body go out in two writes; without TCP_NODELAY each
    # keep-alive answer waits ~40 ms on the peer's delayed ACK.
    disable_nagle_algorithm = True

    def log_message(self, *_args):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            out = b""
            while True:
                size = int(self.rfile.readline(65537).split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                        pass
                    return out
                out += self.rfile.read(size)
                self.rfile.readline(65537)
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""


class _Rpc(_Base):
    log = ""
    marker = ""

    def _answer(self, method):
        if method == "eth_chainId":
            return "0x7e1"
        if self.marker == "worker-stub":
            if method == "eth_sendRawTransaction":
                return "0x" + "ab" * 32
            if method == "eth_getTransactionCount":
                return "0x5"
        return self.marker

    def do_POST(self):  # noqa: N802 (http.server naming)
        raw = self._read_body()
        try:
            req = json.loads(raw)
        except ValueError:
            req = None
        batch = isinstance(req, list)
        calls = [c if isinstance(c, dict) else {} for c in (req if batch else [req])]

        def hdr(name):
            return (self.headers.get(name) or "-").replace(" ", "")

        _append(self.log, [
            "id=%s method=%s batch=%d xff=%s xfp=%s xtg=%s xtgr=%s\n" % (
                c.get("id"), c.get("method"), int(batch), hdr("X-Forwarded-For"),
                hdr("X-Forwarded-Proto"), hdr("X-TN-Gateway"), hdr("X-TN-Gateway-Redirect"))
            for c in calls])
        answers = [{"jsonrpc": "2.0", "id": c.get("id"), "result": self._answer(c.get("method"))}
                   for c in calls]
        self._send(200, answers if batch else answers[0])


class _Health(_Base):
    log = ""
    control = ""

    def do_GET(self):  # noqa: N802 (http.server naming)
        if self.path.split("?")[0] != "/health/workers":
            self._send(404, {"error": "not found"})
            return
        try:
            with open(self.control, encoding="utf-8") as f:
                accepting = f.read().strip() == "true"
        except OSError:
            accepting = False
        _append(self.log, ["poll accepting=%s\n" % str(accepting).lower()])
        self._send(200, {"version": 1,
                         "workers": [{"worker_id": 0, "accepting_transactions": accepting}]})


def serve(d):
    taken = set()
    kinds = (
        ("WORKER", type("WorkerStub", (_Rpc,), {"log": os.path.join(d, "worker.log"),
                                                 "marker": "worker-stub"})),
        ("HEALTH", type("HealthStub", (_Health,), {"log": os.path.join(d, "health.log"),
                                                    "control": os.path.join(d, "accepting")})),
        ("QUERY", type("QueryStub", (_Rpc,), {"log": os.path.join(d, "query.log"),
                                              "marker": "query-stub"})),
    )
    ports = []
    for name, handler in kinds:
        srv, port = _bind_server(handler, taken)
        ports.append((name, port))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    for name in ("LISTEN", "PROBE", "METRICS"):
        ports.append((name, _free_port(taken)))
    tmp = os.path.join(d, "ports.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines("%s=%d\n" % kv for kv in ports)
    os.replace(tmp, os.path.join(d, "ports"))
    threading.Event().wait()


def burst(url, xff_a, n_a, xff_b, n_b, threads, rate, bucket):
    u = urllib.parse.urlsplit(url)
    body = json.dumps({"jsonrpc": "2.0", "id": "rl", "method": "eth_blockNumber",
                       "params": []}).encode()
    counts = {"a": {}, "b": {}}
    ends = {"a": [], "b": []}
    lock = threading.Lock()
    go = threading.Event()

    def run(key, xff, n):
        conn = None
        go.wait()
        for _ in range(n):
            # A keep-alive connection the gateway closed after its last answer
            # fails on reuse before the request is read: open a new one and
            # send again (counted as "reconnects"), at most twice.
            for attempt in range(3):
                try:
                    if conn is None:
                        conn = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
                    conn.request("POST", "/", body, {"Content-Type": "application/json",
                                                     "X-Forwarded-For": xff})
                    resp = conn.getresponse()
                    resp.read()
                    code = str(resp.status)
                    if resp.will_close:
                        conn.close()
                        conn = None
                    break
                except (OSError, http.client.HTTPException) as e:
                    code = "err:" + type(e).__name__
                    if conn is not None:
                        conn.close()
                    conn = None
                    if attempt < 2:
                        with lock:
                            counts[key]["reconnects"] = counts[key].get("reconnects", 0) + 1
            with lock:
                counts[key][code] = counts[key].get(code, 0) + 1
        if conn is not None:
            conn.close()
        with lock:
            ends[key].append(time.monotonic())

    shares = [n_a // threads + (1 if i < n_a % threads else 0) for i in range(threads)]
    workers = [threading.Thread(target=run, args=("a", xff_a, s)) for s in shares if s]
    workers.append(threading.Thread(target=run, args=("b", xff_b, n_b)))
    for t in workers:
        t.start()
    start = time.monotonic()
    go.set()
    for t in workers:
        t.join()
    t_a = max(ends["a"]) - start
    t_b = max(ends["b"]) - start
    bound = bucket + int(rate * t_a) + 1
    a, b = counts["a"], counts["b"]

    def codes(c):
        return ",".join("%s:%d" % kv for kv in sorted(c.items())) or "-"

    print("a200=%d a429=%d aother=%d b200=%d b429=%d bother=%d t_a=%.3f t_b=%.3f bound=%d "
          "certain=%d same_second=%d acodes=%s bcodes=%s" % (
              a.get("200", 0), a.get("429", 0), n_a - a.get("200", 0) - a.get("429", 0),
              b.get("200", 0), b.get("429", 0), n_b - b.get("200", 0) - b.get("429", 0),
              t_a, t_b, bound, int(n_a > bound), int(t_b < 1.0), codes(a), codes(b)))


def main(argv):
    if len(argv) == 3 and argv[1] == "serve":
        serve(argv[2])
        return 0
    if len(argv) == 10 and argv[1] == "burst":
        burst(argv[2], argv[3], int(argv[4]), argv[5], int(argv[6]), int(argv[7]),
              int(argv[8]), int(argv[9]))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
