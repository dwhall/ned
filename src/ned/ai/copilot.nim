# ── GitHub Copilot (6.52, ai.copilot): its language server (@github/copilot-language-server, Node 20.8 or newer)
#    writes the grey suggestions as you type — Tab takes them, as the model's — and the next edits further on in the
#    file; you sign in once with a code shown here, on GitHub's page in the browser ──

var
  copilotSrv: LspServer               # the running server (nil: not started)
  copilotState = ""                   # what it last said about itself (didChangeStatus: its kind and message)
  copilotSaid = ""                    # (the state last told the person: each new one once)
  copilotOut = false                  # it said it is not signed in: no suggestion is asked until it says it is
  copilotWant = ""                    # what to do once it is ready: "signin"
  copilotDocs: Table[int, int]        # buffer id → the version of its text Copilot has

proc copilotCmd(): seq[string] =
  ## how the server starts: ai.copilotCommand, else copilot-language-server when installed, else through npx
  let v = sval("ai.copilotCommand")
  if v != nil and v.kind == JArray and v.len > 0:
    for x in v: result.add x.getStr
    return
  if findExe("copilot-language-server").len > 0: return @["copilot-language-server", "--stdio"]
  @["npx", "-y", "@github/copilot-language-server", "--stdio"]

proc copilotStart(quiet = false): LspServer =
  ## the server, started when it is not running (nil when it cannot be: no Node, no npx — said unless `quiet`)
  if copilotSrv != nil and not copilotSrv.dead: return copilotSrv
  let c = copilotCmd()
  if c.len == 0 or findExe(c[0]).len == 0:
    if not quiet:
      warn("Copilot needs " & (if c.len > 0: c[0] else: "a command") & " — Node.js 20.8 or newer (Termux: pkg " &
           "install nodejs), or ai.copilotCommand")
    return nil
  copilotSrv = lspSpawn("copilot", c, secondary = false)
  if copilotSrv == nil and not quiet: error("Copilot's language server did not start: " & c.join(" "))
  copilotSrv

proc copilotReady(s: LspServer) =
  ## the server answered initialize: what was waiting for it (the sign-in) goes on
  s.lspNotify("workspace/didChangeConfiguration", %*{"settings": {"telemetry": {"telemetryLevel": "off"}}})
  if copilotWant == "signin":
    copilotWant = ""
    runCmd("Copilot: sign in…")

proc cmdCopilotSignIn()

proc copilotStatus(p: JsonNode) =
  ## didChangeStatus: whether it works — signed in (Normal), not (Error: told once, with how to sign in), a passing
  ## problem (Warning), a file it leaves alone (Inactive)
  let kind = p{"kind"}.getStr
  let msg = p{"message"}.getStr.strip
  copilotState = kind & (if msg.len > 0: ": " & msg else: "")
  if not p{"busy"}.getBool: copilotOut = kind == "Error"
  if copilotState == copilotSaid or p{"busy"}.getBool: return
  copilotSaid = copilotState
  case kind
  of "Error":
    toast("Copilot: " & (if msg.len > 0: msg else: "not signed in"), 2, "Sign in", proc() = cmdCopilotSignIn(),
          ttl = 20_000)
  of "Warning":
    if msg.len > 0: info("Copilot: " & msg)
  else: discard

proc copilotSync(s: LspServer, b: Buffer) =
  ## Copilot has the buffer's text as it is now (opened the first time, the whole text again after a change)
  let v = copilotDocs.getOrDefault(b.id, -1)
  if v == b.changeId: return
  if v < 0:
    s.lspNotifyText("textDocument/didOpen", %*{"textDocument": {"uri": uriFromPath(b.path),
      "languageId": b.lang.id, "version": b.changeId + 1, "text": LspTextMark}}, b)
  else:
    s.lspNotifyText("textDocument/didChange", %*{"textDocument": {"uri": uriFromPath(b.path),
      "version": b.changeId + 1}, "contentChanges": [{"text": LspTextMark}]}, b)
  copilotDocs[b.id] = b.changeId

proc copilotForget(id: int) =
  ## a tab closed: Copilot lets its file go
  if id notin copilotDocs: return
  copilotDocs.del id
  let b = bufById(id)
  if copilotSrv != nil and copilotSrv.ready and not copilotSrv.dead and b != nil and b.path.len > 0:
    copilotSrv.lspNotify("textDocument/didClose", %*{"textDocument": {"uri": uriFromPath(b.path)}})

