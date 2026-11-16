#!/usr/bin/env python3
"""ned's network guard (ned --net-guard HOST…, 6.54): the small proxy Copilot's language server goes through, so that
its telemetry is refused (ai.copilotNoTelemetry). With a stand-in for your own proxy (HTTPS_PROXY) and a local echo
server; nothing here reaches the network.

  refused     CONNECT to a host named, or one of its subdomains: 403, never passed on
  passed on   CONNECT to another host goes to your proxy as it came (with Proxy-Authorization from its URL), and the
              bytes flow both ways; with no proxy of yours, straight to the host (200, then the bytes)
  plain HTTP  a request for a host named: 403; another: passed on
  nonsense    not HTTP, or 70 KB of headers: an answer or the connection closed — and the guard still answers
  its end     it ends when its standard input does (ned quitting)

Usage: tnetguard.py path/to/ned"""
import os, socket, subprocess, sys, threading, time

NED = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
results = []


def check(name, ok, info=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(info)[:500]), flush=True)


def serve(handler):
    """a server on 127.0.0.1 that runs handler(conn) for each connection: its port"""
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(16)

    def loop():
        while True:
            c, _ = s.accept()
            threading.Thread(target=handler, args=(c,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()
    return s.getsockname()[1]


seen = []                                   # (what the stand-in for your proxy was sent: the first lines)


def upstream(c):
    """your proxy, played: notes the request, answers CONNECT with 200, then echoes what comes, upper-cased"""
    data = b""
    while b"\r\n\r\n" not in data:
        d = c.recv(4096)
        if not d: return
        data += d
    head = data.split(b"\r\n\r\n")[0].decode("latin-1")
    seen.append(head)
    if head.startswith("CONNECT"):
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    else:
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    rest = data.split(b"\r\n\r\n", 1)[1]
    if rest: c.sendall(rest.upper())
    while True:
        d = c.recv(4096)
        if not d: break
        c.sendall(d.upper())
    c.close()


def echo(c):
    """a host on the far side: echoes what comes, upper-cased"""
    while True:
        d = c.recv(4096)
        if not d: break
        c.sendall(d.upper())
    c.close()


def guard(env):
    """the guard started as ned starts it: (its process, its port)"""
    p = subprocess.Popen([NED, "--net-guard", "blocked.example"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    port = int(p.stdout.readline().decode().strip() or 0)
    return p, port


def ask(port, req, then=b"", wait=2.0):
    """a request to the guard (and bytes after it): all it answered within `wait` seconds"""
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(req)
    if then:
        time.sleep(0.3)
        s.sendall(then)
    s.settimeout(wait)
    got = b""
    try:
        while True:
            d = s.recv(4096)
            if not d: break
            got += d
            if then and then.upper() in got: break
    except socket.timeout:
        pass
    s.close()
    return got


up = serve(upstream)
far = serve(echo)
env = {k: v for k, v in os.environ.items() if k.lower() not in ("https_proxy", "http_proxy", "no_proxy")}
p, port = guard(dict(env, HTTPS_PROXY="http://me:p%%40ss@127.0.0.1:%d" % up))
check("its port, printed first", port > 0, port)
r = ask(port, b"CONNECT blocked.example:443 HTTP/1.1\r\nHost: blocked.example:443\r\n\r\n")
r2 = ask(port, b"CONNECT eu.telemetry.blocked.example:443 HTTP/1.1\r\n\r\n")
check("refused: the host named, and its subdomains (403), never passed on", r.startswith(b"HTTP/1.1 403") and
      r2.startswith(b"HTTP/1.1 403") and not any("blocked.example" in h for h in seen), (r, r2, seen))
r = ask(port, b"CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n", b"hello")
check("passed on: CONNECT to another host goes to your proxy, with its sign-in", any(h.startswith("CONNECT api.github.com:443")
      and "Proxy-Authorization: Basic bWU6cEBzcw==" in h for h in seen) and b"200 Connection established" in r, (seen, r))
check("… and the bytes flow both ways", b"HELLO" in r, r)
r = ask(port, b"GET http://blocked.example/x HTTP/1.1\r\nHost: blocked.example\r\n\r\n")
check("plain HTTP to a host named: 403", r.startswith(b"HTTP/1.1 403"), r)
r = ask(port, b"GET http://other.example/x HTTP/1.1\r\nHost: other.example\r\n\r\n")
check("… to another: passed on", b"200 OK" in r and any(h.startswith("GET http://other.example/x") for h in seen), (r, seen))
r = ask(port, b"\x00\x01 not http\r\n\r\n")
check("not HTTP: 400", r.startswith(b"HTTP/1.1 400"), r)
r = ask(port, b"CONNECT a:1 HTTP/1.1\r\nX: " + b"a" * 70000 + b"\r\n\r\n")
check("70 KB of headers: closed", b"200" not in r, r[:80])
r = ask(port, b"CONNECT blocked.example:443 HTTP/1.1\r\n\r\n")
check("… and it still answers", r.startswith(b"HTTP/1.1 403"), r)
p.stdin.close()
try:
    p.wait(5)
    check("its standard input closed (ned quitting): it ends", p.returncode == 0, p.returncode)
except subprocess.TimeoutExpired:
    p.kill()
    check("its standard input closed (ned quitting): it ends", False, "still running")

# with no proxy of yours: straight to the host
p, port = guard(env)
r = ask(port, b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % far, b"direct")
check("no proxy of yours: straight to the host (200, then the bytes)", r.startswith(b"HTTP/1.1 200") and b"DIRECT" in r, r)
r = ask(port, b"CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")
check("… a host that does not answer: 502", r.startswith(b"HTTP/1.1 502"), r)
p.stdin.close()
p.wait(5)
print("%d/%d passed" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
