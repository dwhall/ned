## SHA-1 (FIPS 180-4), for one thing only: the WebSocket handshake (RFC 6455), where the server answers the client's
## key with the SHA-1 of it and a fixed GUID — Claude Code talks to ned over a WebSocket. SHA-1 is not used for any
## check of content (ned's downloads are checked with SHA-256). Nim 2's standard library no longer has it.

import std/base64

func sha1Rotl(x: uint32, n: int): uint32 {.inline.} =
  ## a 32-bit number rotated left by n bits
  (x shl n) or (x shr (32 - n))

proc sha1*(s: string): array[20, byte] =
  ## the 20-byte SHA-1 of `s` (the whole string at once: what it is used for is short)
  var h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32, 0x10325476'u32, 0xC3D2E1F0'u32]
  var msg = s
  let bits = uint64(s.len) * 8
  msg.add '\x80'
  while msg.len mod 64 != 56: msg.add '\0'
  for i in countdown(7, 0): msg.add char((bits shr (i * 8)) and 0xff)
  var w: array[80, uint32]
  for blk in 0 ..< msg.len div 64:
    for i in 0 ..< 16:
      let o = blk * 64 + i * 4
      w[i] = (uint32(msg[o]) shl 24) or (uint32(msg[o + 1]) shl 16) or (uint32(msg[o + 2]) shl 8) or uint32(msg[o + 3])
    for i in 16 ..< 80: w[i] = sha1Rotl(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)
    var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
    for i in 0 ..< 80:
      var f, k: uint32
      if i < 20: (f, k) = ((b and c) or ((not b) and d), 0x5A827999'u32)
      elif i < 40: (f, k) = (b xor c xor d, 0x6ED9EBA1'u32)
      elif i < 60: (f, k) = ((b and c) or (b and d) or (c and d), 0x8F1BBCDC'u32)
      else: (f, k) = (b xor c xor d, 0xCA62C1D6'u32)
      let t = sha1Rotl(a, 5) + f + e + k + w[i]
      e = d; d = c; c = sha1Rotl(b, 30); b = a; a = t
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e
  for i in 0 ..< 5:
    for j in 0 ..< 4: result[i * 4 + j] = byte((h[i] shr (24 - j * 8)) and 0xff)

proc wsAccept*(key: string): string =
  ## the Sec-WebSocket-Accept a server answers the client's Sec-WebSocket-Key with
  let d = sha1(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  var raw = newString(20)
  for i in 0 ..< 20: raw[i] = char(d[i])
  encode(raw)
