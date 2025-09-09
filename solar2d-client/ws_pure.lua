-- ws_pure.lua  (minimal WebSocket client for ws:// using LuaSocket)
-- Supports: connect, send text, receive text via update(), close
-- Notes: no TLS (use ws:// only), text frames only, single connection

local socket = require("socket")
local mime   = require("mime")       -- from LuaSocket (for base64)

local M = {}

local function parseUrl(url)
  -- ws://host:port/path
  local host, port, path = url:match("^ws://([^:/]+):?(%d*)(/.*)$")
  host = host or url:match("^ws://([^/]+)")
  path = path or "/"
  port = tonumber(port) or 80
  return host, port, path
end

local function randbytes(n)
  local t = {}
  for i=1,n do t[i] = string.char(math.random(0,255)) end
  return table.concat(t)
end

local function maskPayload(maskKey, payload)
  local out = {}
  local m1,m2,m3,m4 = maskKey:byte(1,4)
  local len = #payload
  for i=1,len do
    local pb = payload:byte(i)
    local mb = (i%4==1 and m1) or (i%4==2 and m2) or (i%4==3 and m3) or m4
    out[i] = string.char( (pb ~ mb) ) -- '~' is XOR in Lua 5.3+; for 5.1 we emulate:
  end
  return table.concat(out)
end

-- XOR fallback for Lua 5.1 (Solar2D)
if (string.char(1 ~ 1) ~= "\0") then
  local function bxor(a,b)
    local res, p = 0, 1
    while a>0 or b>0 do
      local abit = a%2; local bbit = b%2
      if abit ~= bbit then res = res + p end
      a = (a - abit)/2; b = (b - bbit)/2; p = p*2
    end
    return res
  end
  function maskPayload(maskKey, payload)
    local out = {}
    local m = {maskKey:byte(1,4)}
    for i=1,#payload do
      local pb = payload:byte(i)
      local mb = m[((i-1)%4)+1]
      out[i] = string.char(bxor(pb, mb))
    end
    return table.concat(out)
  end
end

local function buildTextFrame(payload)
  -- FIN+text opcode
  local b1 = string.char(0x80 + 0x1)
  local len = #payload
  local header
  local maskKey = randbytes(4)
  if len < 126 then
    header = b1 .. string.char(0x80 + len)
  elseif len < 65536 then
    header = b1 .. string.char(0x80 + 126) .. string.char((len >> 8) & 0xFF, len & 0xFF)
  else
    -- 64-bit (we only fill low 32 bits)
    header = b1 .. string.char(0x80 + 127) ..
      string.char(0,0,0,0, (len>>24)&0xFF, (len>>16)&0xFF, (len>>8)&0xFF, len&0xFF)
  end
  return header .. maskKey .. maskPayload(maskKey, payload)
end

local function parseFrame(buf)
  -- returns: frameOrNil, bytesConsumedOr0
  if #buf < 2 then retu