proc copilotUsable(b: Buffer): LspServer =
  ## the server, ready, for a file it may see (saved somewhere, not a file of secrets) — nil otherwise; it is started
  ## the first time (a request then comes at the next pause)
  if b.path.len == 0 or b.lang == nil or aiSecretFile(b.path): return nil
  let s = copilotStart(quiet = copilotSrv != nil)
  if s == nil or not s.ready or s.dead: return nil
  s

func copilotFit(line: string, col, a, e: int, text: string): string =
  ## what a suggestion for the range a ..< e of a line adds at the cursor (column `col`): the part of `text` after what
  ## is typed before the cursor, without what is already after it — "" when it would change what is there
  if a > col or e < col: return ""
  let before = line[max(0, a) ..< col]
  if not text.startsWith(before): return ""
  var t = text[before.len .. ^1]
  let after = line[col ..< min(line.len, e)]
  if after.len > 0:
    if not t.endsWith(after): return ""
    t.setLen(t.len - after.len)
  t

proc copilotAsk(b: Buffer) =
  ## asks Copilot for the suggestion at the cursor (textDocument/inlineCompletion): its first that only adds text
  ## there is shown as the grey text, and Copilot is told it was shown
  let s = copilotUsable(b)
  if s == nil or copilotOut: return                 # (not signed in: Copilot: sign in… first — said once)
  s.copilotSync(b)
  let at = b.primary.head
  let (id, ch) = (b.id, b.changeId)
  ghostAskedChange = ch
  ghostAskedBuf = id
  let params = %*{"textDocument": {"uri": uriFromPath(b.path), "version": b.changeId + 1},
                  "position": s.lspPos(b, at), "context": {"triggerKind": 2},
                  "formattingOptions": {"tabSize": b.lang.indentWidth, "insertSpaces": not b.lang.useTabs}}
  s.lspCall("textDocument/inlineCompletion", params, proc(res: JsonNode, err: string) =
    let bb = bufById(id)
    if err.len > 0 and "NotSignedIn" in err: copilotOut = true
    if err.len > 0 or res == nil or bb == nil or bb.changeId != ch or bb.primary.head != at: return
    let items = if res.kind == JArray: res else: res{"items"}
    if items == nil or items.kind != JArray: return
    for it in items:
      let r = it{"range"}
      var t = it{"insertText"}.getStr.replace("\r\n", "\n")
      if r != nil:
        let a = fromLspPos(s, bb, r{"start"})
        let e = fromLspPos(s, bb, r{"end"})
        if a.line != at.line or e.line != at.line: continue
        t = copilotFit(bb.lines[at.line], at.col, a.col, e.col, t)
      if t.strip.len == 0: continue
      ghostText = t
      ghostBuf = id
      ghostPos = at
      ghostChange = ch
      copilotItem = it
      s.lspNotify("textDocument/didShowCompletion", %*{"item": it})
      needRender = true
      return)

proc copilotNextEdit(b: Buffer, quiet: bool)

proc copilotTaken() =
  ## the suggestion shown was taken: Copilot is told (the item's own command), and then asked for the next edit
  let it = copilotItem
  copilotItem = nil
  if it == nil or copilotSrv == nil or copilotSrv.dead: return
  let c = it{"command"}
  if c != nil and c.kind == JObject and c{"command"}.getStr.len > 0:
    copilotSrv.lspCall("workspace/executeCommand", %*{"command": c{"command"}, "arguments": c{"arguments"}},
                       proc(res: JsonNode, err: string) = discard)
  if sBool("ai.copilotNextEdits"): copilotNextEdit(buf(), quiet = true)

proc copilotEditApply(id: int, e: JsonNode) =
  ## a next edit applied to its file (one undo step), the cursor after it, and Copilot told
  let b = bufById(id)
  let s = copilotSrv
  if b == nil or s == nil or not b.canEdit(): return
  let (a, c, t) = lspEditOf(s, b, %*{"range": e{"range"}, "newText": e{"text"}})
  b.beginEdit()
  let p = b.replaceText(a, c, t)
  b.endEdit()
  b.setSingle(p)
  b.centerOn(p)
  let cmd = e{"command"}
  if cmd != nil and cmd.kind == JObject and cmd{"command"}.getStr.len > 0:
    s.lspCall("workspace/executeCommand", %*{"command": cmd{"command"}, "arguments": cmd{"arguments"}},
              proc(res: JsonNode, err: string) = discard)

