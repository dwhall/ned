# ── MCP servers on the web (MCP's Streamable HTTP): an entry of ai.mcpServers with a "url" — GitHub's, Linear's,
#    a company's own — is started as `ned --mcp-http URL`, a bridge that speaks MCP over stdio to ned (as every other
#    server does) and posts each message to the URL with curl, reading the answer as JSON or as server-sent events.
#    The headers (a token: "Authorization": "Bearer ${GITHUB_TOKEN}") come in the environment and go to curl in a
#    private file, never on a command line; a server you signed in to (ned --mcp-login: ai/mcpauth) gets its token,
#    renewed when it has run out ──

proc mcpHttpExpand(v: string): string =
  ## a header's value with ${NAME} replaced by that environment variable
  var i = 0
  while i < v.len:
    if v[i] == '$' and i + 1 < v.len and v[i + 1] == '{':
      let e = v.find('}', i + 2)
      if e > i + 2:
        result.add getEnv(v[i + 2 ..< e])
        i = e + 1
        continue
    result.add v[i]
    inc i

proc mcpHttpMessages(body: string): seq[string] =
  ## the JSON messages in an answer: the body itself when it is JSON (an array: each of it), else the data of each
  ## server-sent event
  let t = body.strip
  if t.startsWith("{"): return @[t]
  if t.startsWith("["):
    try:
      for x in parseJson(t): result.add $x
    except CatchableError: discard
    return
  var data = ""
  for raw in body.splitLines:
    let l = raw.strip(leading = false, chars = {'\r'})
    if l.len == 0:
      if data.strip.len > 0: result.add data.strip
      data = ""
    elif l.startsWith("data:"):
      data.add (if data.len > 0: "\n" else: "") & l[5 .. ^1].strip(trailing = false, chars = {' '})
  if data.strip.len > 0: result.add data.strip

proc mcpHttpMain(args: seq[string]): int =
  ## ned --mcp-http URL: MCP over stdio here, Streamable HTTP there — each line from ned posted to URL (with the
  ## session's id and protocol version once the server gave them), each message of the answer a line back; an HTTP
  ## error is the request's error
  let url = if args.len > 1: args[1] else: ""
  if not (url.startsWith("https://") or url.startsWith("http://")):
    stderr.writeLine "ned --mcp-http URL: an MCP server on the web, over stdin and stdout (ai.mcpServers' \"url\")"
    return 2
  if findExe("curl").len == 0:
    stderr.writeLine "ned --mcp-http: needs curl"
    return 1
  var dir = privDir() / ("mcp-http-" & $getCurrentProcessId())
  try: createDir(dir)
  except CatchableError:
    # (in an agent's sandbox, which may not write there: its own temporary folder)
    dir = getTempDir() / ("ned-mcp-http-" & $getCurrentProcessId())
    try: createDir(dir)
    except CatchableError as e:
      stderr.writeLine "ned --mcp-http: " & e.msg
      return 1
  try: setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  except CatchableError: discard
  let hdr = dir / "headers"
  let got = dir / "got"
  var lines: seq[string]
  try:
    let h = parseJson(getEnv("NED_MCP_HEADERS", "{}"))
    if h.kind == JObject:
      for k, v in h:
        if k.len > 0 and '\n' notin k and v.kind == JString: lines.add k & ": " & mcpHttpExpand(v.getStr)
  except CatchableError: discard
  var ownAuth = false                  # (an Authorization header of the entry's own: no sign-in's token then)
  for l in lines:
    if l.toLowerAscii.startsWith("authorization:"): ownAuth = true
  var session = ""
  var proto = ""
  for line in stdin.lines:
    if line.strip.len == 0: continue
    var msg: JsonNode
    try: msg = parseJson(line)
    except CatchableError: continue
    var body, err = ""
    var status = 0
    for attempt in 0 .. 1:
      var hs = lines & @["Content-Type: application/json", "Accept: application/json, text/event-stream"]
      if not ownAuth:
        let tok = mcpAuthBearer(url)
        if tok.len > 0: hs.add "Authorization: Bearer " & tok
      if session.len > 0: hs.add "Mcp-Session-Id: " & session
      if proto.len > 0: hs.add "MCP-Protocol-Version: " & proto
      try:
        writeFile(hdr, hs.join("\n") & "\n")
        setFilePermissions(hdr, {fpUserRead, fpUserWrite})
      except CatchableError: discard
      (_, body, err) = runFilter("curl -sS -N -X POST -H @" & quoteShell(hdr) & " -D " & quoteShell(got) &
                                 " --data-binary @- " & quoteShell(url), line, dir, 300_000)
      status = 0
      try:
        for l in readFile(got).splitLines:
          if l.startsWith("HTTP/"):
            let p = l.splitWhitespace
            if p.len > 1: status = (try: parseInt(p[1]) except ValueError: 0)
          elif l.toLowerAscii.startsWith("mcp-session-id:"): session = l[15 .. ^1].strip
      except CatchableError: discard
      # (the token ran out: a new one from the refresh token, and the request again — once)
      if status != 401 or ownAuth or attempt > 0 or not mcpAuthRefresh(url): break
    let id = msg{"id"}
    if status < 200 or status >= 300:
      if id != nil and id.kind != JNull:
        let why = if status == 0: "cannot reach " & url & (if err.strip.len > 0: ": " & err.strip.splitLines[0] else: "")
                  elif status == 401 and not ownAuth: "HTTP 401: this server wants you to sign in — palette › MCP: " &
                    "sign in to a server… (or ned --mcp-login " & url & ")"
                  else: "HTTP " & $status & (if body.strip.len > 0: ": " & body.strip.splitLines[0][0 ..< min(200, body.strip.splitLines[0].len)] else: "")
        stdout.writeLine $(%*{"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": why}})
        stdout.flushFile
      continue
    for m in mcpHttpMessages(body):
      try:
        let j = parseJson(m)
        if msg{"method"}.getStr == "initialize" and j{"result"}{"protocolVersion"}.getStr.len > 0:
          proto = j{"result"}{"protocolVersion"}.getStr
      except CatchableError: discard
      stdout.writeLine m
      stdout.flushFile
  try: removeDir(dir)
  except CatchableError: discard
  0
