# ── an include file that uses a name only an import in a file included after it brings (6.53): the engine's scope
#    of a program is one for the whole of it (its include files share it), but the compiler reads the files in the
#    order they are included, and a name imported later is undeclared before that ──

proc nxIncludeOrder*(f: NxFile, code: seq[string], lo, hi: int): seq[(int, int, string, string)] =
  ## (line, col, name, the include file whose import brings it) for each name in lines lo..hi of `f` — a file another
  ## one includes — that nothing it can see brings, only an import in a file included after it (once per name).
  ## `code`: the lines with their strings and comments blanked. Not looked at: names after a dot (a field or a
  ## method call), the top module's own text, where in a file an import or an include is
  # shortcut: the files are ordered as their includes are, not by where in each file an import is
  if f == nil or code.len == 0: return
  var top = f.path
  var above: seq[string]
  for _ in 0 ..< 6:
    let h = nxIncluderOf(top)
    if h.len == 0 or h in above or h == f.path: break
    above.add h
    top = h
  if above.len == 0: return
  # the include files in the order the compiler reads them, and the ones `f` itself includes
  var order: seq[string]
  proc visit(p: string, d: int, into: var seq[string]) =
    ## the files `p` includes, depth first, each once
    let g = nxLoad(p)
    if g == nil or d > 6: return
    for im in g.imports:
      if not im.isInclude: continue
      let q = nxResolve(g.path, im.spec)
      if q.len > 0 and q != top and q notin into:
        into.add q
        visit(q, d + 1, into)
  visit(top, 0, order)
  let kx = order.find(f.path)
  if kx < 0: return
  var inside: seq[string]
  visit(f.path, 0, inside)
  # the modules imported where `f` sees them, and those imported only after it (→ the file that imports each)
  var seen: HashSet[string]
  var later: OrderedTable[string, string]
  for k, p in @[top] & order:
    let g = nxLoad(p)
    if g == nil: continue
    let sees = k == 0 or k - 1 <= kx or p in inside or p in above
    for im in g.imports:
      if im.isInclude: continue
      let m = nxResolve(g.path, im.spec)
      if m.len == 0: continue
      if sees: seen.incl m
      elif m notin later: later[m] = p
  var names: Table[string, string]         # (a name those bring → the file whose import brings it)
  var theirs: HashSet[string]              # (the files those names are declared in)
  for m, src in later:
    if m in seen: continue
    var s2: HashSet[string]
    var got: seq[NxRef]
    nxExports(m, 0, s2, got)
    for r in got:
      theirs.incl r.file.path
      let n = nxNorm(r.sym.name)
      if n notin names: names[n] = src
  if names.len == 0: return
  var mine: HashSet[string]                # (declared in the file itself: a local, a parameter)
  for s in f.syms: mine.incl nxNorm(s.name)
  let sc = nxScope(f)
  var said: HashSet[string]
  for l in max(0, lo) .. min(hi, code.high):
    let s = code[l]
    let t = s.strip(trailing = false)
    if t.startsWith("import ") or t.startsWith("include ") or t.startsWith("from ") or t.startsWith("export "): continue
    var inactive = false
    for (a, b) in f.inactive:
      if a <= l and l <= b: inactive = true
    if inactive: continue
    var i = 0
    while i < s.len:
      if not (s[i] in IdentStartChars or s[i] >= '\x80') or (i > 0 and nxIsIdent(s[i - 1])):
        inc i
        continue
      var e = i
      while e < s.len and nxIsIdent(s[e]): inc e
      let w = s[i ..< e]
      let n = nxNorm(w)
      if n in names and n notin said and n notin mine and not nxDotBefore(s, i):
        var elsewhere = false
        for r in nxLookup(sc, w):
          if r.file.path notin theirs: elsewhere = true
        if not elsewhere:
          said.incl n
          result.add (l, i, w, names[n])
      i = e
