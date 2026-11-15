# ── signing in to an MCP server on the web (6.52), as MCP asks it be done (OAuth 2.1): `ned --mcp-login URL` finds
#    the server's sign-in service from what it publishes about itself, registers ned with it, sends your browser to its
#    page, takes the answer on a port of this machine (127.0.0.1 only) and trades it for a token (with PKCE, so the
#    answer is no use to anyone else). The token is kept in ned's state folder, for you only (0600): the bridge
#    (ned --mcp-http) sends it, and gets a new one with the refresh token when it has run out ──

import std/sysrand

proc mcpAuthFile(url: string): string =
  ## where the token for a server is kept: ned's state folder (it lasts — the private one is a temporary folder), a
  ## file named after the server's address
  stateDir() / "mcp-auth" / (sha256Hex(url)[0 ..< 24] & ".json")

func mcpB64Url(s: string): string =
  ## base64url without padding (PKCE's challenge and verifier, the state)
  encode(s, safe = true).strip(leading = false, chars = {'='})

proc mcpRandom(n: int): string =
  ## n random bytes, base64url
  var s = newString(n)
  try:
    let b = urandom(n)
    for i in 0 ..< n: s[i] = char(b[i])
  except CatchableError:
    for i in 0 ..< n: s[i] = char((getMonoTime().ticks shr (i mod 8)) and 0xFF)
  mcpB64Url(s)

func mcpEnc(s: string): string =
  ## a value percent-encoded for a URL's query or a form (RFC 3986's unreserved characters as they are)
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

func mcpDec(s: string): string =
  ## a percent-encoded value back ('+' a space, as forms write it)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      result.add char(parseHexInt(s[i + 1 .. i + 2]))
      i += 3
    else:
      result.add (if s[i] == '+': ' ' else: s[i])
      inc i

func mcpForm(pairs: openArray[(string, string)]): string =
  ## name=value pairs as a form or a query (the empty ones left out)
  for (k, v) in pairs:
    if v.len == 0: continue
    if result.len > 0: result.add '&'
    result.add mcpEnc(k) & "=" & mcpEnc(v)

func mcpOrigin(url: string): string =
  ## https://host[:port] of a URL
  let s = url.find("://")
  if s < 0: return url
  let e = url.find('/', s + 3)
  if e < 0: url else: url[0 ..< e]

proc mcpFetch(meth, url: string, body = "", ctype = "", accept = "application/json"): (int, string, string) =
  ## an HTTP request with curl: its status (0: not reached), its body and its headers
  var dir = privDir() / ("mcp-auth-" & $getCurrentProcessId())
  try: createDir(dir)
  except CatchableError:
    dir = getTempDir() / ("ned-mcp-auth-" & $getCurrentProcessId())     # (in an agent's sandbox: its own)
    try: createDir(dir)
    except CatchableError: return (0, "", "")
  let hdr = dir / "headers"
  var cmd = "curl -sS -X " & meth & " -D " & quoteShell(hdr) & " -H " & quoteShell("Accept: " & accept)
  if ctype.len > 0: cmd.add " -H " & quoteShell("Content-Type: " & ctype) & " --data-binary @-"
  cmd.add " " & quoteShell(url)
  let (_, res, _) = runFilter(cmd, body, dir, 30_000)
  var status = 0
  var heads = ""
  try:
    heads = readFile(hdr)
    for l in heads.splitLines:
      if l.startsWith("HTTP/"):
        let p = l.splitWhitespace
        if p.len > 1: status = (try: parseInt(p[1]) except ValueError: 0)
  except CatchableError: discard
  try: removeDir(dir)
  except CatchableError: discard
  (status, res, heads)

func mcpHeaderParam(heads, header, param: string): string =
  ## a parameter of a header — WWW-Authenticate: Bearer resource_metadata="…", scope="…" — "" when it is not there
  for l in heads.splitLines:
    if not l.toLowerAscii.startsWith(header.toLowerAscii & ":"): continue
    let k = l.find(param & "=")
    if k < 0: continue
    var v = l[k + param.len + 1 .. ^1]
    if v.startsWith("\""):
      let e = v.find('"', 1)
      return (if e > 0: v[1 ..< e] else: v[1 .. ^1])
    let e = v.find({',', ' ', '\r'})
    return (if e >= 0: v[0 ..< e] else: v)
  ""

proc mcpJsonGet(url: string): JsonNode =
  ## a JSON document from the web (nil when it is not there, or not JSON)
  let (st, body, _) = mcpFetch("GET", url)
  if st < 200 or st >= 300: return nil
  try:
    result = parseJson(body)
    if result.kind != JObject: result = nil
  except CatchableError: result = nil

