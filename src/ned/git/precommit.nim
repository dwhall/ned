# ── checks before a commit (git.checksBeforeCommit): the files to be committed are formatted (ned's own
#    formatters, on what is staged), and the tests that cover them pass. One that does not stops the commit and
#    says why — with a way to fix it and a way to commit anyway ──

proc commitFiles(root: string, all: bool): seq[string] =
  ## what the commit takes: the staged files, or (commit -a) every changed tracked file — that still exist
  let (ok, o, _) = runFilter((if all: "git diff --name-only HEAD" else: "git diff --cached --name-only --diff-filter=ACMR") &
                             " 2>/dev/null", "", root, 5000)
  if not ok: return
  for l in o.splitLines:
    let p = l.strip
    if p.len > 0 and fileExists(root / p): result.add root / p

proc stagedText(root, path: string, all: bool): (bool, string) =
  ## the file as the commit takes it: what is staged (or, commit -a, the file itself)
  if all:
    try: return (true, readFile(path))
    except CatchableError: return (false, "")
  let rel = relativePath(path, root)
  let (ok, o, _) = runFilter("git show " & quoteShell(":" & rel) & " 2>/dev/null", "", root, 5000)
  (ok, o)

proc unformattedFiles(root: string, files: seq[string], all: bool): seq[(string, string, bool)] =
  ## (file, its formatted text, only staged = the worktree has the same text) for those ned's own formatter would change
  for f in files:
    let lang = detectLang(f, "")
    # (only the languages you have formatted on save: a file in another style is not called wrong)
    if not cfgFormatOnSave or lang == nil: continue
    if cfgFormatOnSaveLangs.len > 0 and lang.id.toLowerAscii notin cfgFormatOnSaveLangs and
       lang.name.toLowerAscii notin cfgFormatOnSaveLangs: continue
    let kind = builtinFmtKind(f, (if lang != nil: lang.id else: ""))
    if kind.len == 0 or (kind == "nim" and (cfgNimFormatter != "builtin" or "nim" in cfgUserFmt)): continue
    if kind == "c" and haveExe("clang-format"): continue          # (clang-format is the one in use for C)
    let (ok, text) = stagedText(root, f, all)
    if not ok or text.len == 0 or text.len > 2_000_000: continue
    let (res, err) = builtinFormatText(kind, text, 2, f)
    if err.len > 0 or res == text: continue
    var same = all
    if not all:
      try: same = readFile(f) == text
      except CatchableError: same = false
    let bi = bufIndexByPath(f)
    if bi >= 0 and bufs[bi].dirty: same = false          # (unsaved edits in ned: not written over)
    result.add (f, res, same)

proc precommitTests(files: seq[string], then: proc(failed: seq[(string, seq[string])], skipped: int)) =
  ## the test files that cover the files, run one after another; then(the ones that failed, how many could not run)
  var tests: seq[string]
  for f in files:
    if not f.endsWith(".nim"): continue
    var lines: seq[string]
    try:
      let bi = bufIndexByPath(f)
      lines = if bi >= 0: bufs[bi].lines else: readFile(f).splitLines
    except CatchableError: continue
    for t in testsOfFile(f, lines, related = true, most = 5):
      if t notin tests: tests.add t
  if tests.len == 0:
    then(@[], 0)
    return
  info("Before the commit: running " & $tests.len & " test file" & (if tests.len == 1: "" else: "s") & "…")
  var failed: seq[(string, seq[string])]
  var skipped = 0
  var i = 0
  proc next() =
    ## runs the next test file, and when all have been run calls `then` with the failures and the number that could not
    ## run (state 1: failed, 2: did not compile or took too long, 3: skipped)
    if i >= tests.len:
      then(failed, skipped)
      return
    let t = tests[i]
    inc i
    runTestOnSave(t, proc(state: int, names: seq[string], passed: int) =
      case state
      of 1: failed.add (t, names)
      of 2: failed.add (t, @["(it did not compile, or took too long)"])
      of 3: inc skipped
      else: discard
      next())
  next()

proc stagedSecrets(root: string, all: bool): seq[(string, int, string)] =
  ## what looks like a secret in what the commit takes (git.secretsCheck): a file of secrets by its name (.env, a
  ## private key …), or a line it adds with an API key, a token, a password … in it (core/secrets: the shapes the
  ## assistant's redaction knows) — (the file, its line from 0 or -1 for the whole file, what it is)
  let (ok, o, _) = runFilter((if all: "git diff HEAD" else: "git diff --cached") & " -U0 --no-color --no-ext-diff 2>/dev/null",
                             "", root, 10000)
  if not ok: return
  var file = ""
  var line = 0
  for l in o.splitLines:
    if l.startsWith("+++ "):
      file = if l.startsWith("+++ b/"): l[6 .. ^1] else: ""
      if file.len > 0 and isSecretFile(root / file, root = root): result.add (file, -1, "a file of secrets")
    elif l.startsWith("@@"):
      # (@@ -a,b +c,d @@: the added lines from c)
      let plus = l.find('+', 2)
      if plus > 0:
        var e = plus + 1
        while e < l.len and l[e] in Digits: inc e
        line = (try: parseInt(l[plus + 1 ..< e]) - 1 except ValueError: 0)
    elif l.startsWith("+") and file.len > 0:
      if l.len < 4000:
        for s in secFind(l[1 .. ^1]):
          result.add (file, line, s.kind)
          break
      inc line
    if result.len >= 20: return

