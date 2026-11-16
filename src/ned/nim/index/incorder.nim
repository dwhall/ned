# ── a name used before the compiler has read the import that brings it (6.53, by position 6.54): the engine's
#    scope of a program is one for the whole of it (its include files share it), but the compiler reads the files in
#    order — each include in place — and an import counts only from where it is: a name used in a file included
#    before the file that imports it, in the top file before that include, or above its own import, is undeclared ──

type NxOrderImport = object
  pos: int                   # (where in the reading order the compiler meets it)
  m: string                  # the module's file
  im: NxImport
  file: string               # the file it is written in

func nxDeclaredHere(s: string, a, e: int): bool =
  ## the name at a ..< e of the line is not a use: it is being declared (`let x =`, `x: int` — a parameter, a field, a
  ## named argument — `for x in`, `proc x`), or asked about (`defined(x)`, `declared(x)`, `compiles(x)`)
  var k = e
  if k < s.len and s[k] == '*': inc k
  while k < s.len and s[k] == ' ': inc k
  if k < s.len and ((s[k] == ':' and not (k + 1 < s.len and s[k + 1] == ':')) or
                    (s[k] == '=' and not (k + 1 < s.len and s[k + 1] == '='))): return true
  var b = a
  while b > 0 and s[b - 1] == ' ': dec b
  let before = s[0 ..< b]
  for w in ["let", "var", "const", "for", "proc", "func", "template", "macro", "iterator", "method", "converter",
            "type", "defined(", "declared(", "compiles("]:
    if before.endsWith(w) and (before.len == w.len or not (before[before.len - w.len - 1] in IdentChars)): return true
  false

