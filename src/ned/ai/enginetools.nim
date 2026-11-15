# ── what ned's Nim engine knows, as tools for the assistant, for ACP agents (through the MCP server ned gives them)
#    and for any client of `nedls --mcp`: a declaration, its uses, the type of an expression, routines that fit a
#    signature, a file's outline — so that a model asks instead of reading whole files and guessing ──

const EngineTools = [
  ("nim_definition", "Nim: where a name on a line is declared, with the declaration and its doc comment — the engine's go-to-definition. Give the file, the line (1-based) and the name as written there.",
   """{"type":"object","properties":{"path":{"type":"string","description":"a .nim file, relative to the project root"},"line":{"type":"integer","description":"1-based"},"name":{"type":"string","description":"the name on that line, e.g. split or obj.field"}},"required":["path","line","name"]}"""),
  ("nim_references", "Nim: every place in the project that uses the declaration a name on a line refers to (resolved like the compiler would, not a text search). Give the file, the line (1-based) and the name.",
   """{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"name":{"type":"string"}},"required":["path","line","name"]}"""),
  ("nim_type", "Nim: the type of an expression at a line of a file, with the locals in scope there, e.g. s.split(',') or result.items[0].",
   """{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"expression":{"type":"string"}},"required":["path","line","expression"]}"""),
  ("nim_routines_by_signature", "Nim: routines that fit a signature — the types they take and give, e.g. (string, char) -> seq[string] or -> JsonNode — those the file can call first, then those of modules it does not import.",
   """{"type":"object","properties":{"signature":{"type":"string"},"path":{"type":"string","description":"the .nim file the routine is wanted in (its imports)"}},"required":["signature","path"]}"""),
  ("nim_outline", "Nim: a file's declarations — types, routines with their signatures, constants, variables — each with its line, exported ones marked with *. Cheaper than reading the file.",
   """{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}""")]

proc engineToolsOn(): bool =
  ## the engine's tools are offered to the model: a Nim project (a .nimble file in its folder) or a Nim file open
  for b in bufs:
    if b.lang != nil and b.lang.mode == lmNim: return true
  if rootDir.len == 0: return false
  try:
    for kind, p in walkDir(rootDir):
      if kind == pcFile and (p.endsWith(".nimble") or p.endsWith(".nim")): return true
  except CatchableError: discard
  false

proc engineToolFile(path: string): (NxFile, seq[string], Buffer, string) =
  ## the engine's reading of a .nim file for a tool — its open tab's text when it has one — with its lines and a
  ## buffer for it, or why not (the last: "" when it worked)
  let p = absProjectPath(path)
  if not p.endsWith(".nim") and not p.endsWith(".nims") and not p.endsWith(".nimble"):
    return (nil, @[], nil, "not a Nim file: " & path)
  if aiSecretFile(p): return (nil, @[], nil, AiSecretNote)
  let bi = bufIndexByPath(p)
  var b: Buffer
  if bi >= 0: b = bufs[bi]
  else:
    if not fileExists(p): return (nil, @[], nil, "no such file: " & path)
    try:
      if getFileSize(p) > 4_000_000: return (nil, @[], nil, "file is too large")
      b = newBuffer()
      b.path = p
      b.lines = readFile(p).split('\n')
      b.lang = detectLang(p, "")
    except CatchableError as e: return (nil, @[], nil, e.msg)
  var f: NxFile
  try: f = nxFileFor(b)
  except CatchableError, Defect: discard
  if f == nil: return (nil, @[], nil, "the engine could not read " & path)
  (f, b.lines, b, "")

proc engineToolCol(lines: seq[string], line: int, name: string): int =
  ## the column of `name` on a line (0-based line), as a whole word — of its last part for a.b.c (-1: not there)
  if line < 0 or line >= lines.len or name.len == 0: return -1
  let s = lines[line]
  let n = name.strip
  var i = s.find(n)
  while i >= 0:
    let e = i + n.len
    if (i == 0 or not nxIsIdent(s[i - 1])) and (e >= s.len or not nxIsIdent(s[e])):
      let dot = n.rfind('.')
      return (if dot >= 0: i + dot + 1 else: i)
    i = s.find(n, i + 1)
  -1

