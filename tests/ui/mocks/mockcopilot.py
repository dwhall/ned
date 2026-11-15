#!/usr/bin/env python3
"""A stand-in for GitHub Copilot's language server (6.52): LSP over stdio — initialize, the files it is sent, signIn
(a code and the command that finishes it, which opens GitHub's page through window/showDocument), its status,
textDocument/inlineCompletion (the line typed so far, finished with `_from_copilot()`), textDocument/copilotInlineEdit
(the first line of the file changed) and the accept command. Every method it gets is logged (MOCK_COPILOT_LOG)."""
import json, os, sys

LOG = os.environ.get('MOCK_COPILOT_LOG', '/dev/null')
docs = {}
nid = [100]


def log(m):
    with open(LOG, 'a') as f: f.write(m + '\n')


def send(m):
    b = json.dumps(m).encode()
    sys.stdout.buffer.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    sys.stdout.buffer.flush()


def read():
    h = {}
    while True:
        l = sys.stdin.buffer.readline()
        if not l: return None
        l = l.strip()
        if not l: break
        k, v = l.split(b':', 1)
        h[k.strip().lower()] = v.strip()
    return json.loads(sys.stdin.buffer.read(int(h[b'content-length'])))


def status(kind, msg=''):
    send({'jsonrpc': '2.0', 'method': 'didChangeStatus', 'params': {'busy': False, 'kind': kind, 'message': msg}})


while True:
    m = read()
    if m is None: break
    meth = m.get('method', '')
    p = m.get('params') or {}
    if meth: log(meth + ' ' + json.dumps(p)[:300])
    if 'id' in m and not meth: continue          # (an answer to its own request)
    mid = m.get('id')
    if meth == 'initialize':
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'capabilities': {'textDocumentSync': 1,
              'inlineCompletionProvider': {}}, 'serverInfo': {'name': 'mock copilot'}}})
    elif meth == 'initialized':
        status('Error', 'You are not signed into GitHub.')
    elif meth in ('textDocument/didOpen', 'textDocument/didChange'):
        td = p['textDocument']
        docs[td['uri']] = (p['contentChanges'][-1]['text'] if meth.endswith('didChange') else td['text'])
    elif meth == 'signIn':
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'userCode': 'ABCD-1234', 'command': {'command':
              'github.copilot.finishDeviceFlow', 'title': 'Sign in', 'arguments': []}}})
    elif meth == 'workspace/executeCommand':
        c = p.get('command')
        if c == 'github.copilot.finishDeviceFlow':
            send({'jsonrpc': '2.0', 'id': nid[0], 'method': 'window/showDocument',
                  'params': {'uri': 'https://github.com/login/device', 'external': True}})
            nid[0] += 1
            status('Normal')
            send({'jsonrpc': '2.0', 'id': mid, 'result': {'status': 'OK', 'user': 'mockuser'}})
        else:
            send({'jsonrpc': '2.0', 'id': mid, 'result': None})
    elif meth == 'textDocument/inlineCompletion':
        lines = docs.get(p['textDocument']['uri'], '').split('\n')
        ln, ch = p['position']['line'], p['position']['character']
        before = lines[ln][:ch] if ln < len(lines) else ''
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'items': [{'insertText': before + '_from_copilot()',
              'range': {'start': {'line': ln, 'character': 0}, 'end': {'line': ln, 'character': ch}},
              'command': {'command': 'github.copilot.didAcceptCompletionItem', 'title': '', 'arguments': ['item-1']}}]}})
    elif meth == 'textDocument/copilotInlineEdit':
        td = p['textDocument']
        first = docs.get(td['uri'], '').split('\n')[0]
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'edits': [{'text': '# edited by copilot',
              'textDocument': td, 'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': len(first)}},
              'command': {'title': '', 'command': 'github.copilot.didAcceptCompletionItem', 'arguments': ['edit-1']}}]}})
    elif meth == 'shutdown':
        send({'jsonrpc': '2.0', 'id': mid, 'result': None})
    elif meth == 'exit':
        break
    elif mid is not None:
        send({'jsonrpc': '2.0', 'id': mid, 'result': None})
