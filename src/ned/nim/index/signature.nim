# ── a routine found by what it takes and gives — `(string, char) -> seq[string]` finds split — as Hoogle does
#    for Haskell: the question when you know the types in your hands and the type you want, not the name ──

proc nxParseSignature*(q: string, params: var seq[string], ret: var string): bool =
  ## a signature as it is typed — `(string, char) -> seq[string]`, `string, char -> seq[string]`, `(s: string): int`,
  ## `-> JsonNode`, `seq[int]` — as the types of its parameters and of its result ("" not said); false: neither
  var left = q.strip
  var arrow = -1
  var depth = 0
  for i in 0 ..< left.len:
    case left[i]
    of '(', '[', '{': inc depth
    of ')', ']', '}': dec depth
    of '-':
      if depth == 0 and i + 1 < left.len and left[i + 1] == '>' and arrow < 0: arrow = i
    else: discard
  if arrow >= 0:
    ret = left[arrow + 2 .. ^1].strip
    left = left[0 ..< arrow].strip
  elif left.startsWith("("):
    # (written as a routine's header: `(s: string): int`)
    let ce = nxMatchClose(left, 0)
    if ce > 0 and left[ce + 1 .. ^1].strip.startsWith(":"):
      ret = left[ce + 1 .. ^1].strip[1 .. ^1].strip
      left = left[0 .. ce]
  if left.startsWith("(") and nxMatchClose(left, 0) == left.high: left = left[1 ..< left.high]
  for p in nxSplitTop(left, {','}):
    var t = p.strip
    let c = nxFindTop(t, ':')                    # (`s: string`: the type)
    if c > 0: t = t[c + 1 .. ^1].strip
    if t.len > 0 and params.len < 6: params.add nxStripValMods(t)
  ret = nxStripValMods(ret)
  params.len > 0 or ret.len > 0

proc nxSignatureFit*(sc: NxScope, s: NxSym, params: seq[string], ret: string): int =
  ## how well a routine fits the signature asked for (0: not at all): each type asked for goes to a parameter of its
  ## own, in any order — exactly, as a related type (a seq for an openArray, a subtype) or as a generic's — and the
  ## result is of the type asked for; parameters it wants beyond those (without a default) count against it, more
  ## than two rule it out
  if ret.len > 0:
    if s.ret.len == 0: return 0
    let r = max(nxCompat(sc, s.ret, s.generics, ret), nxCompat(sc, ret, "", nxStripValMods(s.ret)))
    if r == 0: return 0
    result = r * 10
  var used = newSeq[bool](s.params.len)
  proc place(k: int): int =
    ## the best fit of the types asked for from the k-th on, to the parameters not taken yet (-1: none)
    if k == params.len: return 0
    result = -1
    for j in 0 ..< s.params.len:
      if used[j]: continue
      let c = nxCompatP(sc, s.params[j], s.generics, params[k])
      if c == 0: continue
      used[j] = true
      let rest = place(k + 1)
      used[j] = false
      if rest >= 0: result = max(result, c * 10 + rest)
  let got = place(0)
  if got < 0: return 0
  var required = 0
  for p in s.params:
    if p.default.len == 0: inc required
  let extra = max(0, required - params.len)
  if params.len > 0 and extra > 2: return 0
  result = max(1, result + got + 8 - 4 * min(extra, 2))

proc nxBySignature*(f: NxFile, sc: NxScope, q: string, limit = 300): seq[(NxRef, int, bool)] =
  ## the routines that fit a signature (nxParseSignature), the closest first: (the routine, how well it fits,
  ## whether `f` can call it as it is — else it is a module's that has been read but is not imported here)
  var params: seq[string]
  var ret = ""
  if f == nil or sc == nil or not nxParseSignature(q, params, ret): return
  var seen: HashSet[(string, int32, string)]
  var inScope: HashSet[string]
  template consider(r: NxRef, here: bool) =
    ## adds the routine when it fits and is not listed yet
    if r.sym.kind in NxRoutineKinds and (r.file.path, int32(r.sym.line), r.sym.name) notin seen:
      let fit = nxSignatureFit(sc, r.sym, params, ret)
      if fit > 0:
        seen.incl (r.file.path, int32(r.sym.line), r.sym.name)
        result.add (r, fit, here)
  for i in 0 ..< f.syms.len: consider(NxRef(file: f, idx: int32(i), origin: 1), true)
  inScope.incl f.path
  for r in sc.refs:
    if r.file == nil or r.file.path == f.path: continue
    inScope.incl r.file.path
    consider(r, true)
  for path, g in nxFiles:
    if g == nil or path in inScope: continue
    for i in 0 ..< g.syms.len:
      if g.syms[i].exported and not g.syms[i].local: consider(NxRef(file: g, idx: int32(i)), false)
  # (the closest first; of those that fit as well, this file's, then what can be called here; then by name)
  result.sort(proc(a, b: (NxRef, int, bool)): int =
    result = cmp(b[1], a[1])
    if result == 0: result = cmp(b[0].file == f, a[0].file == f)
    if result == 0: result = cmp(b[2], a[2])
    if result == 0: result = cmp(a[0].sym.name, b[0].sym.name))
  if result.len > limit: result.setLen(limit)
