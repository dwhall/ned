# Claude Code and Gemini CLI use ned as their IDE (6.53, ai.ideLink): one server on 127.0.0.1 that speaks both
# tools' IDE protocols — MCP over a WebSocket for Claude Code (its lock file in ~/.claude/ide), MCP over HTTP with a
# stream of events for Gemini CLI (its file in $TMPDIR/gemini/ide). They see the file and the selection you are on,
# open files here, read the problems, and show the changes they propose as diffs in ned to accept (a) or reject (d).
# Every request carries a random token only you can read; requests from web pages (an Origin header, another Host)
# are turned away.

const
  IdeMaxConns = 16                      # connections at once (more are closed at once)
  IdeMaxHead = 64 * 1024                # an HTTP request's headers
  IdeMaxBody = 16 * 1024 * 1024         # an HTTP body, a WebSocket message
  IdeIdleMs = 15_000                    # a request not finished in this time: the connection goes
  IdeKeepAliveMs = 20_000               # a comment on Gemini's event stream this often (its client gives up on silence)

type
  IdeKind = enum ikHttp, ikWs, ikSse
  IdeConn = ref object
    fd: cint
    kind: IdeKind
    inp, outp: string                   # read and not handled yet; to write (what the socket did not take yet)
    msg: string                         # a WebSocket message whose frames are still coming
    closing: bool                       # closed once what is to write is written
    lastAt: MonoTime                    # the last bytes from it (or the last comment to it, for a stream)
    gone: bool
  IdeDiff = object
    conn: IdeConn                       # who asked (its answer goes there)
    reqId: JsonNode                     # Claude Code: the openDiff request waiting for the answer
    path, text, tab: string             # the file, its proposed text, Claude Code's name for the tab
    gemini: bool
    bufId: int                          # the diff's tab
    who: string                         # who proposes it (said in the tab and the messages)
    cb: proc(accept: bool, text: string) {.closure.}   # ned's own proposals (an agent's worktree, its writes
                                                       # reviewed): what deciding does, with the text as accepted

var
  ideFd: cint = -1
  idePort = 0
  ideToken = ""
  ideConns: seq[IdeConn]
  ideDiffs: seq[IdeDiff]
  ideLock, ideGem = ""                  # the files that tell the tools where ned is (removed when ned quits)
  ideRootsSig = ""                      # the folders written in them
  ideSelNow, ideSelSent = ""            # the selection as it is, as last sent to Claude Code
  ideSelAt: MonoTime                    # when it last moved
  ideLastSel: JsonNode                  # Claude Code's getLatestSelection
  ideCtxNow, ideCtxSent = ""            # Gemini CLI's context (open files, cursor), as it is and as last sent
  ideCtxAt: MonoTime
  ideGemQueue: seq[string]              # events for Gemini CLI while no stream of its is open
  ideTried = false

proc ideClaudeDir(): string =
  ## Claude Code's folder (CLAUDE_CONFIG_DIR, or ~/.claude)
  let d = getEnv("CLAUDE_CONFIG_DIR")
  if d.len > 0: d else: getHomeDir() / ".claude"

proc ideGemDir(): string =
  ## where Gemini CLI looks for IDEs (its os.tmpdir(): $TMPDIR, else /tmp)
  let t = getEnv("TMPDIR")
  (if t.len > 0: t else: "/tmp") / "gemini" / "ide"

proc ideRoots(): seq[string] =
  ## the project's folders, the first the main one
  if rootDir.len > 0: result.add rootDir
  for r in wsRoots:
    if r notin result: result.add r