proc mcpAuthSave(url: string, j: JsonNode) =
  ## the token's file written (only you may read it)
  let f = mcpAuthFile(url)
  try:
    createDir(parentDir(f))
    setFilePermissions(parentDir(f), {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(f, "")
    setFilePermissions(f, {fpUserRead, fpUserWrite})
    writeFile(f, $j)
    setFilePermissions(f, {fpUserRead, fpUserWrite})
  except CatchableError: discard

proc mcpAuthLoad(url: string): JsonNode =
  ## the token kept for a server (nil: none)
  try:
    result = parseJson(readFile(mcpAuthFile(url)))
    if result.kind != JObject: result = nil
  except CatchableError: result = nil

proc mcpAuthTokens(url: string, a: JsonNode, form: string): bool =
  ## the token endpoint asked (a code or a refresh token in `form`): the new tokens kept with what refreshes them
  let (st, body, _) = mcpFetch("POST", a{"token_endpoint"}.getStr, form, "application/x-www-form-urlencoded")
  if st < 200 or st >= 300: return false
  var t: JsonNode
  try: t = parseJson(body)
  except CatchableError: return false
  if t.kind != JObject or t{"access_token"}.getStr.len == 0: return false
  a["access_token"] = t["access_token"]
  if t{"refresh_token"}.getStr.len > 0: a["refresh_token"] = t["refresh_token"]
  let ex = t{"expires_in"}.getInt(0)
  a["expires_at"] = %(if ex > 0: epochTime().int + ex else: 0)
  mcpAuthSave(url, a)
  true

proc mcpAuthRefresh(url: string): bool =
  ## a new token from the refresh token kept (false: none, or the server refused it — sign in again)
  let a = mcpAuthLoad(url)
  if a == nil or a{"refresh_token"}.getStr.len == 0 or a{"token_endpoint"}.getStr.len == 0: return false
  mcpAuthTokens(url, a, mcpForm([("grant_type", "refresh_token"), ("refresh_token", a{"refresh_token"}.getStr),
                                 ("client_id", a{"client_id"}.getStr), ("client_secret", a{"client_secret"}.getStr),
                                 ("resource", url)]))

proc mcpAuthBearer(url: string): string =
  ## the token to send to a server ("" none): a fresh one first when it has run out (a minute's margin)
  var a = mcpAuthLoad(url)
  if a == nil: return ""
  let ex = a{"expires_at"}.getInt(0)
  if ex > 0 and epochTime().int > ex - 60 and mcpAuthRefresh(url): a = mcpAuthLoad(url)
  if a == nil: "" else: a{"access_token"}.getStr

proc mcpLoginListen(): (cint, int) =
  ## a socket listening on 127.0.0.1, on a port between 33418 and 33517 (the first free from a random one): it and
  ## its port, or -1
  let start = int(getMonoTime().ticks mod 100)
  for k in 0 ..< 100:
    let port = 33418 + (start + k) mod 100
    let fd = posix.socket(AF_INET, SOCK_STREAM, 0)
    if fd.cint < 0: return (-1, 0)
    var a: Sockaddr_in
    a.sin_family = TSa_Family(AF_INET)
    a.sin_port = htons(uint16(port))
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    if posix.bindSocket(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0 and posix.listen(fd, 4) == 0:
      return (fd.cint, port)
    discard posix.close(fd.cint)
  (-1, 0)

proc mcpLoginWait(ls: cint, state: string, secs: int): (string, string) =
  ## the browser's visit to the port, sent there by the sign-in page: the code (or the error) it brings, after its
  ## state was checked — a page saying what happened goes back to the browser; ("", why) when none came in time
  let until = getMonoTime() + initDuration(seconds = secs)
  while getMonoTime() < until:
    var pf = [TPollfd(fd: ls, events: POLLIN)]
    if posix.poll(addr pf[0], 1, 500) <= 0: continue
    let c = posix.accept(SocketHandle(ls), nil, nil)
    if c.cint < 0: continue
    var req = ""
    var buf = newString(4096)
    let t0 = getMonoTime()
    while "\r\n\r\n" notin req and req.len < 16384 and msSince(t0) < 5000:
      var cp = [TPollfd(fd: c.cint, events: POLLIN)]
      if posix.poll(addr cp[0], 1, 500) <= 0: continue
      let n = posix.read(c.cint, addr buf[0], buf.len)
      if n <= 0: break
      req.add buf[0 ..< n]
    let first = req.splitLines()[0].splitWhitespace
    let target = if first.len >= 2: first[1] else: ""
    var q: Table[string, string]
    let qi = target.find('?')
    if qi >= 0:
      for kv in target[qi + 1 .. ^1].split('&'):
        let e = kv.find('=')
        if e > 0: q[mcpDec(kv[0 ..< e])] = mcpDec(kv[e + 1 .. ^1])
    let ours = target.startsWith("/callback")
    let ok = ours and q.getOrDefault("state") == state and q.getOrDefault("code").len > 0
    let page = if not ours: "" elif ok: "Signed in — you can close this page and go back to ned."
               else: "ned could not sign in: " & q.getOrDefault("error_description", q.getOrDefault("error", "the answer did not match"))
    let resp = (if ours: "HTTP/1.1 200 OK" else: "HTTP/1.1 404 Not Found") &
               "\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<!doctype html><title>ned</title>" &
               "<p style=\"font: 18px sans-serif; margin: 3em\">" & page.replace("<", "&lt;") & "</p>\n"
    discard posix.write(c.cint, unsafeAddr resp[0], resp.len)
    discard posix.close(c.cint)
    if not ours: continue
    if ok: return (q["code"], "")
    return ("", page[min(page.len, "ned could not sign in: ".len) .. ^1])
  ("", "no answer from the browser in " & $(secs div 60) & " minutes")

proc mcpLoginMain(args: seq[string]): int =
  ## ned --mcp-login URL [CLIENT-ID]: signs in to an MCP server on the web, in your browser, and keeps the token
  let url = if args.len > 1: args[1] else: ""
  if not (url.startsWith("https://") or url.startsWith("http://")):
    echo "ned --mcp-login URL [CLIENT-ID]: sign in to an MCP server on the web (ai.mcpServers' \"url\"), in the browser"
    return 2
  if findExe("curl").len == 0:
    echo "ned --mcp-login needs curl"
    return 1
  # 1. the server says where to sign in (a 401 with its metadata's address), or that it needs no sign-in
  let probe = """{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ned","version":"""" & Version & """"}}}"""
  let (st0, _, heads0) = mcpFetch("POST", url, probe, "application/json", "application/json, text/event-stream")
  if st0 == 0:
    echo "Cannot reach " & url
    return 1
  if st0 >= 200 and st0 < 300:
    echo url & " lets ned in without signing in: nothing to do"
    return 0
  var meta = mcpHeaderParam(heads0, "WWW-Authenticate", "resource_metadata")
  var scope = mcpHeaderParam(heads0, "WWW-Authenticate", "scope")
  let origin = mcpOrigin(url)
  let path = url[origin.len .. ^1].strip(leading = false, chars = {'/'})
  var issuer = ""
  var rm: JsonNode
  for m in [meta, origin & "/.well-known/oauth-protected-resource" & path, origin & "/.well-known/oauth-protected-resource"]:
    if m.len == 0: continue
    rm = mcpJsonGet(m)
    if rm != nil: break
  if rm != nil:
    if rm{"authorization_servers"} != nil and rm["authorization_servers"].kind == JArray and rm["authorization_servers"].len > 0:
      issuer = rm["authorization_servers"][0].getStr
    if scope.len == 0 and rm{"scopes_supported"} != nil and rm["scopes_supported"].kind == JArray:
      var ss: seq[string]
      for x in rm["scopes_supported"]: ss.add x.getStr
      scope = ss.join(" ")
  if issuer.len == 0: issuer = origin            # (an older server: the sign-in service is the server itself)
  # 2. the sign-in service: where its page and its tokens are
  let io = mcpOrigin(issuer)
  let ip = issuer[io.len .. ^1].strip(leading = false, chars = {'/'})
  var asMeta: JsonNode
  for m in [io & "/.well-known/oauth-authorization-server" & ip, io & "/.well-known/openid-configuration" & ip,
            issuer.strip(leading = false, chars = {'/'}) & "/.well-known/openid-configuration"]:
    asMeta = mcpJsonGet(m)
    if asMeta != nil and asMeta{"authorization_endpoint"}.getStr.len > 0 and asMeta{"token_endpoint"}.getStr.len > 0: break
    asMeta = nil
  if asMeta == nil:
    echo "Could not find where " & url & " signs people in (its OAuth metadata, at " & issuer & ")"
    return 1
  # 3. a port here for the answer, and ned registered with the service (or the client id you gave)
  let (ls, port) = mcpLoginListen()
  if ls < 0:
    echo "Could not listen on 127.0.0.1 for the browser's answer"
    return 1
  defer: discard posix.close(ls)
  let redirect = "http://127.0.0.1:" & $port & "/callback"
  var clientId = if args.len > 2: args[2] else: getEnv("NED_MCP_CLIENT_ID")
  var clientSecret = ""
  if clientId.len == 0:
    let reg = asMeta{"registration_endpoint"}.getStr
    if reg.len == 0:
      echo "This server does not let ned register itself: give its client id — ned --mcp-login URL CLIENT-ID (or " &
           "\"clientId\" in its ai.mcpServers entry)"
      return 1
    let (st, body, _) = mcpFetch("POST", reg, $(%*{"client_name": "ned", "redirect_uris": [redirect],
                                 "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                                 "token_endpoint_auth_method": "none"}), "application/json")
    var r: JsonNode
    try: r = parseJson(body)
    except CatchableError: r = nil
    if st < 200 or st >= 300 or r == nil or r.kind != JObject or r{"client_id"}.getStr.len == 0:
      echo "The server would not register ned (HTTP " & $st & "): " & body.strip.splitLines()[0 .. ^1].join(" ")[0 ..< min(200, body.len)]
      return 1
    clientId = r["client_id"].getStr
    clientSecret = r{"client_secret"}.getStr
  # 4. your browser to the sign-in page (PKCE: only this ned can trade its answer for a token)
  let verifier = mcpRandom(32)
  var c = sha256Init()
  c.sha256Update(verifier)
  let d = c.sha256Final()
  var raw = newString(32)
  for i in 0 ..< 32: raw[i] = char(d[i])
  let state = mcpRandom(16)
  let ae = asMeta["authorization_endpoint"].getStr
  let page = ae & (if '?' in ae: "&" else: "?") & mcpForm([("response_type", "code"), ("client_id", clientId),
    ("redirect_uri", redirect), ("code_challenge", mcpB64Url(raw)), ("code_challenge_method", "S256"),
    ("state", state), ("resource", url), ("scope", scope)])
  echo "Signing in to " & url
  echo "Your browser opens the sign-in page. If it does not, open this address:"
  echo ""
  echo "  " & page
  echo ""
  for opener in ["termux-open-url", "xdg-open", "open", "wslview"]:
    if findExe(opener).len > 0:
      try: discard spawnProc(@[opener, page], getHomeDir())
      except CatchableError: discard
      break
  let (code, why) = mcpLoginWait(ls, state, 300)
  if code.len == 0:
    echo "Not signed in: " & why
    return 1
  # 5. the answer traded for the tokens, kept
  let a = %*{"url": url, "token_endpoint": asMeta["token_endpoint"].getStr, "client_id": clientId,
             "client_secret": clientSecret, "issuer": issuer}
  if not mcpAuthTokens(url, a, mcpForm([("grant_type", "authorization_code"), ("code", code),
                                        ("redirect_uri", redirect), ("client_id", clientId),
                                        ("client_secret", clientSecret), ("code_verifier", verifier),
                                        ("resource", url)])):
    echo "The sign-in service did not give a token for the answer"
    return 1
  echo "Signed in. ned (and the agents it starts) use " & url & " with this sign-in from now on; the token is kept " &
       "in " & mcpAuthFile(url) & " (only you may read it)."
  0

proc cmdMcpSignIn() =
  ## MCP: sign in to a server… — the servers on the web (ai.mcpServers' "url"): one chosen signs in, in a terminal
  ## (ned --mcp-login: the browser opens, the terminal says what happens); one signed in to can also be signed out of
  let all = settingNode("ai.mcpServers")
  var items: seq[(string, string, Action)]
  if all != nil and all.kind == JObject:
    for name, sp in all:
      if sp.kind != JObject or sp{"url"}.getStr.len == 0: continue
      let url = sp{"url"}.getStr
      let cid = sp{"clientId"}.getStr
      let signed = mcpAuthLoad(url) != nil
      capture url, cid, name:
        items.add act("Sign in: " & name, url & (if signed: " · signed in" else: ""), proc() =
          newTerminal()
          let t = curTermObj()
          if t != nil:
            t.pending = quoteShell(getAppFilename()) & " --mcp-login " & quoteShell(url) &
                        (if cid.len > 0: " " & quoteShell(cid) else: "") & "\r")
        if signed:
          items.add act("Sign out: " & name, "its token forgotten", proc() =
            try:
              removeFile(mcpAuthFile(url))
              info("Signed out of " & name)
            except CatchableError as e: error(e.msg))
  if items.len == 0:
    info("No MCP server on the web in ai.mcpServers — {\"linear\": {\"url\": \"https://mcp.linear.app/mcp\"}}")
    return
  openActions("MCP servers on the web", items)
