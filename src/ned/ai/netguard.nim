# Copilot's telemetry refused (6.54, ai.copilotNoTelemetry): Copilot's language server reaches the network through a
# small proxy of ned's — `ned --net-guard HOST…`, a process of its own on 127.0.0.1 — that refuses the hosts named
# (copilot-telemetry.githubusercontent.com) and passes everything else on, through your own proxy when HTTPS_PROXY
# names one. It ends when ned does (its standard input closes).

const NetGuardBlocked = ["copilot-telemetry.githubusercontent.com"]

var
  ngProc: Proc                      # the guard ned started (pid -1: none)
  ngUrl = ""                        # where it listens ("" not started)
  ngTried = false

proc ngConnect(host: string, port: int): cint =
  ## a TCP connection to host:port, made at once (blocking: the guard is a process of its own); -1 when it fails
  when defined(windows): -1
  else:
    var hints: AddrInfo
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: ptr AddrInfo
    if getaddrinfo(host.cstring, cstring($port), addr hints, res) != 0 or res == nil: return -1
    result = -1
    var it = res
    while it != nil:
      let fd = posix.socket(it.ai_family, it.ai_socktype, it.ai_protocol)
      if fd.cint >= 0:
        if posix.connect(fd, it.ai_addr, it.ai_addrlen) == 0:
          result = fd.cint
          break
        discard posix.close(fd.cint)
      it = it.ai_next
    freeaddrinfo(res)

proc ngUnpercent(s: string): string =
  ## %XX in a URL's user and password as the bytes they stand for
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      result.add char(parseHexInt(s[i + 1 .. i + 2]))
      i += 3
    else:
      result.add s[i]
      inc i

proc ngUpstream(): (string, int, string) =
  ## your own proxy (HTTPS_PROXY / https_proxy): its host, its port, its Proxy-Authorization ("" none)
  var u = getEnv("HTTPS_PROXY", getEnv("https_proxy", getEnv("HTTP_PROXY", getEnv("http_proxy"))))
  if u.len == 0: return ("", 0, "")
  let s = u.find("://")
  if s >= 0: u = u[s + 3 .. ^1]
  u = u.split('/')[0]
  var auth = ""
  let at = u.rfind('@')
  if at >= 0:
    auth = "Basic " & encode(ngUnpercent(u[0 ..< at]))
    u = u[at + 1 .. ^1]
  let c = u.rfind(':')
  if c < 0: return (u, 80, auth)
  (u[0 ..< c], (try: parseInt(u[c + 1 .. ^1]) except ValueError: 80), auth)

