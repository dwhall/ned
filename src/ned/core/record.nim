# ════════════════════════════════════════════════════════
#  A session recorded and played back. `ned --record FILE` writes what the terminal sent — keys, the mouse, its
#  answers, its size — and the text of the files opened, as they come; `ned --replay FILE` gives it all back, with
#  the pauses between, to a ned started the same way: a bug seen on one machine, seen again on another.
#  The file is text, a line per event: `i GAP "bytes"` (input), `r GAP COLS ROWS` (the terminal's size),
#  `f GAP ["path", "text"]` (a file read, by its path from the start folder) — GAP: ms since the event before — after
#  a first line of JSON: ned's version, the arguments, the terminal's environment, the settings (secrets taken out)
# ════════════════════════════════════════════════════════

const
  RecFileMax = 1_000_000       # (bytes: a bigger file is not put in a recording)
  RepGapMax = 3000             # (ms: a longer pause is played as this long)
  RecEnv = ["TERM", "COLORTERM", "TERM_PROGRAM", "TERMUX_VERSION", "TMUX", "LANG", "LC_ALL", "NO_COLOR"]

type RecEvent = object
  kind: char                   # i: input, r: the terminal's size, f: a file's text
  gap: int                     # ms since the event before
  a, b: string                 # i: the bytes; f: the path from the start folder, and the text
  w, h: int                    # r: columns and rows

var
  recOut: File                 # --record: the recording being written (nil: none)
  recPath = ""                 # … its file
  recRoot = ""                 # the start folder: files under it are recorded
  recLast: MonoTime            # when the event before was written
  recCount = 0                 # events written
  recFiles: seq[string]        # the files whose text is in it
  recSeen: Table[string, Hash] # file → its text as last recorded
  recSize = (0, 0)             # the size last recorded
  repEvents: seq[RecEvent]     # --replay: the recording's events
  repAt = 0                    # … the next one
  repOn = false                # the keys come from the recording (until it ends)
  repLast: MonoTime            # when the event before was given
  repSize = (0, 0)             # the terminal's size as recorded ((0, 0): the real one)
  repRoot = ""                 # the folder the replay runs in: the recording's files are written there
  repNote = ""                 # what to say when ned leaves

func recSafePath(p: string): bool =
  ## a path from the start folder that stays in it: not empty, not absolute, no `..`, no NUL
  if p.len == 0 or p.len > 1000 or p[0] in {'/', '\\'} or '\0' in p or (p.len > 1 and p[1] == ':'): return false
  for part in p.split({'/', '\\'}):
    if part == "..": return false
  true

proc recEvent(kind: char, rest: string) =
  ## one event written, and given to the system at once: what happened before a crash is in the file
  if recOut == nil: return
  let now = getMonoTime()
  try:
    recOut.writeLine kind & " " & $(if recCount == 0: 0 else: int((now - recLast).inMilliseconds)) & " " & rest
    recOut.flushFile()
  except IOError: discard
  recLast = now
  inc recCount

proc recInput(bytes: string) =
  ## what the terminal just sent (as text when it reads back the same, else in base64)
  if recOut == nil or bytes.len == 0: return
  let js = escapeJson(bytes)
  let same = try: parseJson(js).getStr == bytes except CatchableError: false
  recEvent('i', if same: js else: "b" & encode(bytes))

proc recResized(w, h: int) =
  ## the terminal's size, when it is not the one last recorded
  if recOut == nil or (w, h) == recSize: return
  recSize = (w, h)
  recEvent('r', $w & " " & $h)

proc recFileRead(path: string) =
  ## a file ned reads (a tab's, the project's settings): its text, when it is under the start folder, not big, and
  ## not recorded as it is already
  if recOut == nil or recRoot.len == 0 or not path.startsWith(recRoot & "/"): return
  let rel = path[recRoot.len + 1 .. ^1]
  if not recSafePath(rel): return
  try:
    if getFileSize(path) > RecFileMax or path == recPath: return
    let text = readFile(path)
    let h = hash(text)
    if recSeen.getOrDefault(rel, Hash(0)) == h and rel in recSeen: return
    recSeen[rel] = h
    if rel notin recFiles: recFiles.add rel
    recEvent('f', $(%*[rel, text]))
  except CatchableError: discard

func recConfigText(config: string): string =
  ## the settings file's text for a recording: the value of every key that names a secret (an API key, a token, a
  ## password — `ai.apiKey`, an agent's `ANTHROPIC_API_KEY`) emptied; the caller takes out what looks like one
  var i = 0
  while i < config.len:
    if config[i] != '"':
      result.add config[i]
      inc i
      continue
    # a string: is it a key (a colon after it) that names a secret, with a string for its value?
    var e = i + 1
    while e < config.len and config[e] != '"':
      if config[e] == '\\': inc e
      inc e
    let key = config[min(i + 1, config.len) ..< min(e, config.len)].toLowerAscii.multiReplace(("_", ""), (".", ""), ("-", ""))
    result.add config[i .. min(e, config.high)]
    i = e + 1
    var secret = false
    for w in ["apikey", "token", "secret", "password", "passwd", "authorization", "credential"]:
      if w in key: secret = true
    if not secret: continue
    var v = i
    while v < config.len and config[v] in {' ', '\t'}: inc v
    if v >= config.len or config[v] != ':': continue
    inc v
    while v < config.len and config[v] in {' ', '\t'}: inc v
    if v >= config.len or config[v] != '"': continue
    var ve = v + 1
    while ve < config.len and config[ve] != '"':
      if config[ve] == '\\': inc ve
      inc ve
    result.add config[i ..< v] & "\"\""
    i = ve + 1