proc idePrivFile(path, text: string): bool =
  ## a file only you can read, in a folder made only yours when ned makes it
  try:
    if not dirExists(parentDir(path)):
      createDir(parentDir(path))
      setFilePermissions(parentDir(path), {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(path, "")
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    writeFile(path, text)
    true
  except CatchableError: false

proc ideWriteFiles() =
  ## the lock file for Claude Code and the discovery file for Gemini CLI, with the project's folders as they are now
  let roots = ideRoots()
  ideRootsSig = roots.join("\n")
  let pid = getCurrentProcessId()
  if dirExists(ideClaudeDir()) or findExe("claude").len > 0:
    ideLock = ideClaudeDir() / "ide" / ($idePort & ".lock")
    if not idePrivFile(ideLock, $(%*{"pid": pid, "workspaceFolders": roots, "ideName": "ned", "transport": "ws",
                                     "runningInWindows": defined(windows), "authToken": ideToken})):
      ideLock = ""
  ideGem = ideGemDir() / ("gemini-ide-server-" & $pid & "-" & $idePort & ".json")
  if not idePrivFile(ideGem, $(%*{"port": idePort, "workspacePath": roots.join($PathSep), "authToken": ideToken,
                                  "ideInfo": {"name": "ned", "displayName": "ned"}})):
    ideGem = ""

proc ideSweep() =
  ## files left by neds that are gone (a crash): theirs only, never another IDE's
  for (dir, isLock) in [(ideClaudeDir() / "ide", true), (ideGemDir(), false)]:
    try:
      for kind, p in walkDir(dir):
        let n = extractFilename(p)
        if not (if isLock: n.endsWith(".lock") else: n.startsWith("gemini-ide-server-")): continue
        let j = try: parseJson(readFile(p)) except CatchableError: nil
        if j == nil or j.kind != JObject: continue
        let ours = if isLock: j{"ideName"}.getStr == "ned" else: j{"ideInfo"}{"name"}.getStr == "ned"
        var pid = if isLock: j{"pid"}.getInt(0) else: 0
        if not isLock:
          let parts = n.split('-')
          if parts.len >= 5: pid = (try: parseInt(parts[3]) except ValueError: 0)
        when not defined(windows):
          if ours and pid > 0 and pid != getCurrentProcessId() and kill(Pid(pid), 0) != 0 and errno == ESRCH:
            removeFile(p)
    except CatchableError: discard

proc ideBind(port: int): cint =
  ## a listening socket on 127.0.0.1:port (-1 when the port is taken)
  let fd = posix.socket(AF_INET, SOCK_STREAM, 0)
  if fd.cint < 0: return -1
  when not defined(windows):
    var one: cint = 1                                # (bound again at once after a restart: no wait for TIME_WAIT)
    discard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr one, SockLen(sizeof(one)))
  var a: Sockaddr_in
  a.sin_family = TSa_Family(AF_INET)
  a.sin_port = htons(uint16(port))
  a.sin_addr.s_addr = inet_addr("127.0.0.1")
  if posix.bindSocket(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0 and posix.listen(fd, 8) == 0:
    return fd.cint
  discard posix.close(fd.cint)
  -1

proc ideStart() =
  ## the server, once (ai.ideLink): the port and token of the last time when the port is free — a terminal that
  ## outlived a restart keeps working — else a new port between 41000 and 41999 and a new token; then the files
  ## that point to it
  if ideFd >= 0 or ideTried or wkWorkerMode or not sBool("ai.ideLink"): return
  ideTried = true
  let keep = privDir() / "ide-link"                  # ("PORT TOKEN", only yours)
  try:
    let w = readFile(keep).splitWhitespace
    if w.len == 2 and w[1].len == 32 and w[1].allCharsInSet(HexDigits):
      let port = parseInt(w[0])
      if port in 41000 .. 41999:
        let fd = ideBind(port)
        if fd >= 0: (ideFd, idePort, ideToken) = (fd, port, w[1])
  except CatchableError: discard
  if ideFd < 0:
    ideToken = ctlNewKey()
    if ideToken.len == 0: return
    let start = int(getMonoTime().ticks mod 1000)
    for k in 0 ..< 60:
      let port = 41000 + (start + k * 17) mod 1000
      let fd = ideBind(port)
      if fd >= 0:
        (ideFd, idePort) = (fd, port)
        break
    if ideFd < 0: return
    discard idePrivFile(keep, $idePort & " " & ideToken)
  discard fcntl(ideFd, F_SETFD, FD_CLOEXEC)
  setNonBlock(ideFd)
  ideSweep()
  ideWriteFiles()

proc ideEnv(): seq[(string, string)] =
  ## what a terminal's shell gets, so that claude and gemini started there find this ned at once
  ideStart()
  if ideFd < 0: return
  result = @[("CLAUDE_CODE_SSE_PORT", $idePort), ("ENABLE_IDE_INTEGRATION", "true"),
             ("GEMINI_CLI_IDE_SERVER_PORT", $idePort), ("GEMINI_CLI_IDE_PID", $getCurrentProcessId()),
             ("GEMINI_CLI_IDE_WORKSPACE_PATH", ideRoots().join($PathSep))]

proc ideStop() =
  ## ned quits: the connections and the server closed, the files removed
  for c in ideConns:
    if c.fd >= 0: discard posix.close(c.fd)
  ideConns.setLen(0)
  if ideFd >= 0: discard posix.close(ideFd)
  ideFd = -1
  for p in [ideLock, ideGem]:
    if p.len > 0:
      try: removeFile(p)
      except CatchableError: discard

# ── the bytes: HTTP requests and answers, WebSocket frames, events on a stream ──

proc ideWrite(c: IdeConn, s: string) =
  ## queues bytes for the connection and writes what the socket takes now
  if c.gone: return
  c.outp.add s
  while c.outp.len > 0:
    let n = posix.write(c.fd, addr c.outp[0], c.outp.len)
    if n > 0: c.outp = c.outp[n .. ^1]
    else:
      if n < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]: c.gone = true
      break
  if c.outp.len > 4 * IdeMaxBody: c.gone = true            # (it does not read what it is sent)

proc ideHttp(c: IdeConn, status: string, body = "", ctype = "application/json", extra = "") =
  ## an HTTP answer (the connection is kept for the next request)
  c.ideWrite("HTTP/1.1 " & status & "\r\nContent-Type: " & ctype & "\r\nContent-Length: " & $body.len & "\r\n" &
             "Cache-Control: no-store\r\n" & extra & "\r\n" & body)

proc ideFrame(op: int, payload: string): string =
  ## a WebSocket frame from the server (never masked)
  result.add char(0x80 or op)
  if payload.len < 126: result.add char(payload.len)
  elif payload.len < 65536:
    result.add char(126)
    result.add char((payload.len shr 8) and 0xff)
    result.add char(payload.len and 0xff)
  else:
    result.add char(127)
    for i in countdown(7, 0): result.add char((payload.len shr (i * 8)) and 0xff)
  result.add payload

proc ideWsClose(c: IdeConn, code: int) =
  ## the WebSocket closed, with its reason's number
  c.ideWrite(ideFrame(8, char((code shr 8) and 0xff) & char(code and 0xff)))
  c.closing = true

proc ideSend(c: IdeConn, m: JsonNode) =
  ## a message to a client: a frame on a WebSocket, an event on a stream
  case c.kind
  of ikWs: c.ideWrite(ideFrame(1, $m))
  of ikSse: c.ideWrite("event: message\ndata: " & $m & "\n\n")
  of ikHttp: discard

proc ideNotify(claude: bool, meth: string, params: JsonNode) =
  ## an event for Claude Code (its WebSockets) or Gemini CLI (its streams: kept for later when none is open)
  let m = %*{"jsonrpc": "2.0", "method": meth, "params": params}
  var sent = false
  for c in ideConns:
    if c.gone or c.closing: continue
    if (claude and c.kind == ikWs) or (not claude and c.kind == ikSse):
      c.ideSend(m)
      sent = true
  if not sent and not claude and meth != "ide/contextUpdate":
    ideGemQueue.add $m
    if ideGemQueue.len > 32: ideGemQueue.delete(0)

proc ideClaudeOn(): bool =
  ## a Claude Code is connected
  for c in ideConns:
    if c.kind == ikWs and not c.gone: return true

# ── what the tools ask: files, the selection, problems, diffs ──

# a tool's result: one text
proc ideText(s: string): JsonNode = %*{"content": [{"type": "text", "text": s}]}
# a tool's result that is an error, said in one text
proc ideErr(s: string): JsonNode = %*{"content": [{"type": "text", "text": s}], "isError": true}

proc ideBufOf(path: string): Buffer =
  ## the open tab of a file (nil when it is not open)
  if path.len == 0: return nil
  let p = absProjectPath(path)
  for b in bufs:
    if b.path.len > 0 and (b.path == p or b.path == path): return b

# a place as the tools read one: a line and a character from 0, characters in UTF-16 units as in VS Code
proc idePosJ(b: Buffer, p: Pos): JsonNode =
  %*{"line": p.line, "character": (if p.line < b.lines.len: toU16(b.lines[p.line], p.col) else: p.col)}

proc ideSelection(b: Buffer): JsonNode =
  ## the tab's selection as Claude Code reads it (lines and characters from 0)
  let (a, e) = b.primary.range
  %*{"success": true, "text": (if a == e: "" else: b.getText(a, e)), "filePath": b.path, "fileUrl": uriFromPath(b.path),
     "selection": {"start": idePosJ(b, a), "end": idePosJ(b, e), "isEmpty": a == e}}

proc ideOffPos(b: Buffer, off: int): Pos =
  ## the place of a byte in the whole text
  var left = off
  for i, l in b.lines:
    if left <= l.len: return Pos(line: i, col: left)
    left -= l.len + 1
  Pos(line: b.lines.high, col: b.lines[^1].len)

proc ideOpenFile(a: JsonNode): JsonNode =
  ## openFile: the file opened (in front unless makeFrontmost is false), the text from startText to endText selected
  let path = absProjectPath(a{"filePath"}.getStr)
  if a{"filePath"}.getStr.len == 0 or not fileExists(path): return ideErr("No such file: " & a{"filePath"}.getStr)
  let was = curBuf
  let b = openFile(path)
  if b == nil: return ideErr("ned could not open " & path)
  let st = a{"startText"}.getStr
  if st.len > 0:
    let all = b.allText
    let i = all.find(st)
    if i >= 0:
      var e = i + st.len
      let en = a{"endText"}.getStr
      if en.len > 0:
        let j = all.find(en, i + st.len)
        if j >= 0: e = j + en.len
      var ep = b.ideOffPos(e)
      if a{"selectToEndOfLine"}.getBool: ep.col = b.lines[ep.line].len
      b.centerOn(b.ideOffPos(i))                 # (it leaves one cursor: the selection after it)
      b.setSingle(ep, b.ideOffPos(i))
  if not a{"makeFrontmost"}.getBool(true) and was >= 0 and was < bufs.len:
    curBuf = was
    return ideText($(%*{"success": true, "filePath": path, "languageId": b.lang.id, "lineCount": b.lines.len}))
  needRender = true
  ideText("Opened file: " & path)

proc ideDiagJ(path: string): JsonNode =
  ## a file's problems as Claude Code reads them
  var ds = newJArray()
  let b = ideBufOf(path)
  proc u16(l, c: int): int =
    ## a column in UTF-16 units, when the file is open (its lines at hand); else as it is
    if b != nil and l >= 0 and l < b.lines.len: toU16(b.lines[l], c) else: c
  for d in diagsFor(path):
    ds.add %*{"message": d.msg, "severity": ["Error", "Error", "Warning", "Information", "Hint"][clamp(d.sev, 0, 4)],
              "source": (if d.src.len > 0: d.src else: "ned"),
              "range": {"start": {"line": d.line, "character": u16(d.line, d.col)},
                        "end": {"line": max(d.line, d.eline), "character": u16(max(d.line, d.eline), max(0, d.ecol))}}}
  %*{"uri": uriFromPath(path), "diagnostics": ds}

proc ideDiagnostics(a: JsonNode): JsonNode =
  ## getDiagnostics: one file's problems (uri) or every file's that has some
  var res = newJArray()
  let u = a{"uri"}.getStr
  if u.len > 0:
    res.add ideDiagJ(if u.startsWith("file://"): pathFromUri(u) else: absProjectPath(u))
  else:
    var paths: seq[string]
    for t in [diagsLsp, diagsBuild, diagsTest, diagsEmit, diagsWeb, diagsExt]:
      for p in dtab(t).keys:
        if p notin paths: paths.add p
    for b in bufs:
      if b.path.len > 0 and b.path notin paths: paths.add b.path
    for p in paths:
      let j = ideDiagJ(p)
      if j["diagnostics"].len > 0: res.add j
  ideText($res)

proc ideDiffShow(who, p, text: string): int =
  ## a proposed change shown as a diff in a tab of its own — the file as it is on the left, the proposal on the right
  ## — with a toast to accept it: the tab's buffer id
  var old = ""
  let ob = ideBufOf(p)
  if ob != nil: old = ob.allText
  elif fileExists(p):
    try: old = readFile(p)
    except CatchableError: discard
  let lang = if ob != nil: ob.lang else: detectLang(p, "")
  proc lines(s: string): seq[string] =
    ## the lines of a text (no last empty one for its final newline)
    result = s.replace("\r\n", "\n").split('\n')
    if result.len > 1 and result[^1].len == 0: result.setLen(result.len - 1)
  openDiffView(who & ": " & extractFilename(p), lines(old), extractFilename(p) & " (now)", nil, lines(text),
               "proposed by " & who & " — a: accept · d: reject · e: edit", lang)
  let bid = buf().id
  toast(who & " proposes a change to " & extractFilename(p) & " — a accepts, d rejects", 3, "Accept", proc() =
    ideDiffDecide(bid, true), ttl = 60_000)
  bid

proc ideDiffOpen(c: IdeConn, reqId: JsonNode, path, text, tab: string, gemini: bool) =
  ## a change Claude Code or Gemini CLI proposes, as a diff to accept or reject
  let p = absProjectPath(path)
  let who = if gemini: "Gemini CLI" else: "Claude Code"
  let bid = ideDiffShow(who, p, text)
  # (Gemini CLI's answer goes out on its event stream, not the request's connection — which may close at once)
  ideDiffs.add IdeDiff(conn: (if gemini: nil else: c), reqId: reqId, path: p, text: text, tab: tab, gemini: gemini,
                       bufId: bid, who: who)

proc proposeDiff(who, path, text: string, cb: proc(accept: bool, text: string) {.closure.}) =
  ## a change ned itself proposes (an agent's worktree, an agent's write under ai.agentReview), as a diff to accept
  ## (a), reject (d) or edit first (e): `cb` does it, with the text as accepted
  let bid = ideDiffShow(who, path, text)
  ideDiffs.add IdeDiff(path: path, text: text, bufId: bid, who: who, cb: cb)

proc ideDiffEnd(i: int, accept: bool, answer = true, closeTab = true) =
  ## the diff at index i decided (or closed: rejected): the tool told, its tab closed (not when it is closing)
  let d = ideDiffs[i]
  ideDiffs.delete(i)
  let bi = if closeTab: bufs.find(bufById(d.bufId)) else: -1
  if bi >= 0: closeBufferAt(bi)
  needRender = true
  if d.cb != nil:
    if answer: d.cb(accept, d.text)
    return
  if answer and d.gemini:
    if accept: ideNotify(false, "ide/diffAccepted", %*{"filePath": d.path, "content": d.text})
    else: ideNotify(false, "ide/diffRejected", %*{"filePath": d.path})
  elif answer and d.conn != nil and not d.conn.gone:
    if d.reqId != nil:
      let res = if accept: %*{"content": [{"type": "text", "text": "FILE_SAVED"}, {"type": "text", "text": d.text}]}
                else: %*{"content": [{"type": "text", "text": "DIFF_REJECTED"}, {"type": "text", "text": d.tab}]}
      d.conn.ideSend(%*{"jsonrpc": "2.0", "id": d.reqId, "result": res})

proc ideDiffDecide(bufId: int, accept: bool) =
  ## a: accept, d: reject — in the diff's tab, or from its toast (the tool writes the file itself)
  for i, d in ideDiffs:
    if d.bufId == bufId:
      let (who, name) = (d.who, extractFilename(d.path))
      info(who & ": change to " & name & (if accept: " accepted" else: " rejected"))
      ideDiffEnd(i, accept)
      return
  info("No proposed change in this tab")

proc ideDiffEdit(bufId: int) =
  ## e in a proposed change's tab: the proposal in a tab of its own to edit — Ctrl+S accepts it as it is then,
  ## closing the tab rejects it
  for d in ideDiffs.mitems:
    if d.bufId != bufId: continue
    let ob = ideBufOf(d.path)
    let b = openScratch("Proposed: " & extractFilename(d.path) & " (" & d.who & ")", d.text,
                        if ob != nil: ob.lang else: detectLang(d.path, ""))
    b.readOnly = false
    d.bufId = b.id
    let old = bufs.find(bufById(bufId))
    if old >= 0: closeBufferAt(old)                   # (the diff's tab: its proposal now in the new one)
    curBuf = max(0, bufs.find(b))
    toast("Edit the proposed change: Ctrl+S accepts it as it is then, closing the tab rejects it", 3, ttl = 20_000)
    needRender = true
    return

proc ideProposalSave(bufId: int): bool =
  ## Ctrl+S in a proposed change's tab — its diff, or its text being edited: accepted (true), as it stands
  for i, d in ideDiffs:
    if d.bufId != bufId: continue
    let b = bufById(bufId)
    if b != nil and not diffViews.hasKey(bufId):
      var t = b.allText
      if d.text.endsWith("\n") and not t.endsWith("\n"): t.add "\n"
      ideDiffs[i].text = t
    ideDiffDecide(bufId, true)
    return true
  false

proc ideDiffKey(bufId: int, k: Key): bool =
  ## the keys of a proposed change's tab: a accepts, d rejects, e opens it to edit (false: not such a tab, or another
  ## key)
  if k.kind != kChar or k.mods != {} or k.ch notin [ord('a'), ord('d'), ord('e')]: return false
  for d in ideDiffs:
    if d.bufId == bufId:
      if k.ch == ord('e'): ideDiffEdit(bufId)
      else: ideDiffDecide(bufId, k.ch == ord('a'))
      return true
  false

proc ideDiffForget(bufId: int) =
  ## a tab closed: a proposed change in it is rejected
  for i, d in ideDiffs:
    if d.bufId == bufId:
      ideDiffEnd(i, false, closeTab = false)
      return

proc ideClaudeTools(): JsonNode =
  ## the tools Claude Code finds in ned
  proc t(name, desc: string, props: JsonNode = newJObject(), req: seq[string] = @[]): JsonNode =
    ## one tool and its arguments
    %*{"name": name, "description": desc, "inputSchema": {"type": "object", "properties": props, "required": req}}
  let fp = %*{"filePath": {"type": "string", "description": "the file's path"}}
  %*[t("openFile", "Opens a file in ned, the text from startText to endText selected",
       %*{"filePath": {"type": "string"}, "preview": {"type": "boolean"}, "startText": {"type": "string"},
          "endText": {"type": "string"}, "selectToEndOfLine": {"type": "boolean"}, "makeFrontmost": {"type": "boolean"}},
       @["filePath"]),
     t("openDiff", "Shows a proposed change as a diff in ned and waits for it to be accepted or rejected",
       %*{"old_file_path": {"type": "string"}, "new_file_path": {"type": "string"},
          "new_file_contents": {"type": "string"}, "tab_name": {"type": "string"}},
       @["old_file_path", "new_file_path", "new_file_contents", "tab_name"]),
     t("getCurrentSelection", "The selection in ned's current tab"),
     t("getLatestSelection", "The last selection made in ned"),
     t("getOpenEditors", "The files open in ned"),
     t("getWorkspaceFolders", "The project's folders"),
     t("getDiagnostics", "The problems ned shows (one file's: uri)", %*{"uri": {"type": "string"}}),
     t("checkDocumentDirty", "Whether an open file has unsaved changes", fp, @["filePath"]),
     t("saveDocument", "Saves an open file", fp, @["filePath"]),
     t("close_tab", "Closes a proposed change's tab", %*{"tab_name": {"type": "string"}}, @["tab_name"]),
     t("closeAllDiffTabs", "Closes every proposed change's tab")]

proc ideGemTools(): JsonNode =
  ## the tools Gemini CLI finds in ned
  %*[{"name": "openDiff", "description": "Shows a proposed change as a diff in ned (accepted or rejected later)",
      "inputSchema": {"type": "object", "properties": {"filePath": {"type": "string"}, "newContent": {"type": "string"}},
                      "required": ["filePath", "newContent"]}},
     {"name": "closeDiff", "description": "Closes a proposed change's tab, giving back its text",
      "inputSchema": {"type": "object", "properties": {"filePath": {"type": "string"}}, "required": ["filePath"]}}]

proc ideCall(c: IdeConn, id: JsonNode, name: string, a: JsonNode): JsonNode =
  ## tools/call: the tool's result (nil: answered later — Claude Code's openDiff)
  let claude = c.kind == ikWs
  case name
  of "openFile": ideOpenFile(a)
  of "openDiff":
    if claude:
      if a{"new_file_contents"} == nil or a{"new_file_contents"}.kind != JString:
        return ideErr("openDiff needs new_file_contents")
      let p = if a{"new_file_path"}.getStr.len > 0: a{"new_file_path"}.getStr else: a{"old_file_path"}.getStr
      c.ideDiffOpen(id, p, a{"new_file_contents"}.getStr, a{"tab_name"}.getStr, false)
      return nil
    if a{"filePath"}.getStr.len == 0 or a{"newContent"} == nil or a{"newContent"}.kind != JString:
      return ideErr("openDiff needs filePath and newContent")
    c.ideDiffOpen(nil, a{"filePath"}.getStr, a{"newContent"}.getStr, "", true)
    %*{"content": []}
  of "closeDiff":
    let p = absProjectPath(a{"filePath"}.getStr)
    for i, d in ideDiffs:
      if d.path == p:
        let t = d.text
        ideDiffEnd(i, false, answer = false)
        return ideText(t)
    ideErr("No proposed change open for " & p)
  of "getCurrentSelection":
    let b = buf()
    if b.path.len == 0: ideText($(%*{"success": false, "message": "No active editor found"}))
    else: ideText($ideSelection(b))
  of "getLatestSelection":
    if ideLastSel == nil: ideText($(%*{"success": false, "message": "No selection available"}))
    else: ideText($ideLastSel)
  of "getOpenEditors":
    var tabs = newJArray()
    for i, b in bufs:
      if b.path.len == 0: continue
      tabs.add %*{"uri": uriFromPath(b.path), "isActive": i == curBuf, "label": extractFilename(b.path),
                  "languageId": b.lang.id, "isDirty": b.dirty}
    ideText($(%*{"tabs": tabs}))
  of "getWorkspaceFolders":
    var fs = newJArray()
    for r in ideRoots(): fs.add %*{"name": extractFilename(r), "uri": uriFromPath(r), "path": r}
    ideText($(%*{"success": true, "folders": fs, "rootPath": rootDir}))
  of "getDiagnostics": ideDiagnostics(a)
  of "checkDocumentDirty", "saveDocument":
    let p = absProjectPath(a{"filePath"}.getStr)
    let b = ideBufOf(p)
    if b == nil: return ideText($(%*{"success": false, "message": "Document not open: " & p}))
    if name == "checkDocumentDirty":
      return ideText($(%*{"success": true, "filePath": p, "isDirty": b.dirty, "isUntitled": false}))
    let ok = saveBuffer(b)
    ideText($(%*{"success": ok, "filePath": p, "saved": ok,
                 "message": (if ok: "Document saved successfully" else: "ned could not save it")}))
  of "close_tab":
    let tn = a{"tab_name"}.getStr
    for i, d in ideDiffs:
      if d.tab == tn and d.conn == c:
        ideDiffEnd(i, false)
        break
    ideText("TAB_CLOSED")
  of "closeAllDiffTabs":
    var n = 0
    var i = 0
    while i < ideDiffs.len:
      if ideDiffs[i].conn == c:
        ideDiffEnd(i, false)
        inc n
      else: inc i
    ideText("CLOSED_" & $n & "_DIFF_TABS")
  else: nil

proc ideRpc(c: IdeConn, m: JsonNode): JsonNode =
  ## one JSON-RPC message from a tool: the answer to send (nil: none now — a notification, an answer for later)
  if m.kind != JObject: return %*{"jsonrpc": "2.0", "id": newJNull(), "error": {"code": -32600, "message": "not a request"}}
  let isReq = m.hasKey("id")                                     # (no id: a notification, never answered)
  let id = if m{"id"} != nil: m{"id"} else: newJNull()
  let meth = m{"method"}.getStr
  if meth.len == 0: return nil                                   # (an answer to ned: it asks nothing)
  let p = if m{"params"} != nil and m{"params"}.kind == JObject: m{"params"} else: newJObject()
  # (the answer to this request, with its result)
  proc ok(r: JsonNode): JsonNode = %*{"jsonrpc": "2.0", "id": id, "result": r}
  var res: JsonNode
  case meth
  of "initialize":
    let pv = p{"protocolVersion"}.getStr
    if c.kind == ikWs: toast("Claude Code is connected to ned", 3)
    else: toast("Gemini CLI is connected to ned", 3)
    res = ok(%*{"protocolVersion": (if pv in ["2024-11-05", "2025-03-26", "2025-06-18"]: pv else: "2025-06-18"),
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "ned", "version": Version}})
  of "ping": res = ok(newJObject())
  of "tools/list": res = ok(%*{"tools": (if c.kind == ikWs: ideClaudeTools() else: ideGemTools())})
  of "tools/call":
    let name = p{"name"}.getStr
    let a = if p{"arguments"} != nil and p{"arguments"}.kind == JObject: p{"arguments"} else: newJObject()
    let r = try: c.ideCall(id, name, a) except CatchableError as e: ideErr("ned: " & e.msg)
    if r == nil and name in ["openDiff"] and c.kind == ikWs: return nil
    if r == nil:
      if not isReq: return nil
      return %*{"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "No tool " & name & " in ned"}}
    res = ok(r)
  of "resources/list": res = ok(%*{"resources": []})
  of "prompts/list": res = ok(%*{"prompts": []})
  else:
    if not isReq: return nil                                     # (notifications/initialized, cancelled …)
    return %*{"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": meth & " is not in ned"}}
  if isReq: res else: nil

