-- main.lua — WS first (official plugin), legacy fallback, HTTP poll as safety net
display.setStatusBar(display.HiddenStatusBar)

local json = require("json")


-- Localize engine + stdlib globals we actually use (quiet linter + faster lookups)
---@diagnostic disable-next-line: undefined-global
local display = display
---@diagnostic disable-next-line: undefined-global
local native = native
---@diagnostic disable-next-line: undefined-global
local network = network
---@diagnostic disable-next-line: undefined-global
local timer = timer
---@diagnostic disable-next-line: undefined-global
local transition = transition
---@diagnostic disable-next-line: undefined-global
local Runtime = Runtime

local os = os
local math = math
local table = table
local tostring = tostring
local type = type
local select = select
local print = print

-- Lua 5.1/5.3 compatibility: provide `unpack` locally (used by badge())
local unpack = unpack or table.unpack

---@class WebSocket
---@field connect fun(self: WebSocket, ...): any
---@field open fun(self: WebSocket, ...): any
---@field close fun(self: WebSocket): any
---@field setUrl fun(self: WebSocket, url: string)
---@field addEventListener fun(self: WebSocket, event: any|string, listener: fun(e: table))

---@class WebSocketLib
---@field EVENT any
---@field new fun(...): WebSocket

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
-- CHANGE THIS to your Windows machine's LAN IP when testing on a real iPhone:
local HOST = "192.168.1.xx"
local PORT = 8080
local BASE  = ("http://%s:%d"):format(HOST, PORT)
local WSURL = ("ws://%s:%d/ws"):format(HOST, PORT)

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local playerId = nil
local ws, wsOpen = nil, false

---@type WebSocketLib|nil
local WSLib

do
  local ok1, mod = pcall(require, "plugin.websocket")      -- singular (official)
  if ok1 then
    WSLib = mod
  else
    local ok2, mod2 = pcall(require, "plugin.websockets")  -- legacy
    if ok2 then WSLib = mod2 end
  end
end

local wsPluginOk = WSLib ~= nil

local _wsTryIndex, wsBackoffMs = 0, 600  -- exponential backoff cap handled below

-- polling fallback
local polling, pollTimer, lastEventId = false, nil, 0

-- transport selector: "AUTO" (WS→POLL), "WS" (WS only), "POLL" (HTTP only)
local transportMode = "AUTO"

----------------------------------------------------------------
-- UTIL / LOGGING / TOAST
----------------------------------------------------------------
local function safeEncode(t)
  local ok2, txt = pcall(json.encode, t)
  return ok2 and txt or "null"
end

local function safeDecode(s)
  if type(s) ~= "string" or #s == 0 then return nil end
  local ok2, obj = pcall(json.decode, s)
  return ok2 and obj or nil
end