proc precommitOther(root: string, all: bool, commit: proc())

proc precommitChecks(root: string, all: bool, commit: proc()) =
  ## the checks, then `commit` — or what failed, and the choice. The first, git.secretsCheck: no secret goes into the
  ## history — what looks like one stops the commit, with (o)pen it, (c)ommit anyway, (x) cancel; then the others
  ## (git.checksBeforeCommit: precommitOther)
  let found = if sBool("git.secretsCheck") and root.len > 0: stagedSecrets(root, all) else: @[]
  if found.len == 0:
    precommitOther(root, all, commit)
    return
  var what: seq[string]
  for (f, l, k) in found[0 ..< min(3, found.len)]:
    what.add (if l < 0: f & " (" & k & ")" else: f & ":" & $(l + 1) & " (" & k & ")")
  let (f0, l0, _) = found[0]
  askConfirm("A secret in what you commit: " & what.join(", ") & (if found.len > 3: " …" else: "") &
             " — once pushed it stays in the history. (o)pen it, (c)ommit anyway, (x) cancel", proc(c: char) =
    if c == 'c': precommitOther(root, all, commit)
    elif c == 'o':
      let nb = openFile(root / f0)
      if nb != nil and l0 >= 0: nb.centerOn(nb.clampPos(Pos(line: l0, col: 0))))

proc precommitOther(root: string, all: bool, commit: proc()) =
  ## the checks of git.checksBeforeCommit (formatted, the tests passing), then `commit` — or what failed, and the choice
  if cfgCommitChecks == "off" or root.len == 0:
    commit()
    return
  let files = commitFiles(root, all)
  if files.len == 0:
    commit()
    return
  proc testsThen() =
    ## the second check: unless the setting leaves tests out, runs the tests of the files and, if any fail, asks whether
    ## to open the test, commit anyway or cancel; otherwise commits
    if cfgCommitChecks notin ["both", "tests"]:
      commit()
      return
    precommitTests(files, proc(failed: seq[(string, seq[string])], skipped: int) =
      if failed.len == 0:
        if skipped > 0: info("Tests not run before the commit: the folder is not trusted, or nim is missing")
        commit()
        return
      var what = ""
      for (t, ns) in failed:
        if what.len > 0: what.add "; "
        what.add extractFilename(t) & ": " & ns[0 ..< min(3, ns.len)].join(", ") & (if ns.len > 3: " …" else: "")
      let first = failed[0][0]
      askConfirm("Tests fail: " & what & " — not committed. (o)pen the test, (c)ommit anyway, (x) cancel",
                 proc(c: char) =
        if c == 'c': commit()
        elif c == 'o': discard openFile(first)))
  if cfgCommitChecks notin ["both", "format"]:
    testsThen()
    return
  let bad = unformattedFiles(root, files, all)
  if bad.len == 0:
    testsThen()
    return
  var names: seq[string]
  var fixable = true
  for (f, _, same) in bad:
    names.add relativePath(f, root)
    if not same: fixable = false
  let list = names[0 ..< min(4, names.len)].join(", ") & (if names.len > 4: " …" else: "")
  askConfirm("Not formatted: " & list & " — " &
             (if fixable: "(f)ormat and stage them, " else: "(they have unstaged changes too: format them yourself) ") &
             "(c)ommit anyway, (x) cancel", proc(c: char) =
    if c == 'c': testsThen()
    elif c == 'f' and fixable:
      var paths: seq[string]
      for (f, res, _) in bad:
        let bi = bufIndexByPath(f)
        try:
          if bi >= 0:
            bufs[bi].setTextMinimal(res)
            discard bufs[bi].saveBuffer()
          else: writeFileSafe(f, res)
          paths.add relativePath(f, root)
        except CatchableError as e:
          error("Format " & extractFilename(f) & ": " & e.msg)
          return
      var cmd = "git add --"
      for p in paths: cmd.add " " & quoteShell(p)
      discard startJob(jkGit, cmd, root, proc(j: Job) =
        if j.code != 0:
          error("git add: " & j.output.strip)
          return
        info("Formatted and staged " & $paths.len & " file" & (if paths.len == 1: "" else: "s"))
        testsThen()))
