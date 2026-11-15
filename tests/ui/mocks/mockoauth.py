#!/usr/bin/env python3
"""A stand-in for an MCP server on the web that asks you to sign in (6.52), as MCP's authorization asks: /mcp answers
401 with where its metadata is until a token comes; the metadata names this same server as the sign-in service, which
registers clients, sends the browser back with a code (/authorize), and trades the code — PKCE checked — or a refresh
token for a token (/token). POST /expire makes the tokens given so far run out.

  mockoauth.py PORT"""
import base64, hashlib, json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
BASE = 'http://127.0.0.1:%d' % PORT
state = {'codes': {}, 'tokens': set(), 'refresh': set(), 'n': 0, 'seen': []}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def out(self, code, body, ctype='application/json', extra=None):
        b = (json.dumps(body) if not isinstance(body, str) else body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def body(self):
        return self.rfile.read(int(self.headers.get('Content-Length', 0) or 0)).decode()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        if u.path == '/.well-known/oauth-protected-resource/mcp' or u.path == '/.well-known/oauth-protected-resource':
            self.out(200, {'resource': BASE + '/mcp', 'authorization_servers': [BASE], 'scopes_supported': ['mcp']})
        elif u.path == '/.well-known/oauth-authorization-server':
            self.out(200, {'issuer': BASE, 'authorization_endpoint': BASE + '/authorize', 'token_endpoint': BASE + '/token',
                           'registration_endpoint': BASE + '/register', 'code_challenge_methods_supported': ['S256']})
        elif u.path == '/authorize':
            ok = q.get('client_id') == 'ned-client' and q.get('code_challenge_method') == 'S256' and \
                 q.get('resource') == BASE + '/mcp' and q.get('redirect_uri', '').startswith('http://127.0.0.1:')
            if not ok:
                self.out(400, {'error': 'invalid_request', 'got': q})
                return
            state['n'] += 1
            code = 'code%d' % state['n']
            state['codes'][code] = (q['code_challenge'], q['redirect_uri'])
            self.send_response(302)
            self.send_header('Location', q['redirect_uri'] + '?' + urllib.parse.urlencode({'code': code, 'state': q['state']}))
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            self.out(404, {'error': 'not here'})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        b = self.body()
        if u.path == '/register':
            r = json.loads(b)
            if r.get('token_endpoint_auth_method') != 'none' or not r.get('redirect_uris'):
                self.out(400, {'error': 'invalid_client_metadata'})
                return
            self.out(201, {'client_id': 'ned-client', 'redirect_uris': r['redirect_uris']})
        elif u.path == '/token':
            f = dict(urllib.parse.parse_qsl(b))
            state['n'] += 1
            tok, ref = 'tok%d' % state['n'], 'ref%d' % state['n']
            if f.get('grant_type') == 'authorization_code':
                ch, red = state['codes'].pop(f.get('code', ''), (None, None))
                want = base64.urlsafe_b64encode(hashlib.sha256(f.get('code_verifier', '').encode()).digest()).decode().rstrip('=')
                if ch is None or ch != want or red != f.get('redirect_uri') or f.get('resource') != BASE + '/mcp':
                    self.out(400, {'error': 'invalid_grant'})
                    return
            elif f.get('grant_type') == 'refresh_token':
                if f.get('refresh_token') not in state['refresh']:
                    self.out(400, {'error': 'invalid_grant'})
                    return
            else:
                self.out(400, {'error': 'unsupported_grant_type'})
                return
            state['tokens'].add(tok)
            state['refresh'].add(ref)
            self.out(200, {'access_token': tok, 'token_type': 'Bearer', 'refresh_token': ref, 'expires_in': 3600})
        elif u.path == '/expire':
            state['tokens'].clear()
            self.out(200, {'ok': True})
        elif u.path == '/mcp':
            auth = self.headers.get('Authorization', '')
            tok = auth[7:] if auth.startswith('Bearer ') else ''
            if tok not in state['tokens']:
                self.out(401, {'error': 'unauthorized'}, extra={'WWW-Authenticate':
                         'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/mcp", scope="mcp"' % BASE})
                return
            m = json.loads(b)
            if 'id' not in m:
                self.out(202, '', 'text/plain')
                return
            if m['method'] == 'initialize':
                res = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'oauth mock'}}
            elif m['method'] == 'tools/list':
                res = {'tools': [{'name': 'whoami', 'description': 'who the token is', 'inputSchema': {'type': 'object'}}]}
            elif m['method'] == 'tools/call':
                res = {'content': [{'type': 'text', 'text': 'signed in with ' + tok}]}
            else:
                res = {}
            self.out(200, {'jsonrpc': '2.0', 'id': m['id'], 'result': res})
        else:
            self.out(404, {'error': 'not here'})


HTTPServer(('127.0.0.1', PORT), H).serve_forever()