proc ideRpcText(c: IdeConn, body: string): JsonNode =
  ## a message (or a batch of them) as text: the answer(s), nil when there is none
  let m = try: parseJson(body) except CatchableError: nil
  if m == nil: return %*{"jsonrpc": "2.0", "id": newJNull(), "error": {"code": -32700, "message": "not JSON"}}
  if m.kind == JArray:
    var outs = newJArray()
    for x in m:
      let r = c.ideRpc(x)
      if r != nil: outs.add r
    return (if outs.len > 0: outs else: nil)
  c.ideRpc(m)

# ── the connections ──

proc ideHeader(head, name: string): string =
  ## a header's value in a request's headers ("" when it has none)
  for l in head.split("\r\n")[1 .. ^1]:
    let k = l.find(':')
    if k > 0 and l[0 ..< k].strip.toLowerAscii == name: return l[k + 1 .. ^1].strip

proc ideHttpOne(c: IdeConn): bool =
  ## one whole request from the input, answered (false: not whole yet, or the connection is closing)
  let e = c.inp.find("\r\n\r\n")
  if e < 0 or e > IdeMaxHead:
    if c.inp.len > IdeMaxHead:
      c.ideHttp("431 Request Header Fields Too Large", "")
      c.closing = true
    return false
  let head = c.inp[0 ..< e]
  let first = head.split("\r\n")[0].splitWhitespace
  if first.len < 3 or not first[2].startsWith("HTTP/1."):
    c.ideHttp("400 Bad Request", "")
    c.closing = true
    return false
  let (meth, target) = (first[0], first[1])
  var n = 0
  let cl = ideHeader(head, "content-length")
  if cl.len > 0:
    n = try: parseInt(cl) except ValueError: -1
    if n < 0 or n > IdeMaxBody:
      c.ideHttp("413 Content Too Large", "")
      c.closing = true
      return false
  if ideHeader(head, "transfer-encoding").len > 0:              # shortcut: no chunked bodies (neither tool sends them)
    c.ideHttp("411 Length Required", "")
    c.closing = true
    return false
  if c.inp.len < e + 4 + n: return false
  let body = c.inp[e + 4 ..< e + 4 + n]
  c.inp = c.inp[e + 4 + n .. ^1]
  # (a web page cannot reach it: it would send an Origin, or another Host when a name is pointed at 127.0.0.1)
  let host = ideHeader(head, "host")
  if ideHeader(head, "origin").len > 0 or host notin ["127.0.0.1:" & $idePort, "localhost:" & $idePort]:
    c.ideHttp("403 Forbidden", "")
    c.closing = true
    return false
  if ideHeader(head, "upgrade").toLowerAscii == "websocket":
    let key = ideHeader(head, "sec-websocket-key")
    if meth != "GET" or key.len == 0 or not ctlSameKey(ideHeader(head, "x-claude-code-ide-authorization"), ideToken):
      c.ideHttp("401 Unauthorized", "")
      c.closing = true
      return false
    var proto = ideHeader(head, "sec-websocket-protocol").split(',')[0].strip
    c.ideWrite("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " &
               wsAccept(key) & "\r\n" & (if proto.len > 0: "Sec-WebSocket-Protocol: " & proto & "\r\n" else: "") & "\r\n")
    c.kind = ikWs
    return true
  if target.split('?')[0] != "/mcp":
    c.ideHttp("404 Not Found", "")
    return true
  let auth = ideHeader(head, "authorization")
  if not (auth.startsWith("Bearer ") and ctlSameKey(auth[7 .. ^1].strip, ideToken)):
    c.ideHttp("401 Unauthorized", "", extra = "WWW-Authenticate: Bearer\r\n")
    c.closing = true
    return false
  let close = ideHeader(head, "connection").toLowerAscii == "close"
  case meth
  of "POST":
    let r = c.ideRpcText(body)
    if r == nil: c.ideHttp("202 Accepted", "")
    else:
      let sid = if body.contains("\"initialize\""): "Mcp-Session-Id: " & ctlNewKey() & "\r\n" else: ""
      c.ideHttp("200 OK", $r, extra = sid)
  of "GET":
    if "text/event-stream" notin ideHeader(head, "accept"):
      c.ideHttp("406 Not Acceptable", "")
    else:
      c.ideWrite("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n")
      c.kind = ikSse
      for m in ideGemQueue: c.ideWrite("event: message\ndata: " & m & "\n\n")
      ideGemQueue.setLen(0)
      ideCtxSent = ""                                              # (what it is looking at, sent again at once)
      return false
  of "DELETE": c.ideHttp("200 OK", "")
  else: c.ideHttp("405 Method Not Allowed", "", extra = "Allow: GET, POST, DELETE\r\n")
  if close: c.closing = true
  not close

