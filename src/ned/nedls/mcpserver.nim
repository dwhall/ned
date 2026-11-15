# ── nedls --mcp: ned's Nim engine as an MCP server (Model Context Protocol, over stdin and stdout, a JSON message a
#    line) — the tools ned's assistant has (ai/enginetools: a declaration, its uses, a type, routines by their
#    signature, a file's outline), for Claude Code, Codex, Gemini CLI and the other agents, in ned or outside it ──

const McpServerHelp = """nedls --mcp [--root DIR] — ned's Nim engine as an MCP server on stdin and stdout, for coding agents:
  nim_definition, nim_references, nim_type, nim_routines_by_signature, nim_outline.
  --root DIR   the project (default: the current folder)
  Claude Code: claude mcp add ned -- nedls --mcp      Codex: [mcp_servers.ned] command = "nedls", args = ["--mcp"]
"""

proc mcpServeOne(msg: JsonNode): JsonNode =
  ## the answer to one message (nil for a notification): initialize, ping, tools/list, tools/call
  let id = msg{"id"}
  let meth = msg{"method"}.getStr
  if id == nil or id.kind == JNull: return nil
  var res: JsonNode
  case meth
  of "initialize":
    let asked = msg{"params"}{"protocolVersion"}.getStr
    res = %*{"protocolVersion": (if asked.len > 0: asked else: "2025-06-18"),
             "capabilities": {"tools": {"listChanged": false}},
             "serverInfo": {"name": "ned", "version": NedVersion},
             "instructions": "ned's Nim engine: ask it where a name is declared, where it is used, the type of an " &
                             "expression, which routines fit a signature, or a file's outline — instead of reading " &
                             "whole files. Paths are relative to the project; lines are 1-based."}
  of "ping": res = newJObject()
  of "tools/list":
    var tools = newJArray()
    for (n, d, s) in EngineTools: tools.add %*{"name": n, "description": d, "inputSchema": parseJson(s)}
    res = %*{"tools": tools}
  of "tools/call":
    let name = msg{"params"}{"name"}.getStr
    var args = msg{"params"}{"arguments"}
    if args == nil or args.kind != JObject: args = newJObject()
    var known = false
    for (n, _, _) in EngineTools:
      if n == name: known = true
    if not known:
      return %*{"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "unknown tool " & name}}
    let (text, isErr) = engineTool(name, args)
    res = %*{"content": [{"type": "text", "text": text}], "isError": isErr}
  else:
    return %*{"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "method not found: " & meth}}
  %*{"jsonrpc": "2.0", "id": id, "result": res}

proc mcpServerMain(args: seq[string]): int =
  ## nedls --mcp: the project from --root (else the current folder), ned's settings and the toolchain as nedls has
  ## them, then a message a line until stdin ends
  var root = getCurrentDir()
  var i = 0
  while i < args.len:
    case args[i]
    of "--mcp": discard
    of "--root":
      inc i
      if i < args.len: root = args[i]
    of "--help", "-h":
      stdout.write McpServerHelp
      return 0
    else:
      stderr.writeLine "nedls --mcp: unknown option " & args[i] & " (nedls --mcp --help)"
      return 2
    inc i
  signal(SIGPIPE, SIG_IGN)
  initLangs()
  loadConfig()
  bufs = @[newBuffer()]
  curBuf = 0
  lsSetRoot(root)
  nxEnsureToolchain(nil)
  for line in stdin.lines:
    if line.strip.len == 0: continue
    var ans: JsonNode
    try:
      let msg = parseJson(line)
      if msg.kind != JObject: continue
      ans = mcpServeOne(msg)
    except CatchableError, Defect:
      ans = %*{"jsonrpc": "2.0", "id": nil, "error": {"code": -32700, "message": getCurrentExceptionMsg()}}
    if ans != nil:
      stdout.writeLine $ans
      stdout.flushFile
  0