proc nxIncludeOrder*(f: NxFile, code: seq[string], lo, hi: int): seq[(int, int, string, string)] =
  ## (line, col, name, the file whose import brings it) for each name in lines lo..hi of `f` that only an import the
  ## compiler has not read yet brings there — in a file included later, further down the file itself, or after the
  ## include of `f` in the file that includes it (once per name). A name after a dot counts only when no field has
  ## it and the import brings a routine of that name (a method call). `code`: the lines with their strings and
  ## comments blanked. Not looked at: names declared in a later file (routines need their forward declarations), and
  ## runnableExamples blocks (their own imports)
  if f == nil or code.len == 0: return
  var top = f.path
  var above: seq[string]
  for _ in 0 ..< 6:
    let h = nxIncluderOf(top)
    if h.len == 0 or h in above or h == f.path: break
    above.add h
    top = h
  if top.extractFilename == "system.nim": return  # (system and its include files: the compiler's own, magic first)
  # the reading order: each file's imports and includes by line, an include read in place, each file once
  var order: seq[NxOrderImport]
  var mine: seq[(int, int)]                  # (f's own imports and includes: line → place in the order)
  var fEnd = -1
  var counter = 0
  var seenFiles = @[top]
  proc inactive(g: NxFile, l: int): bool =
    ## the line is in a `when` branch the defines leave out
    for (a, b) in g.inactive:
      if a <= l and l <= b: return true
  proc walk(p: string, d: int) =
    ## the files `p` includes read in place, its imports noted where they are
    let g = nxLoad(p)
    if g == nil or d > 6: return
    var ims = g.imports
    ims.sort(proc(a, b: NxImport): int = cmp(a.line, b.line))
    for im in ims:
      if inactive(g, im.line): continue
      if p == f.path: mine.add (im.line, counter)
      if im.isInclude:
        let q = nxResolve(g.path, im.spec)
        inc counter
        if q.len > 0 and q notin seenFiles:
          seenFiles.add q
          walk(q, d + 1)
      else:
        let m = nxResolve(g.path, im.spec)
        if m.len > 0: order.add NxOrderImport(pos: counter, m: m, im: im, file: p)
        inc counter
    if p == f.path: fEnd = counter
  walk(top, 0)
  if fEnd < 0: return                          # (f is not in its program's reading order)
  # the names each import brings (from m import a, b: those; import m except c: not that one), and their files
  var cache: Table[string, (Table[string, NxKind], HashSet[string])]
  proc brings(o: NxOrderImport): (Table[string, NxKind], HashSet[string]) =
    ## (normalized name → its kind, the files those names are declared in) for one import
    let key = o.m & "|" & o.im.only.join(",") & "|" & o.im.excepts.join(",")
    if key in cache: return cache[key]
    var s2: HashSet[string]
    var got: seq[NxRef]
    nxExports(o.m, 0, s2, got)
    var only, exc: HashSet[string]
    for x in o.im.only: only.incl nxNorm(x)
    for x in o.im.excepts: exc.incl nxNorm(x)
    for r in got:
      if r.sym.kind == nxField: continue         # (a field is never named alone: posix's fd is not a parameter's)
      let n = nxNorm(r.sym.name)
      if (only.len > 0 and n notin only) or n in exc: continue
      result[1].incl r.file.path
      if n notin result[0] or r.sym.kind in {nxProc, nxFunc, nxMethod, nxIterator, nxConverter, nxTemplate, nxMacro}:
        result[0][n] = r.sym.kind
    cache[key] = result
  var declared: HashSet[string]              # (declared in the file itself: a local, a parameter, its own routines)
  var fields: HashSet[string]                # (the fields of the program's own types)
  for s in f.syms: declared.incl nxNorm(s.name)
  let sc = nxScope(f)
  for r in sc.refs.own:
    if r.sym.kind == nxField: fields.incl nxNorm(r.sym.name)
  var said: HashSet[string]
  # the lines of runnableExamples blocks: compiled on their own, with imports of their own (std/tables's example
  # imports hashes above the module's import of it)
  var examples: seq[(int, int)]
  var l0 = 0
  while l0 < code.len:
    let t0 = code[l0].strip(trailing = false)
    if t0.startsWith("runnableExamples") and (t0.len == 16 or t0[16] in {':', '(', ' '}):
      let ind = code[l0].len - t0.len
      var e = l0 + 1
      while e < code.len and (code[e].strip.len == 0 or code[e].len - code[e].strip(trailing = false).len > ind): inc e
      examples.add (l0, e - 1)
      l0 = e
    else: inc l0
  proc inExample(l: int): bool =
    ## the line is in a runnableExamples block
    for (a, b) in examples:
      if a <= l and l <= b: return true
  # the lines of import, include, from and export statements — `import\n  a, b,\n  c` too: names of modules
  var importLines: HashSet[int]
  for l in 0 ..< code.len:
    let t = code[l].strip(trailing = false)
    var kw = false
    for k in ["import", "include", "from", "export"]:
      if t.startsWith(k) and (t.len == k.len or t[k.len] in {' ', '\t', '['}): kw = true
    if not kw: continue
    importLines.incl l
    let ind = code[l].len - t.len
    var e = l
    while e + 1 < code.len:
      let prev = code[e].strip
      let nt = code[e + 1].strip(trailing = false)
      if nt.len == 0: break
      if code[e + 1].len - nt.len <= ind and not prev.endsWith(",") and prev.count('[') <= prev.count(']'): break
      inc e
      importLines.incl e
  # one part of f at a time: the lines between two of its imports or includes see the same imports
  var cuts = @[(-1, 0)] & mine
  for k in 0 ..< cuts.len:
    let first = cuts[k][0] + 1
    let last = if k + 1 < cuts.len: cuts[k + 1][0] - 1 else: code.high
    let limit = if k + 1 < cuts.len: cuts[k + 1][1] else: fEnd
    if last < max(lo, first) or first > hi: continue
    var seen: HashSet[string]
    for o in order:
      if o.pos < limit: seen.incl o.m
    var later: seq[NxOrderImport]
    for o in order:
      if o.pos >= limit and o.m notin seen: later.add o
    if later.len == 0: continue
    var names: Table[string, (NxKind, string)]   # (a name the later imports bring → its kind, the file importing it)
    var theirs: HashSet[string]
    for o in later:
      let (ns, fs) = brings(o)
      for n, kd in ns:
        if n notin names: names[n] = (kd, o.file)
      for x in fs: theirs.incl x
    if names.len == 0: continue
    var visFiles: HashSet[string]            # (the files the imports already read bring: made when needed)
    var visMade = false
    for l in max(lo, first) .. min(hi, min(last, code.high)):
      let s = code[l]
      if l in importLines or inactive(f, l) or inExample(l): continue
      var i = 0
      while i < s.len:
        if not (s[i] in IdentStartChars or s[i] >= '\x80') or (i > 0 and nxIsIdent(s[i - 1])):
          inc i
          continue
        var e = i
        while e < s.len and nxIsIdent(s[e]): inc e
        let w = s[i ..< e]
        let n = nxNorm(w)
        if n in names and n notin said and n notin declared and w notin NxKeywords and   # (raise: not posix's)
           not nxDeclaredHere(s, i, e):
          let (kd, src) = names[n]
          let dot = nxDotBefore(s, i)
          if not dot or (n notin fields and kd in {nxProc, nxFunc, nxMethod, nxIterator, nxConverter, nxTemplate, nxMacro}):
            var elsewhere = false
            for r in nxLookup(sc, w):
              if r.file.path notin theirs or r.origin == 3:      # (system brings it too: doAssert)
                elsewhere = true
                break
              if not visMade:
                for o in order:
                  if o.pos < limit:
                    let (_, fs) = brings(o)
                    for x in fs: visFiles.incl x
                visMade = true
              if r.file.path in visFiles:
                elsewhere = true
                break
            if not elsewhere:
              for x in nxLocals(f, code, l, i):           # (a local of that name: `let paramCount = …`)
                if nxNorm(x.name) == n:
                  elsewhere = true
                  break
            if not elsewhere:
              said.incl n
              result.add (l, i, w, src)
        i = e