proc engineToolWhere(path: string, line: int): string =
  ## path:line for the model: from the project folder inside it, else the whole path
  (if rootDir.len > 0 and path.startsWith(rootDir & "/"): path[rootDir.len + 1 .. ^1] else: path) & ":" & $(line + 1)

proc engineToolLine(path: string, line: int): string =
  ## a file's line, trimmed (from its open tab when it has one), "" when there is none
  let bi = bufIndexByPath(path)
  try:
    let ls = if bi >= 0: bufs[bi].lines else: readFile(path).split('\n')
    if line >= 0 and line < ls.len: return ls[line].strip
  except CatchableError: discard
  ""

proc engineTool(name: string, j: JsonNode): (string, bool) =
  ## runs one of the engine's tools (EngineTools): its answer as text, and whether it is an error
  try:
    case name
    of "nim_definition", "nim_references", "nim_type":
      let (f, ls, b, why) = engineToolFile(j{"path"}.getStr)
      if why.len > 0: return (why, true)
      let line = j{"line"}.getInt - 1
      if line < 0 or line >= ls.len: return ("line " & $(line + 1) & " is not in the file (" & $ls.len & " lines)", true)
      if name == "nim_type":
        let ex = j{"expression"}.getStr.strip
        if ex.len == 0: return ("no expression", true)
        let t = nxTypeOfExpr(f, nxScope(f), nxLocals(f, ls, line, 0), ex, line, 0).typ
        return ((if t.len > 0: ex & ": " & t else: "the engine cannot tell the type of " & ex & " there"), t.len == 0)
      let col = engineToolCol(ls, line, j{"name"}.getStr)
      if col < 0: return (j{"name"}.getStr & " is not on line " & $(line + 1) & ": " & ls[line].strip, true)
      if name == "nim_definition":
        var o: seq[string]
        for (p, l, _, sig) in nxDefinition(f, ls, line, col):
          o.add engineToolWhere(p, l) & ": " & (if sig.len > 0: sig else: engineToolLine(p, l))
          if o.len >= 10: break
        return ((if o.len > 0: o.join("\n") else: "the engine does not know where " & j{"name"}.getStr & " is declared"), o.len == 0)
      var hits: seq[(string, int, int)]
      var decl = ""
      if not engineReferences(b, Pos(line: line, col: col), hits, decl):
        return ("the engine cannot tell what " & j{"name"}.getStr & " is there", true)
      var o: seq[string]
      for (p, l, c) in hits:
        o.add engineToolWhere(p, l) & ":" & $(c + 1) & ": " & engineToolLine(p, l)
        if o.len >= 200:
          o.add "… and " & $(hits.len - 200) & " more"
          break
      return ((if decl.len > 0: decl & "\n" else: "") & $hits.len & " uses" & (if nxRefsCut: " (stopped early)" else: "") &
              (if o.len > 0: ":\n" & o.join("\n") else: ""), false)
    of "nim_routines_by_signature":
      let (f, _, _, why) = engineToolFile(j{"path"}.getStr)
      if why.len > 0: return (why, true)
      var o: seq[string]
      for (r, _, here) in nxBySignature(f, nxScope(f), j{"signature"}.getStr, 40):
        o.add nxSig(r.sym) & "  — " & engineToolWhere(r.file.path, r.sym.line) & (if here: "" else: " (not imported here)")
      return ((if o.len > 0: o.join("\n") else: "no routine fits " & j{"signature"}.getStr), o.len == 0)
    of "nim_outline":
      let (f, _, _, why) = engineToolFile(j{"path"}.getStr)
      if why.len > 0: return (why, true)
      var o: seq[string]
      for s in f.syms:
        if s.local or s.kind in {nxParam, nxForVar, nxResult, nxModule}: continue
        o.add $(s.line + 1) & ": " & (if s.kind in {nxField, nxEnumVal}: "  " else: "") & nxSig(s) &
              (if s.exported: " *" else: "")
        if o.len >= 400:
          o.add "…"
          break
      return ((if o.len > 0: o.join("\n") else: "no declarations"), false)
    else: return ("unknown tool " & name, true)
  except CatchableError, Defect:
    return ("the engine failed: " & getCurrentExceptionMsg(), true)