proc ideWsOne(c: IdeConn): bool =
  ## one whole frame from the input, handled (false: not whole yet, or the connection is closing)
  if c.inp.len < 2: return false
  let b0 = ord(c.inp[0])
  let b1 = ord(c.inp[1])
  let op = b0 and 0x0f
  let fin = (b0 and 0x80) != 0
  if (b1 and 0x80) == 0 or (b0 and 0x70) != 0:                    # (a client's frames are masked; no extensions)
    c.ideWsClose(1002)
    return false
  var n = b1 and 0x7f
  var at = 2
  if n == 126:
    if c.inp.len < 4: return false
    n = (ord(c.inp[2]) shl 8) or ord(c.inp[3])
    at = 4
  elif n == 127:
    if c.inp.len < 10: return false
    var big: uint64
    for i in 2 ..< 10: big = (big shl 8) or uint64(ord(c.inp[i]))
    if big > uint64(IdeMaxBody):
      c.ideWsClose(1009)
      return false
    n = int(big)
    at = 10
  if n > IdeMaxBody or c.msg.len + n > IdeMaxBody:
    c.ideWsClose(1009)
    return false
  if op >= 8 and (n > 125 or not fin):
    c.ideWsClose(1002)
    return false
  if c.inp.len < at + 4 + n: return false
  let mask = c.inp[at ..< at + 4]
  var payload = c.inp[at + 4 ..< at + 4 + n]
  for i in 0 ..< payload.len: payload[i] = char(ord(payload[i]) xor ord(mask[i mod 4]))
  c.inp = c.inp[at + 4 + n .. ^1]
  case op
  of 0, 1, 2:
    if op != 0 and c.msg.len > 0:                                  # (a new message before the last one ended)
      c.ideWsClose(1002)
      return false
    c.msg.add payload
    if fin:
      let whole = c.msg
      c.msg = ""
      let r = c.ideRpcText(whole)
      if r != nil: c.ideWrite(ideFrame(1, $r))
  of 8:
    c.ideWrite(ideFrame(8, if payload.len >= 2: payload[0 ..< 2] else: ""))
    c.closing = true
    return false
  of 9: c.ideWrite(ideFrame(10, payload))
  of 10: discard
  else:
    c.ideWsClose(1002)
    return false
  true

