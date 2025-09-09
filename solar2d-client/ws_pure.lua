-- ws_pure.lua  (minimal WebSocket client for ws:// using LuaSocket)
--
-- Goals
--  • No native plugins. Works inside Solar2D (Lua 5.1) and plain LuaSocket
--  • Client text frames only (masking required). Server frames (unmasked)
--  • Handshake, send(), update() to pump incoming frames, close()
--  • Simple event API: addEventListener("open"|"message"|"close"|"error", fn)
--  • Optional enterFrame auto-pump when Solar2D Runtime is present
--
-- Limits
--  • No TLS (use ws:// only)
--  • No fragmented messages, no extensions, text only, payload <= 2^32-1
--
-- Usage:
--    local WS = require("ws_pure")
--    local ws = WS.new()
--    ws:addEventListener("message", function(e) print("got:", e.data) end)
--    ws:connect("ws://127.0.0.1:8080/ws")
--    -- call ws:update() periodically (or ws:autoPump(true) in Solar2D)

local socket = require("socket")
local ok_mime, mime = pcall(require, "mime") -- for base64; LuaSocket provides this

-- seed RNG once (Solar2D/Lua 5.1 friendly)
do
  local seeded = rawget(_G, "__ws_pure_seeded")
  if not seeded then
    local t = os.time()
    local addr = tonumber(tostring({}):match("0x(%x+)"), 16) or 0
    math.randomseed((t % 0xFFFFFFFF) + addr)
    _G.__ws_pure_seeded = true
  end
end

-- tiny pure-Lua base64 (fallback if LuaSocket's mime.b64 is unavailable)
local __b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64encode(data)
  local bytes = { data:byte(1, #data) }
  local out = {}
  for i = 1, #bytes, 3 do
    local b1 = bytes[i] or 0
    local b2 = bytes[i+1] or 0
    local b3 = bytes[i+2] or 0
    local n = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096)   % 64
    local c3 = math.floor(n / 64)     % 64
    local c4 = n % 64
    out[#out+1] = __b64chars:sub(c1+1, c1+1)
    out[#out+1] = __b64chars:sub(c2+1, c2+1)
    out[#out+1] = (i+1 <= #bytes) and __b64chars:sub(c3+1, c3+1) or "="
    out[#out+1] = (i+2 <= #bytes) and __b64chars:sub(c4+1, c4+1) or "="
  end
  return table.concat(out)
end

local M = {}
M.VERSION = "0.2"

----------------------------------------------------------------
-- small helpers
----------------------------------------------------------------
local function parseUrl(url)
  -- supports: ws://host[:port][/path]
  local host, port, path
  host, port, path = url:match("^ws://([^:/]+):(%d+)(/.*)$")
  if not host then
    host, path = url:match("^ws://([^/]+)(/.*)$")
  end
  if not host then
    host = url:match("^ws://([^/]+)$")
  end
  path = path or "/"
  if not port then
    port = host:match(":(%d+)$")
    if port then host = host:gsub(":"..port.."$", "") end
  end
  port = tonumber(port) or 80
  return host, port, path
end

local function randbytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0,255)) end
  return table.concat(t)
end

-- portable bxor for Lua 5.1
local function bxor(a, b)
  local res, p = 0, 1
  while a > 0 or b > 0 do
    local abit = a % 2; local bbit = b % 2
    if abit ~= bbit then res = res + p end
    a = (a - abit) / 2; b = (b - bbit) / 2; p = p * 2
  end
  return res
end

local function maskPayload(maskKey, payload)
  local out = {}
  local m = { maskKey:byte(1,4) }
  for i = 1, #payload do
    local pb = payload:byte(i)
    local mb = m[((i - 1) % 4) + 1]
    out[i] = string.char(bxor(pb, mb))
  end
  return table.concat(out)
end

local function u16(n)
  local hi = math.floor(n / 256) % 256
  local lo = n % 256
  return string.char(hi, lo)
end

local function u64_from_len(len)
  -- pack 64-bit BE, but we only support up to 2^32-1
  local b4 = math.floor(len / 16777216) % 256 -- >> 24
  local b3 = math.floor(len / 65536)   % 256 -- >> 16
  local b2 = math.floor(len / 256)     % 256 -- >> 8
  local b1 = len % 256
  return string.char(0,0,0,0, b4, b3, b2, b1)
end

local function buildFrame(payload, opcode)
  -- client -> server MUST be masked
  opcode = opcode or 0x1 -- text
  local b1 = string.char(0x80 + (opcode % 16))
  local len = #payload
  local maskKey = randbytes(4)
  local header
  if len < 126 then
    header = b1 .. string.char(0x80 + len)
  elseif len < 65536 then
    header = b1 .. string.char(0x80 + 126) .. u16(len)
  else
    header = b1 .. string.char(0x80 + 127) .. u64_from_len(len)
  end
  return header .. maskKey .. maskPayload(maskKey, payload)
end

local function buildPong(payload)
  payload = payload or ""
  return buildFrame(payload, 0xA) -- opcode 10 = pong
end

local function parseFrame(buf)
  -- returns: tbl, consumed   where tbl = { opcode=1|8|9|10, data=string, code=?, reason=? }
  local n = #buf
  if n < 2 then return nil, 0 end
  local b1 = buf:byte(1)
  local b2 = buf:byte(2)
  local fin = (b1 >= 0x80)
  local opcode = b1 % 16
  local masked = (b2 >= 0x80)
  local len7 = b2 % 128
  local idx = 3
  local payloadLen
  if len7 < 126 then
    payloadLen = len7
  elseif len7 == 126 then
    if n < 4 then return nil, 0 end
    local b3, b4 = buf:byte(3,4)
    payloadLen = b3 * 256 + b4
    idx = 5
  else -- 127
    if n < 10 then return nil, 0 end
    local b3,b4,b5,b6,b7,b8,b9,b10 = buf:byte(3,10)
    -- high 32 bits ignored
    payloadLen = ((b7 * 256 + b8) * 256 + b9) * 256 + b10
    idx = 11
  end
  local maskKey = nil
  if masked then
    if n < idx + 3 then return nil, 0 end
    maskKey = buf:sub(idx, idx + 3)
    idx = idx + 4
  end
  if n < idx + payloadLen - 1 then return nil, 0 end
  local payload = buf:sub(idx, idx + payloadLen - 1)
  if masked and payloadLen > 0 then
    payload = maskPayload(maskKey, payload)
  end
  local consumed = idx + payloadLen - 1
  local frame = { opcode = opcode, fin = fin, data = payload }
  if opcode == 0x8 and payloadLen >= 2 then -- close
    local c1, c2 = payload:byte(1,2)
    frame.code = c1 * 256 + c2
    frame.reason = payloadLen > 2 and payload:sub(3) or ""
  end
  return frame, consumed
end

----------------------------------------------------------------
-- client object
----------------------------------------------------------------
local Client = {}
Client.__index = Client

function Client:_fire(name, evt)
  local lst = self._listeners[name]
  if not lst then return end
  for i = 1, #lst do
    local ok, err = pcall(lst[i], evt)
    if not ok then
      -- best effort: also report via error listeners
      local el = self._listeners.error
      if el and #el > 0 then
        for j = 1, #el do pcall(el[j], { message = tostring(err) }) end
      end
    end
  end
end

function Client:addEventListener(name, fn)
  if type(fn) ~= "function" then return end
  local lst = self._listeners[name]
  if not lst then lst = {}; self._listeners[name] = lst end
  lst[#lst+1] = fn
end

function Client:autoPump(on)
  -- Solar2D convenience: attach/detach Runtime enterFrame to call :update()
  if _G.Runtime and _G.Runtime.addEventListener then
    if on and not self._autoPump then
      self._autoPump = function() self:update() end
      _G.Runtime:addEventListener("enterFrame", self._autoPump)
    elseif (not on) and self._autoPump then
      _G.Runtime:removeEventListener("enterFrame", self._autoPump)
      self._autoPump = nil
    end
  end
end

function Client:connect(urlOr)
  if self.sock then self:close() end
  local url = urlOr
  if type(urlOr) == "table" then url = urlOr.url end
  assert(type(url) == "string" and url:match("^ws://"), "ws_pure: only ws:// URLs supported")

  local host, port, path = parseUrl(url)
  local tcp = assert(socket.tcp())
  tcp:settimeout(5)
  local ok, err = tcp:connect(host, port)
  if not ok and err then
    self:_fire("error", { message = "connect failed: "..tostring(err) })
    return false
  end

  -- Handshake
  local key
  if ok_mime and mime and mime.b64 then
    key = mime.b64(randbytes(16))
  else
    -- RFC requires base64 of 16 random bytes; use pure-Lua fallback
    key = base64encode(randbytes(16))
  end

  local req = table.concat({
    "GET "..path.." HTTP/1.1",
    "Host: "..host..":"..tostring(port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: "..key,
    "Sec-WebSocket-Version: 13",
    "\r\n"
  }, "\r\n")

  local ok2, err2 = tcp:send(req)
  if not ok2 then
    self:_fire("error", { message = "handshake send failed: "..tostring(err2) })
    tcp:close(); return false
  end

  -- Read headers until blank line
  local headers = {}
  while true do
    local line, e = tcp:receive("*l")
    if not line then
      self:_fire("error", { message = "handshake recv failed: "..tostring(e) })
      tcp:close(); return false
    end
    if line == "" then break end
    headers[#headers+1] = line
    if #headers == 1 and not line:find("101") then
      self:_fire("error", { message = "handshake HTTP not 101: "..line })
      tcp:close(); return false
    end
  end

  tcp:settimeout(0) -- non-blocking now
  self.sock = tcp
  self.recv = ""
  self.isOpen = true
  self:_fire("open", {})
  return true
end

function Client:send(text)
  if not (self.sock and self.isOpen) then return false, "not open" end
  local frame = buildFrame(tostring(text or ""), 0x1)
  local ok, err = self.sock:send(frame)
  if not ok then
    self:_fire("error", { message = tostring(err) })
    return false, err
  end
  return true
end

function Client:_readAvailable()
  if not self.sock then return end
  while true do
    local chunk, err, partial = self.sock:receive(4096)
    local s = chunk or partial
    if s and #s > 0 then
      self.recv = self.recv .. s
    end
    if err == "timeout" then
      break
    elseif err == "closed" then
      self.isOpen = false
      self:_fire("close", { code = 1006, reason = "socket closed" })
      self:close()
      return
    elseif not err then
      -- keep looping; may still have more
    else
      -- unknown error
      break
    end
  end
end

function Client:update()
  if not self.sock then return end
  self:_readAvailable()
  while true do
    local frame, consumed = parseFrame(self.recv)
    if not frame or consumed == 0 then break end
    self.recv = self.recv:sub(consumed + 1)

    if frame.opcode == 0x1 then -- text
      self:_fire("message", { data = frame.data })
    elseif frame.opcode == 0x8 then -- close
      local code = frame.code or 1000
      local reason = frame.reason or ""
      self.isOpen = false
      self:_fire("close", { code = code, reason = reason })
      self:close()
      break
    elseif frame.opcode == 0x9 then -- ping -> pong
      if self.sock then self.sock:send(buildPong(frame.data or "")) end
    elseif frame.opcode == 0xA then
      -- pong, ignore
    else
      -- other opcodes ignored
    end
  end
end

function Client:close()
  if self.sock then
    pcall(function() self.sock:close() end)
    self.sock = nil
  end
  self.isOpen = false
  self.recv = ""
end

----------------------------------------------------------------
-- factory
----------------------------------------------------------------
function M.new()
  local self = setmetatable({
    sock = nil,
    recv = "",
    isOpen = false,
    _listeners = {
      open = {},
      message = {},
      close = {},
      error = {},
    }
  }, Client)
  return self
end

return M