proc copilotNextEdit(b: Buffer, quiet: bool) =
  ## asks Copilot what to change next in the file (textDocument/copilotInlineEdit): the change shown — the lines as
  ## they are and as they would be — to apply, go to or leave; `quiet`: after a suggestion was taken, only a note
  ## that there is one (nothing when there is none)
  let s = copilotUsable(b)
  if s == nil:
    if not quiet: info("Copilot is starting (or off: ai.copilot) — ask again in a moment")
    return
  s.copilotSync(b)
  let (id, ch) = (b.id, b.changeId)
  s.lspCall("textDocument/copilotInlineEdit", %*{"textDocument": {"uri": uriFromPath(b.path),
            "version": b.changeId + 1}, "position": s.lspPos(b, b.primary.head)}, proc(res: JsonNode, err: string) =
    let bb = bufById(id)
    if bb == nil or bb.changeId != ch: return
    let edits = if res != nil: res{"edits"} else: nil
    if err.len > 0 or edits == nil or edits.kind != JArray or edits.len == 0:
      if not quiet: info("Copilot has no next edit here" & (if err.len > 0: " (" & err & ")" else: ""))
      return
    let e = edits[0]
    let (a, c, t) = lspEditOf(s, bb, %*{"range": e{"range"}, "newText": e{"text"}})
    let cmdArgs = if e{"command"} != nil: e{"command"}{"arguments"} else: newJArray()
    s.lspNotify("textDocument/didShowInlineEdit", %*{"item": {"command": {"arguments": cmdArgs}}})
    let lastL = min(c.line, bb.lines.high)
    let was = bb.lines[a.line .. lastL].join("\n")
    let now = bb.lines[a.line][0 ..< min(a.col, bb.lines[a.line].len)] & t & bb.lines[lastL][min(c.col, bb.lines[lastL].len) .. ^1]
    proc show() =
      ## the change, to apply, go to or leave
      var items = @[mi("Apply Copilot's change at line " & $(a.line + 1), "", proc() = copilotEditApply(id, e)),
                    mi("Go there", "", proc() =
                      let b2 = bufById(id)
                      if b2 != nil:
                        b2.setSingle(b2.clampPos(a))
                        b2.centerOn(b2.primary.head)),
                    msep()]
      for l in was.splitLines[0 ..< min(6, was.splitLines.len)]: items.add mi("− " & truncTo(l.strip, 70), disabled = true)
      for l in now.splitLines[0 ..< min(6, now.splitLines.len)]: items.add mi("+ " & truncTo(l.strip, 70), disabled = true)
      openMenu(items, (if cursorX >= 0: cursorX else: scrW div 3), (if cursorY >= 0: cursorY + 1 else: 3))
    if quiet:
      toast("Copilot suggests a change at line " & $(a.line + 1), 3, "Show", show)
    else: show())

proc cmdCopilotSignIn() =
  ## signs in to GitHub Copilot: the server gives a code (copied, and shown), then GitHub's page opens in the browser
  ## to type it in; a server signed in already says who
  let s = copilotStart()
  if s == nil: return
  if not s.ready:
    copilotWant = "signin"
    info("Copilot is starting — the sign-in follows")
    return
  s.lspCall("signIn", newJObject(), proc(res: JsonNode, err: string) =
    if err.len > 0:
      error("Copilot: " & err)
      return
    if res == nil or res.kind != JObject: return
    let user = res{"user"}.getStr
    if res{"status"}.getStr in ["AlreadySignedIn", "OK"]:
      copilotOut = false
      info("Copilot: signed in" & (if user.len > 0: " as " & user else: ""))
      return
    let code = res{"userCode"}.getStr
    if code.len > 0: clipSet(code)
    let cmd = res{"command"}
    let page = res{"verificationUri"}.getStr
    toast("Copilot: your code is " & code & " (copied) — paste it on GitHub's page", 3, ttl = 120_000)
    info("Copilot: your code is " & code & " (copied) — paste it on GitHub's page" &
         (if page.len > 0: ": " & page else: ""))
    if cmd != nil and cmd.kind == JObject and cmd{"command"}.getStr.len > 0:
      s.lspCall("workspace/executeCommand", %*{"command": cmd{"command"}, "arguments": cmd{"arguments"}},
                proc(r: JsonNode, e: string) =
        if e.len > 0: error("Copilot: " & e)
        elif r != nil and r.kind == JObject and r{"user"}.getStr.len > 0:
          copilotOut = false
          info("Copilot: signed in as " & r{"user"}.getStr))
    elif page.len > 0: openInBrowser(page))

proc cmdCopilotSignOut() =
  ## signs out of GitHub Copilot
  if copilotSrv == nil or copilotSrv.dead or not copilotSrv.ready:
    info("Copilot is not running")
    return
  copilotSrv.lspCall("signOut", newJObject(), proc(res: JsonNode, err: string) =
    if err.len > 0: error("Copilot: " & err) else: info("Copilot: signed out"))