proc ideFds(fds: var seq[TPollfd]) =
  ## the server and its connections, for the main loop to wait on
  if ideFd >= 0: fds.add TPollfd(fd: ideFd, events: POLLIN)
  for c in ideConns:
    if c.gone: continue
    fds.add TPollfd(fd: c.fd, events: if c.outp.len > 0: POLLIN or POLLOUT else: POLLIN)

proc ideSelSig(): string =
  ## the current tab and its selection, as a string that changes when they do
  let b = buf()
  if b.path.len == 0: return ""
  let (a, e) = b.primary.range
  b.path & "\0" & $a.line & ":" & $a.col & "-" & $e.line & ":" & $e.col & "\0" & $b.changeId

proc ideCtxSig(): string =
  ## Gemini CLI's context: the open files and where the cursor is
  for b in bufs:
    if b.path.len > 0: result.add b.path & "\0"
  result.add ideSelSig()

proc ideContext(): JsonNode =
  ## ide/contextUpdate's parameters: the files open (the current first, at most ten), its cursor and selection
  var files = newJArray()
  let now = epochTime()
  let cb = buf()
  if cb.path.len > 0:
    let (a, e) = cb.primary.range
    var f = %*{"path": cb.path, "timestamp": int(now * 1000), "isActive": true,
               "cursor": {"line": cb.primary.head.line + 1,
                          "character": toU16(cb.lines[cb.primary.head.line], cb.primary.head.col) + 1}}
    if a != e:
      let t = cb.getText(a, e)
      f["selectedText"] = %t[0 ..< utf8Cut(t, min(t.len, 16384))]
    files.add f
  var k = 1
  for b in bufs:
    if files.len >= 10: break
    if b.path.len == 0 or b == cb or not fileExists(b.path): continue
    files.add %*{"path": b.path, "timestamp": int(now * 1000) - k}
    inc k
  %*{"workspaceState": {"openFiles": files, "isTrusted": codeTrusted(rootDir)}}