local logBox
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[#parts+1] = (type(v) == "table") and safeEncode(v) or tostring(v)
  end
  local line = table.concat(parts, " ")
  print(line)
  if logBox then
    logBox.text = (logBox.text or "") .. line .. "\n"
    logBox:setSelection(#logBox.text, #logBox.text)
  end
end

local function toast(text)
  local g = display.newGroup()
  local w = math.min(display.contentWidth - 40, 320)
  local t = display.newText({
    text = tostring(text or ""),
    x = display.contentCenterX,
    y = display.contentCenterY - 130,
    font = native.systemFontBold,
    fontSize = 14,
    width = w - 24,
    align = "center"
  })
  t:setFillColor(1,1,1)
  local r = display.newRoundedRect(t.x, t.y, math.max(80, t.width + 24), t.height + 16, 10)
  r:setFillColor(0,0,0)
  r.alpha = 0.82
  g:insert(r)
  g:insert(t)
  transition.to(g, { delay = 1200, time = 2200, alpha = 0, onComplete = function() display.remove(g) end })
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------
local function SafeArea()
  return display.safeScreenOriginX, display.safeScreenOriginY,
         display.safeActualContentWidth, display.safeActualContentHeight
end

local function badge(label, color, x, y)
  local g = display.newGroup()
  local t = display.newText({ text = label, x = x, y = y, font = native.systemFontBold, fontSize = 12 })
  t:setFillColor(1,1,1)
  local r = display.newRoundedRect(t.x, t.y, t.width + 20, t.height + 6, 8)
  r:setFillColor(unpack(color))
  g:insert(r)
  g:insert(t)
  function g:set(on) r:setFillColor(unpack(on and color or {0.25,0.25,0.28})) end
  g:set(false)
  return g
end

local function newBtn(label, centerY, onTap)
  local g = display.newGroup()
  g.enabled = true
  local t = display.newText({ text = label, x = display.contentCenterX, y = centerY,
                              font = native.systemFontBold, fontSize = 18 })
  t:setFillColor(1,1,1)
  local r = display.newRoundedRect(t.x, t.y, t.width + 24, t.height + 12, 12)
  r:setFillColor(0.20, 0.38, 0.75)
  g:insert(r)
  g:insert(t)
  function g:setEnabled(b)
    g.enabled = b and true or false
    g.alpha = g.enabled and 1 or 0.45
  end
  local touching = false
  g:addEventListener("touch", function(e)
    if e.phase == "began" then
      display.getCurrentStage():setFocus(g)
      touching = true
      g.xScale, g.yScale = 0.98, 0.98
    elseif e.phase == "ended" or e.phase == "cancelled" then
      display.getCurrentStage():setFocus(nil)
      g.xScale, g.yScale = 1, 1
      if touching and g.enabled and onTap then onTap() end
      touching = false
    end
    return true
  end)
  return g
end

-- header + console (custom bg so we avoid 'hasBackground' warnings on macOS)
do
  local sx, sy, sw, sh = SafeArea()
  local title = display.newText({
    text = "Solar2D ↔ Java Backend",
    x = display.contentCenterX, y = sy + 22,
    font = native.systemFontBold, fontSize = 18
  })
  local sub = display.newText({
    text = ("%s  •  %s"):format(BASE, WSURL),
    x = display.contentCenterX, y = title.y + 18,
    font = native.systemFont, fontSize = 12
  })
  sub:setFillColor(0.8,0.8,0.9)

  local bg = display.newRoundedRect(display.contentCenterX, sy + sh - 120, sw - 20, 180, 8)
  bg:setFillColor(0.08, 0.08, 0.1)
  bg.alpha = 0.9

  logBox = native.newTextBox(display.contentCenterX, sy + sh - 120, sw - 24, 172)
  logBox.isEditable = false
  logBox.size = 12
  logBox.font = native.newFont("Courier New", 12)
end

local httpBadge = badge("HTTP", {0.10, 0.65, 0.35}, display.contentCenterX - 80, display.contentCenterY - 90)
local wsBadge   = badge("WS",   {0.10, 0.50, 0.85}, display.contentCenterX - 20, display.contentCenterY - 90)
local modeText  = display.newText({ text = "AUTO", x = display.contentCenterX + 60, y = display.contentCenterY - 90,
                                    font = native.systemFontBold, fontSize = 12 })
modeText:setFillColor(0.9,0.9,0.9)

local function setHttp(ok) httpBadge:set(ok) end
local function setWs(ok)
  wsBadge:set(ok)
  wsOpen = ok and true or false
end
local function setModeText() modeText.text = transportMode end

modeText:addEventListener("tap", function()
  transportMode = (transportMode == "AUTO" and "WS") or (transportMode == "WS" and "POLL") or "AUTO"
  setModeText()
  toast("Transport: " .. transportMode)
  -- stop any active channel when switching
  if polling then
    polling = false
    if pollTimer then
      timer.cancel(pollTimer)
      pollTimer = nil
    end
  end
  if ws and ws.close then
    pcall(function() ws:close() end)
  end
  setWs(false)
  return true
end)
setModeText()

----------------------------------------------------------------
-- HTTP helper
----------------------------------------------------------------
local function http(method, path, body, cb)
  if type(path) ~= "string" then
    log("HTTP path not string; abort")
    return
  end
  local url = BASE .. path
  local params = { headers = { ["Content-Type"] = "application/json" } }
  if body ~= nil then params.body = safeEncode(body) end
  network.request(url, method, function(event)
    if event.isError then
      log("HTTP error", method, path, "status:", tostring(event.status))
      setHttp(false)
      if cb then cb(nil, event) end
      return
    end
    setHttp(true)
    if cb then cb(safeDecode(event.response), event) end
  end, params)
end

----------------------------------------------------------------
-- POLLING FALLBACK
----------------------------------------------------------------
local function handleIncoming(msg)
  if not msg then return end
  if msg.type == "server" then
    local text = (type(msg.payload) == "table" and (msg.payload.text or safeEncode(msg.payload)))
                  or tostring(msg.payload or "")
    toast(text ~= "" and text or "Server message")
    log("POLL message:", text)
  elseif msg.type == "progress" then
    toast(("Progress: L%d  XP%d"):format(msg.level or 0, msg.xp or 0))
    log("POLL progress:", msg)
  else
    log("POLL unknown:", msg)
  end
end

local function pollOnce()
  http("GET", "/api/events/poll?after=" .. tostring(lastEventId), nil, function(data)
    if not data or not data.events then return end
    for i = 1, #data.events do
      local ev = data.events[i]
      lastEventId = math.max(lastEventId, ev.id or lastEventId)
      handleIncoming(ev.data or ev)
    end
  end)
end

local function stopPolling()
  polling = false
  if pollTimer then
    timer.cancel(pollTimer)
    pollTimer = nil
  end
end

local function startPolling()
  if polling then return end
  polling = true
  toast("Realtime via HTTP (WS unavailable)")
  log("Polling enabled")
  pollTimer = timer.performWithDelay(1200, function()
    if polling then pollOnce() end
  end, 0)
end

----------------------------------------------------------------
-- ACTIONS (login/save/broadcast)
----------------------------------------------------------------
local function doLogin()
  http("POST", "/api/login", { email = "test@demo", password = "x" }, function(data)
    if data and data.playerId then
      playerId = data.playerId
      log("Logged in with playerId:", playerId)
      toast("Logged in")
    else
      log("Login failed / bad JSON:", data or "<nil>")
    end
  end)
end

----------------------------------------------------------------
-- WebSocket (multi-strategy, backoff, crash-proof)
----------------------------------------------------------------
local function wsUnifiedHandler(e)
  local t = e and (e.type or e.name)
  if     t == "open" then
    stopPolling()
    setWs(true)
    wsBackoffMs = 600
    log("WS open")
    toast("WebSocket connected")
  elseif t == "message" then
    log("WS message:", e and e.data or "<nil>")
    local msg = safeDecode(e and e.data or "")
    if msg and msg.type == "server" then
      local text = (type(msg.payload) == "table" and (msg.payload.text or safeEncode(msg.payload)))
                    or tostring(msg.payload or "")
      toast(text ~= "" and text or "Server message")
    elseif msg and msg.type == "progress" then
      toast(("Progress: L%d  XP%d"):format(msg.level or 0, msg.xp or 0))
    end
  elseif t == "close" then
    setWs(false)
    log("WS closed", e and e.code or "", e and e.reason or "")
    if transportMode ~= "WS" then startPolling() end
  elseif t == "error" then
    setWs(false)
    log("WS error:", (e and (e.errorMessage or e.reason)) or "unknown")
    if transportMode ~= "WS" then startPolling() end
  else
    log("WS event:", tostring(t))
  end
end

local function hookWsEvents()
  if not ws or not ws.addEventListener then return end
  if WSLib and WSLib.EVENT then
    ws:addEventListener(WSLib.EVENT, wsUnifiedHandler)
  else
    ws:addEventListener("open",    wsUnifiedHandler)
    ws:addEventListener("message", wsUnifiedHandler)
    ws:addEventListener("close",   wsUnifiedHandler)
    ws:addEventListener("error",   wsUnifiedHandler)
  end
end

-- Strategies across plugin versions:
-- 1) new(WSURL); connect()
-- 2) new();      connect(WSURL)
-- 3) new({url=WSURL}); connect()
-- 4) new();      connect({url=WSURL})
-- 5) new();      setUrl(WSURL); connect()
local STRATS = { 1, 2, 3, 4, 5 }

