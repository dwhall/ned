#!/usr/bin/env python3
# Ollama's API for ned's tests: /api/tags, /api/pull (streamed progress), and an OpenAI-style chat that says "ready"
import sys, json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
models = []
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def send_json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith('/api/tags'): return self.send_json({"models": models})
        self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        if self.path.startswith('/api/pull'):
            self.send_response(200); self.send_header('Content-Type', 'application/x-ndjson')
            self.send_header('Connection', 'close'); self.end_headers()
            for line in [{"status": "pulling manifest"}, {"status": "downloading", "completed": 40, "total": 100},
                         {"status": "downloading", "completed": 100, "total": 100}, {"status": "success"}]:
                self.wfile.write((json.dumps(line) + '\n').encode()); self.wfile.flush(); time.sleep(0.3)
            models.append({"name": body.get("model", "x"), "size": 1000000000})
            self.close_connection = True
            return
        if self.path.startswith('/api/generate'):
            # (fill in the middle: a code model given the text after the cursor too; another model refuses it)
            if body.get('model') != 'coder' or 'suffix' not in body:
                b2 = json.dumps({"error": "model does not support insert"}).encode()
                self.send_response(400); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(b2))); self.end_headers(); self.wfile.write(b2); return
            with open(sys.argv[2] if len(sys.argv) > 2 else '/dev/null', 'a') as f: f.write(json.dumps(body) + '\n')
            return self.send_json({"response": ' "fim-651"', "done": True})
        if self.path.endswith('/chat/completions'):
            if body.get('stream'):
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Connection', 'close'); self.end_headers()
                for ev in [{'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'ready'}}]},
                           {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}]:
                    self.wfile.write(('data: ' + json.dumps(ev) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
                self.close_connection = True
                return
            return self.send_json({'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'ready'}, 'finish_reason': 'stop'}]})
        self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