proc ideDueMs(): int =
  ## how soon the link has something to do (the selection to send after a pause, a stream to keep alive)
  result = 100_000
  if ideConns.len == 0: return
  if ideSelNow != ideSelSent: result = 160
  if ideCtxNow != ideCtxSent: result = min(result, 120)
  for c in ideConns:
    if c.kind == ikSse: result = min(result, IdeKeepAliveMs)
    elif c.kind == ikHttp: result = min(result, IdeIdleMs)

proc ideLinkPump(ready: HashSet[cint]) =
  ## new connections, what they sent, what to tell them (the selection, Gemini's context), and the files kept up to
  ## date with the project's folders
  if ideFd < 0: return
  if ideFd in ready:
    while true:
      let fd = posix.accept(SocketHandle(ideFd), nil, nil)
      if fd.cint < 0: break
      if ideConns.len >= IdeMaxConns:
        discard posix.close(fd.cint)
        continue
      discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
      setNonBlock(fd.cint)
      ideConns.add IdeConn(fd: fd.cint, lastAt: getMonoTime())
  for c in ideConns:
    if c.gone: continue
    if c.outp.len > 0: c.ideWrite("")
    if c.fd in ready:
      var tmp: array[65536, char]
      while true:
        let n = posix.read(c.fd, addr tmp[0], tmp.len)
        if n > 0:
          let old = c.inp.len
          c.inp.setLen(old + n)
          copyMem(addr c.inp[old], addr tmp[0], n)
          c.lastAt = getMonoTime()
          if c.inp.len > IdeMaxBody + IdeMaxHead + 16:
            c.gone = true
            break
        else:
          if n == 0 or errno notin [EAGAIN, EWOULDBLOCK, EINTR]: c.gone = true
          break
      while not c.gone and not c.closing and c.inp.len > 0:
        let more = try: (if c.kind == ikWs: c.ideWsOne() elif c.kind == ikHttp: c.ideHttpOne() else: (c.inp = ""; false))
                   except CatchableError: (c.gone = true; false)
        if not more: break
    if c.closing and c.outp.len == 0: c.gone = true
    if c.kind == ikHttp and msSince(c.lastAt) > IdeIdleMs and c.outp.len == 0: c.gone = true
    if c.kind == ikSse and msSince(c.lastAt) > IdeKeepAliveMs:
      c.ideWrite(": ned\n\n")
      c.lastAt = getMonoTime()
  var i = 0
  while i < ideConns.len:
    let c = ideConns[i]
    if c.gone:
      discard posix.close(c.fd)
      var k = 0
      while k < ideDiffs.len:                                       # (a tool that went: its diffs close)
        if ideDiffs[k].conn == c: ideDiffEnd(k, false, answer = false) else: inc k
      if c.kind == ikWs: info("Claude Code is no longer connected to ned")
      ideConns.delete(i)
    else: inc i
  if ideConns.len == 0: return
  # the selection, once it has stayed put a moment (Claude Code), the context (Gemini CLI)
  let s = ideSelSig()
  if s != ideSelNow:
    ideSelNow = s
    ideSelAt = getMonoTime()
  if ideSelNow != ideSelSent and msSince(ideSelAt) >= 150:
    ideSelSent = ideSelNow
    if s.len > 0:
      ideLastSel = ideSelection(buf())
      if ideClaudeOn(): ideNotify(true, "selection_changed", ideLastSel)
  let cs = ideCtxSig()
  if cs != ideCtxNow:
    ideCtxNow = cs
    ideCtxAt = getMonoTime()
  if ideCtxNow != ideCtxSent and msSince(ideCtxAt) >= 100:
    var gem = false
    for c in ideConns:
      if c.kind == ikSse: gem = true
    if gem:
      ideCtxSent = ideCtxNow
      ideNotify(false, "ide/contextUpdate", ideContext())
  if ideRoots().join("\n") != ideRootsSig: ideWriteFiles()