local function connectWithStrategy(idx)
  _wsTryIndex = idx
  local mode = STRATS[idx]
  log(("WS try %d"):format(mode))
  wsOpen = false
  ws = nil

  local okNew, inst
  if mode == 1 then
    okNew, inst = pcall(function() return WSLib.new(WSURL) end)
  elseif mode == 2 or mode == 4 or mode == 5 then
    okNew, inst = pcall(function() return WSLib.new() end)
  elseif mode == 3 then
    okNew, inst = pcall(function() return WSLib.new({ url = WSURL }) end)
  end

  if not okNew or not inst then
    log("WS new() failed:", tostring(inst))
    if idx < #STRATS then
      return timer.performWithDelay(200, function() connectWithStrategy(idx + 1) end)
    else
      log("WS: all strategies failed")
      setWs(false)
      if transportMode ~= "WS" then startPolling() end
      return
    end
  end

  ws = inst
  hookWsEvents()

  local okConn, err = pcall(function()
    if mode == 1 then
      return (ws.connect and ws:connect()) or (ws.open and ws:open())
    elseif mode == 2 then
      if ws.connect then return ws:connect(WSURL) end
      if ws.open    then return ws:open(WSURL)    end
    elseif mode == 3 then
      return (ws.connect and ws:connect()) or (ws.open and ws:open())
    elseif mode == 4 then
      if ws.connect then return ws:connect({ url = WSURL }) end
      if ws.open    then return ws:open({ url = WSURL })    end
    elseif mode == 5 then
      if ws.setUrl then ws:setUrl(WSURL) end
      return (ws.connect and ws:connect()) or (ws.open and ws:open())
    end
    error("No connect/open method")
  end)

  if not okConn then
    log("WS connect threw:", tostring(err))
    if idx < #STRATS then
      return timer.performWithDelay(200, function() connectWithStrategy(idx + 1) end)
    else
      log("WS: all strategies failed")
      setWs(false)
      if transportMode ~= "WS" then startPolling() end
      return
    end
  end

  -- If no 'open' in 1600ms, try next strategy (or backoff + poll)
  timer.performWithDelay(1600, function()
    if not wsOpen then
      log("WS no 'open' yet; trying alt path")
      if idx < #STRATS then
        connectWithStrategy(idx + 1)
      else
        log("WS failed; backoff ".. wsBackoffMs .."ms then retry (AUTO/WS modes)")
        if transportMode ~= "POLL" then
          timer.performWithDelay(wsBackoffMs, function()
            wsBackoffMs = math.min(wsBackoffMs * 2, 1000)
            if transportMode == "AUTO" then startPolling() end
            connectWithStrategy(1)
          end)
        else
          startPolling()
        end
      end
    end
  end)
