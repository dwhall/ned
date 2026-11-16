#!/usr/bin/env python3
"""Sits between ned and a real language server and writes down what passes: `lsptee.py LOG CMD ARGS…` starts CMD
and copies its standard input and output both ways, one line in LOG per message — "> " what ned sent, "< " what the
server sent, with the method (or the id of an answer) and the message itself, cut at 600 characters. The tests of
real servers (GitHub Copilot's) read the log: what was asked, how often, and what ned answered."""
import json, subprocess, sys, threading

log_path, cmd = sys.argv[1], sys.argv[2:]
log = open(log_path, "a", buffering=1)
lock = threading.Lock()
child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def frames(src):
    """the messages of an LSP stream, each as its bytes (None at its end)"""
    while True:
        n = -1
        while True:
            line = src.readline()
            if not line: return
            line = line.strip()
            if not line: break
            if line.lower().startswith(b"content-length:"): n = int(line.split(b":")[1])
        if n < 0: return
        body = src.read(n)
        if len(body) < n: return
        yield body


def note(way, body):
    """one line in the log for one message"""
    try:
        m = json.loads(body)
        what = m.get("method") or "answer %s" % m.get("id")
    except ValueError:
        what = "(not JSON)"
    with lock:
        log.write("%s %s %s\n" % (way, what, body[:600].decode("utf-8", "replace")))


def pump(src, dst, way):
    """copies the messages from src to dst, each noted"""
    for body in frames(src):
        note(way, body)
        try:
            dst.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            dst.flush()
        except OSError:
            return


threading.Thread(target=pump, args=(child.stdout, sys.stdout.buffer, "<"), daemon=True).start()
pump(sys.stdin.buffer, child.stdin, ">")
try:
    child.stdin.close()
except OSError:
    pass
try:
    child.wait(5)
except subprocess.TimeoutExpired:
    child.kill()