proc netGuardMain(args: seq[string]): int =
  ## ned --net-guard HOST…: the proxy, on a free port of 127.0.0.1 (printed first, alone on its line); CONNECT and
  ## plain requests for the hosts named (and their subdomains) refused with 403, the rest passed on; it ends when its
  ## standard input does
  when defined(windows):
    stderr.writeLine("ned --net-guard: not on Windows")
    return 2
  else:
    var blocked: seq[string]
    for a in args:
      for h in a.split(','):
        if h.strip.len > 0: blocked.add h.strip.toLowerAscii
    let lfd = posix.socket(AF_INET, SOCK_STREAM, 0)
    var a: Sockaddr_in
    a.sin_family = TSa_Family(AF_INET)
    a.sin_port = 0
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    if lfd.cint < 0 or posix.bindSocket(lfd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) != 0 or
       posix.listen(lfd, 16) != 0:
      stderr.writeLine("ned --net-guard: no port on 127.0.0.1")
      return 1
    var alen = SockLen(sizeof(a))
    discard getsockname(lfd, cast[ptr SockAddr](addr a), addr alen)
    stdout.writeLine($ntohs(a.sin_port))
    stdout.flushFile()
    let (upHost, upPort, upAuth) = ngUpstream()
    type C = object
      c, u: cint
      head, toC, toU: string
      relay, closing: bool
    var cs: seq[C]
    proc refused(host: string): bool =
      ## a host named, or one of its subdomains
      let h = host.toLowerAscii.strip(chars = {'[', ']'})
      for b in blocked:
        if h == b or h.endsWith("." & b): return true
    proc flush(fd: cint, buf: var string): bool =
      ## what is waiting written to fd (false: it is gone)
      while buf.len > 0:
        let n = posix.write(fd, addr buf[0], buf.len)
        if n > 0: buf = buf[n .. ^1]
        elif n < 0 and errno in [EAGAIN, EWOULDBLOCK, EINTR]: return true
        else: return false
      true
    while true:
      var fds = @[TPollfd(fd: 0, events: POLLIN), TPollfd(fd: lfd.cint, events: POLLIN)]
      for x in cs:
        fds.add TPollfd(fd: x.c, events: POLLIN or (if x.toC.len > 0: POLLOUT else: 0))
        if x.u >= 0: fds.add TPollfd(fd: x.u, events: POLLIN or (if x.toU.len > 0: POLLOUT else: 0))
      if posix.poll(addr fds[0], Tnfds(fds.len), 30_000) < 0 and errno != EINTR: return 1
      if (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        var b: array[64, char]
        if posix.read(0, addr b[0], b.len) <= 0: return 0           # (ned is gone)
      if (fds[1].revents and POLLIN) != 0:
        let fd = posix.accept(lfd, nil, nil)
        if fd.cint >= 0:
          setNonBlock(fd.cint)
          cs.add C(c: fd.cint, u: -1)
      var buf: array[65536, char]
      for x in cs.mitems:
        if x.closing: continue
        # (from the client: its request first, then what it sends)
        let n = posix.read(x.c, addr buf[0], buf.len)
        if n == 0 or (n < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]): x.closing = true
        elif n > 0:
          var got = newString(n)
          copyMem(addr got[0], addr buf[0], n)
          if x.relay: x.toU.add got
          else:
            x.head.add got
            if x.head.len > 65536: x.closing = true
            let e = x.head.find("\r\n\r\n")
            if e >= 0 and not x.closing:
              let first = x.head[0 ..< x.head.find("\r\n")].splitWhitespace
              var host = ""
              var port = 443
              let connect = first.len >= 2 and first[0] == "CONNECT"
              if connect:
                let k = first[1].rfind(':')
                host = if k > 0: first[1][0 ..< k] else: first[1]
                if k > 0: port = (try: parseInt(first[1][k + 1 .. ^1]) except ValueError: 443)
              elif first.len >= 2 and first[1].startsWith("http://"):
                let hp = first[1][7 .. ^1].split('/')[0]
                let k = hp.rfind(':')
                host = if k > 0: hp[0 ..< k] else: hp
                port = if k > 0: (try: parseInt(hp[k + 1 .. ^1]) except ValueError: 80) else: 80
              if host.len == 0:
                x.toC = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                x.closing = true
              elif refused(host):
                stderr.writeLine("ned --net-guard: refused " & host)
                x.toC = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                x.closing = true
              else:
                x.u = if upHost.len > 0: ngConnect(upHost, upPort) else: ngConnect(host, port)
                if x.u < 0:
                  x.toC = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                  x.closing = true
                else:
                  setNonBlock(x.u)
                  x.relay = true
                  if upHost.len > 0:                    # (your proxy gets the request as it came, and answers it)
                    var h = x.head
                    if upAuth.len > 0:
                      h = h[0 ..< e] & "\r\nProxy-Authorization: " & upAuth & h[e .. ^1]
                    x.toU = h
                  elif connect:
                    x.toC = "HTTP/1.1 200 Connection established\r\n\r\n"
                    x.toU = x.head[e + 4 .. ^1]
                  else:                                 # (a plain request: its line with the path only)
                    let rest = first[1][7 .. ^1]
                    let sl = rest.find('/')
                    let path = if sl >= 0: rest[sl .. ^1] else: "/"
                    x.toU = first[0] & " " & path & " " & (if first.len > 2: first[2] else: "HTTP/1.1") &
                            x.head[x.head.find("\r\n") .. ^1]
                  x.head = ""
        if x.u >= 0 and not x.closing:
          let m = posix.read(x.u, addr buf[0], buf.len)
          if m == 0 or (m < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]): x.closing = true
          elif m > 0:
            let old = x.toC.len
            x.toC.setLen(old + m)
            copyMem(addr x.toC[old], addr buf[0], m)
        if x.u >= 0 and not flush(x.u, x.toU): x.closing = true
        if not flush(x.c, x.toC): x.closing = true
      var i = 0
      while i < cs.len:
        if cs[i].closing:
          discard flush(cs[i].c, cs[i].toC)                # (the last of it, a refusal: then both ends closed)
          discard posix.close(cs[i].c)
          if cs[i].u >= 0: discard posix.close(cs[i].u)
          cs.delete(i)
        else: inc i

proc netGuardStart(): string =
  ## the guard for Copilot (once; ai.copilotNoTelemetry): "http://127.0.0.1:PORT", or "" when it is off or did not
  ## start (then Copilot goes to the network as it did)
  if ngUrl.len > 0 or ngTried: return ngUrl
  ngTried = true
  when defined(windows): return ""
  else:
    if not sBool("ai.copilotNoTelemetry"): return ""
    try:
      ngProc = spawnProc(@[getAppFilename(), "--net-guard"] & @NetGuardBlocked, getHomeDir(), siPipe, erNull)
    except OSError: return ""
    var fds = @[TPollfd(fd: ngProc.outFd, events: POLLIN)]
    var line = ""
    let t0 = getMonoTime()
    while msSince(t0) < 3000 and '\n' notin line:
      if posix.poll(addr fds[0], 1, 200) > 0:
        var b: array[64, char]
        let n = posix.read(ngProc.outFd, addr b[0], b.len)
        if n <= 0: break
        for i in 0 ..< n: line.add b[i]
    let port = try: parseInt(line.strip) except ValueError: 0
    if port <= 0: return ""
    ngUrl = "http://127.0.0.1:" & $port
    ngUrl
