"""The two clients of ned's IDE link (ai.ideLink), for the tests: Claude Code's (MCP over a WebSocket, the token in
x-claude-code-ide-authorization) and Gemini CLI's (MCP over HTTP with a Bearer token, its events on a GET stream) —
on raw sockets, so that a test can also send what no real client would (unmasked frames, huge lengths, bad
headers)."""
import base64, json, os, socket, time


class Ws:
    """a WebSocket client: connect() does the handshake; send()/recv() whole text messages; frame() any frame"""

    def __init__(self, port, token, extra=b"", host="127.0.0.1", proto=None):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16))
        req = (b"GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               b"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n" % (host.encode(), port, key))
        if token is not None: req += b"x-claude-code-ide-authorization: " + token.encode() + b"\r\n"
        if proto: req += b"Sec-WebSocket-Protocol: " + proto.encode() + b"\r\n"
        self.s.sendall(req + extra + b"\r\n")
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            d = self.s.recv(65536)
            if not d: break
            self.buf += d
        self.head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        self.status = int(self.head.split(b" ")[1]) if self.head.startswith(b"HTTP/1.1 ") else 0
        self.events = []                               # notifications that came while waiting for an answer
        self.nid = 0

    def frame(self, op, payload, fin=True, mask=True, length=None):
        """one frame as a client sends it (or not: mask=False, a length that lies)"""
        n = len(payload) if length is None else length
        b = bytes([(0x80 if fin else 0) | op])
        m = 0x80 if mask else 0
        if n < 126: b += bytes([m | n])
        elif n < 65536: b += bytes([m | 126]) + n.to_bytes(2, "big")
        else: b += bytes([m | 127]) + n.to_bytes(8, "big")
        if mask:
            k = os.urandom(4)
            b += k + bytes(c ^ k[i % 4] for i, c in enumerate(payload))
        else:
            b += payload
        self.s.sendall(b)

    def read_frame(self, timeout=10):
        """(opcode, payload) of the next frame from the server; (None, b'') when it closed or nothing came"""
        self.s.settimeout(timeout)
        try:
            while True:
                if len(self.buf) >= 2:
                    n = self.buf[1] & 0x7f
                    at = 2
                    if n == 126 and len(self.buf) >= 4: n, at = int.from_bytes(self.buf[2:4], "big"), 4
                    elif n == 127 and len(self.buf) >= 10: n, at = int.from_bytes(self.buf[2:10], "big"), 10
                    if n < 126 or at > 2:
                        if len(self.buf) >= at + n:
                            op, p = self.buf[0] & 0x0f, self.buf[at:at + n]
                            self.buf = self.buf[at + n:]
                            return op, p
                d = self.s.recv(65536)
                if not d: return None, b""
                self.buf += d
        except (socket.timeout, OSError):
            return None, b""

    def send(self, obj):
        self.frame(1, json.dumps(obj).encode())

    def recv(self, timeout=10):
        """the next message (a dict), None when none came"""
        end = time.time() + timeout
        while time.time() < end:
            op, p = self.read_frame(max(0.1, end - time.time()))
            if op is None: return None
            if op == 1: return json.loads(p)
        return None

    def call(self, method, params=None, timeout=10):
        """a request and its answer (the notifications that come before it are kept in events)"""
        self.nid += 1
        self.send({"jsonrpc": "2.0", "id": self.nid, "method": method, "params": params or {}})
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv(max(0.1, end - time.time()))
            if m is None: return None
            if m.get("id") == self.nid: return m
            self.events.append(m)
        return None

    def tool(self, name, args=None, timeout=10):
        """a tool's result: its first text (parsed when it is JSON), or the whole answer when it has none"""
        r = self.call("tools/call", {"name": name, "arguments": args or {}}, timeout)
        if r is None or "result" not in r: return r
        c = r["result"].get("content", [])
        if not c: return r["result"]
        t = c[0].get("text", "")
        try: return json.loads(t)
        except ValueError: return t

    def wait_event(self, method, timeout=8, pred=lambda p: True):
        """a notification of that method (one kept already, or one that comes)"""
        for e in self.events:
            if e.get("method") == method and pred(e.get("params", {})):
                self.events.remove(e)
                return e["params"]
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv(max(0.1, end - time.time()))
            if m is None: return None
            if m.get("method") == method and pred(m.get("params", {})): return m["params"]
            self.events.append(m)
        return None

    def close(self):
        try: self.s.close()
        except OSError: pass


def http(port, method, path="/mcp", body=b"", token=None, headers=None, host=None, sock=None, timeout=10):
    """one HTTP request: (status, headers dict, body); `sock` keeps the connection (keep-alive)"""
    s = sock or socket.create_connection(("127.0.0.1", port), timeout=timeout)
    h = {"Host": host or "127.0.0.1:%d" % port, "Content-Length": str(len(body)),
         "Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
    if token is not None: h["Authorization"] = "Bearer " + token
    h.update(headers or {})
    req = "%s %s HTTP/1.1\r\n" % (method, path) + "".join("%s: %s\r\n" % kv for kv in h.items()) + "\r\n"
    s.sendall(req.encode() + body)
    data = b""
    s.settimeout(timeout)
    try:
        while b"\r\n\r\n" not in data:
            d = s.recv(65536)
            if not d: break
            data += d
        head, _, rest = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        st = int(lines[0].split(" ")[1]) if lines and lines[0].startswith("HTTP/1.1 ") else 0
        hd = {}
        for l in lines[1:]:
            k, _, v = l.partition(":")
            hd[k.strip().lower()] = v.strip()
        n = int(hd.get("content-length", "0"))
        while len(rest) < n:
            d = s.recv(65536)
            if not d: break
            rest += d
    except (socket.timeout, OSError):
        return 0, {}, b""
    if sock is None: s.close()
    return st, hd, rest[:n]


class Sse:
    """Gemini CLI's event stream: GET /mcp; events() gives the messages that came"""

    def __init__(self, port, token):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.s.sendall(("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAccept: text/event-stream\r\n"
                        "Authorization: Bearer %s\r\n\r\n" % (port, token)).encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            d = self.s.recv(65536)
            if not d: break
            self.buf += d
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        self.status = int(head.split(b" ")[1]) if head.startswith(b"HTTP/1.1 ") else 0
        self.head = head

    def next(self, method=None, timeout=8, pred=lambda p: True):
        """the next message (of that method), None when none came in time"""
        end = time.time() + timeout
        while time.time() < end:
            while b"\n\n" in self.buf:
                ev, _, self.buf = self.buf.partition(b"\n\n")
                data = [l[5:].strip() for l in ev.split(b"\n") if l.startswith(b"data:")]
                if not data: continue
                m = json.loads(b"".join(data))
                if method is None or (m.get("method") == method and pred(m.get("params", {}))): return m
            self.s.settimeout(max(0.1, end - time.time()))
            try:
                d = self.s.recv(65536)
            except (socket.timeout, OSError):
                return None
            if not d: return None
            self.buf += d
        return None

    def close(self):
        try: self.s.close()
        except OSError: pass


def rpc(port, token, method, params=None, id=1, sock=None):
    """a JSON-RPC request over HTTP (Gemini CLI's way): (status, answer or None)"""
    body = json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}).encode()
    st, _, b = http(port, "POST", body=body, token=token, sock=sock)
    return st, (json.loads(b) if b else None)