proc cmdIdeMention() =
  ## AI: send to Claude Code — the file and the lines selected (or the cursor's line), as an @-mention in its prompt
  let b = buf()
  if b.path.len == 0:
    info("Open a file first")
    return
  if not ideClaudeOn():
    info("No Claude Code is connected — run claude in ned's terminal (ai.ideLink)")
    return
  let (a, e) = b.primary.range
  ideNotify(true, "at_mentioned", %*{"filePath": b.path, "lineStart": a.line, "lineEnd": e.line})
  info("Sent to Claude Code: " & extractFilename(b.path) & ":" & $(a.line + 1) &
       (if e.line != a.line: "-" & $(e.line + 1) else: ""))

proc cmdIdeStatus() =
  ## AI: IDE link — where it listens, who is connected, how to use it
  ideStart()
  if ideFd < 0:
    info(if sBool("ai.ideLink"): "The IDE link could not start (no free port on 127.0.0.1)" else: "The IDE link is off (ai.ideLink)")
    return
  var cl, gm = 0
  for c in ideConns:
    if c.kind == ikWs: inc cl
    elif c.kind == ikSse: inc gm
  info("IDE link on 127.0.0.1:" & $idePort & " — Claude Code: " & $cl & ", Gemini CLI: " & $gm &
       " connected. Run claude or gemini in ned's terminal (gemini: /ide enable)")