end

local function openWS()
  log("OpenWS tapped; mode=", transportMode, " pluginOk=", tostring(wsPluginOk), " url=", WSURL)
  if transportMode == "POLL" then
    startPolling()
    return
  end
  if not wsPluginOk then
    log("WS plugin not available; " .. (transportMode == "WS" and "WS-only mode selected." or "switching to HTTP."))
    if transportMode == "WS" then
      toast("WS plugin missing")
      return
    end
    startPolling()
    return
  end
  if wsOpen then
    log("WS already open")
    return
  end
  connectWithStrategy(1)
end

----------------------------------------------------------------
-- Save / Broadcast
----------------------------------------------------------------
local function saveProgress()
  if not playerId then log("Login first") ; toast("Login first") ; return end
  local lvl = math.random(2, 9)
  local xp  = math.random(100, 2000)
  http("POST", "/api/progress/" .. playerId, { level = lvl, xp = xp }, function(_)
    log("Progress saved: level=", lvl, "xp=", xp)
  end)
end

local function broadcastTest()
  http("POST", "/api/broadcast", { text = "hello from client", ts = os.time() }, function()
    log("Asked server to broadcast")
  end)
end

----------------------------------------------------------------
-- Layout / Buttons
----------------------------------------------------------------
local y = display.contentCenterY - 10
local _btnLogin = newBtn("1) Login",          y, doLogin)
y = y + 48
local _btnWS    = newBtn("2) Connect",        y, openWS)
y = y + 48
local _btnSave  = newBtn("3) Save Progress",  y, saveProgress)
y = y + 48
local _btnBC    = newBtn("4) Broadcast Test", y, broadcastTest)

setWs(false)
log("Ready. Server:", BASE, "WS:", WSURL)
log("Tap 1) Login, 2) Connect (mode: tap the right badge to cycle AUTO/WS/POLL), 3) Save, 4) Broadcast.")

----------------------------------------------------------------
-- System events: pause/resume → stop/start poll; retry WS
----------------------------------------------------------------
local function onSystem(e)
  if e.type == "applicationSuspend" then
    stopPolling()
  elseif e.type == "applicationResume" or e.type == "applicationStart" then
    if transportMode == "POLL" or (not wsPluginOk and transportMode ~= "WS") then
      startPolling()
    elseif transportMode ~= "POLL" then
      connectWithStrategy(1)
    end
  end
end
Runtime:addEventListener("system", onSystem)