proc recStart(path, root: string, args: JsonNode, config: string): string =
  ## starts a recording in `path` of a session in the folder `root`, started with `args` (each file as [its path from
  ## the folder, line, column]) and these settings: "" or why not
  try:
    if not open(recOut, path, fmWrite): return "cannot write " & path
    setFilePermissions(path, {fpUserRead, fpUserWrite})  # (what was typed is in it: yours only)
  except CatchableError as e:
    recOut = nil
    return e.msg
  recPath = path
  recRoot = root
  var env = newJObject()
  for n in RecEnv:
    if existsEnv(n): env[n] = %getEnv(n)
  try:
    recOut.writeLine $(%*{"ned": Version, "args": args, "env": env, "config": config})
  except IOError: discard
  # (what the project's folder says about itself: read by ned without a tab)
  for f in [".editorconfig", ".ned/settings.json", ".ned/lint.json", "nim.cfg", "config.nims"]:
    if fileExists(root / f): recFileRead(root / f)
  try:
    for kind, p in walkDir(root):
      if kind == pcFile and p.endsWith(".nimble"): recFileRead(p)
  except CatchableError: discard
  ""

proc recDone(): string =
  ## ends the recording: what it holds, to say when ned leaves ("" none was made)
  if recOut == nil: return
  close(recOut)
  recOut = nil
  result = "ned: recorded this session in " & recPath & " — it holds every key you typed (a password too) and the " &
           "text of " & (if recFiles.len == 0: "no file" elif recFiles.len <= 6: recFiles.join(", ")
                         else: recFiles[0 .. 4].join(", ") & " and " & $(recFiles.len - 5) & " more") &
           ": a text file, read it before you send it. Play it back with: ned --replay " & extractFilename(recPath)

proc repWriteFiles(k: int) =
  ## the files the recording has from event k up to its next input: written into the replay's folder (as they were
  ## when ned read them), unless they are there the same
  var j = k
  while j < repEvents.len and repEvents[j].kind != 'i':
    let e = repEvents[j]
    inc j
    if e.kind != 'f' or not recSafePath(e.a): continue
    let p = repRoot / e.a
    try:
      if fileExists(p) and readFile(p) == e.b: continue
      createDir(parentDir(p))
      writeFile(p, e.b)
    except CatchableError: discard

proc repLoad(path: string, header: var JsonNode): string =
  ## reads a recording: its first line (`header`) and its events — "" or what is wrong with it. Lines it cannot read
  ## are left out; sizes and pauses are kept within reason
  var first = true
  try:
    for line in lines(path):
      if first:
        first = false
        header = parseJson(line)
        if header.kind != JObject or not header.hasKey("ned"): return "not a recording of ned's"
        continue
      let parts = line.split(' ', 2)
      if parts.len < 3 or parts[0].len != 1: continue
      var e = RecEvent(kind: parts[0][0])
      try:
        e.gap = clamp(parseInt(parts[1]), 0, RepGapMax)
        case e.kind
        of 'i':
          e.a = if parts[2].startsWith("b"): decode(parts[2][1 .. ^1]) else: parseJson(parts[2]).getStr
        of 'r':
          let wh = parts[2].split(' ')
          e.w = clamp(parseInt(wh[0]), 20, 1000)
          e.h = clamp(parseInt(wh[1]), 5, 1000)
        of 'f':
          let j = parseJson(parts[2])
          e.a = j[0].getStr
          e.b = j[1].getStr
          if not recSafePath(e.a): continue
        else: continue
      except CatchableError, Defect: continue
      repEvents.add e
  except CatchableError as e:
    return e.msg
  if first: return "the file is empty"
  for e in repEvents:
    # (the size ned started in: the first one, before any key)
    if e.kind == 'i': break
    if e.kind == 'r':
      repSize = (e.w, e.h)
      break
  ""

proc repStart(root: string) =
  ## the replay begins, in the folder `root`: the files read before the first key are there
  repRoot = root
  repOn = repEvents.len > 0
  repLast = getMonoTime()
  repWriteFiles(0)

proc repDueMs(): int =
  ## ms until the recording's next event is due (a long time when none is played; 0 at its end, which repNext notes)
  if not repOn: return 60_000
  if repAt >= repEvents.len: return 0
  max(0, repEvents[repAt].gap - int((getMonoTime() - repLast).inMilliseconds))

proc repNext(bytes: var string): bool =
  ## gives what is due of the recording, up to one input (true: `bytes` is what the terminal sent then) — a size
  ## becomes the terminal's, the files read after that input are written first. One input a call: two that came
  ## apart stay apart (an Escape on its own is not an Alt key)
  while repAt < repEvents.len and repDueMs() == 0:
    let e = repEvents[repAt]
    inc repAt
    repLast = getMonoTime()
    case e.kind
    of 'r':
      repSize = (e.w, e.h)
      gResized = true
    of 'i':
      repWriteFiles(repAt)
      bytes = e.a
      return true
    else: discard
  if repOn and repAt >= repEvents.len: repOn = false     # (it has ended: the keys are the terminal's again)
