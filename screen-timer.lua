-- screen-timer.lua — Hammerspoon module
-- Shows in the menu bar how long you've been on the CURRENT app + window,
-- resetting to 00:00 the moment you switch app, switch window (by real
-- window ID), or the window title changes (e.g. a browser tab switch).
-- Also logs every finished "stay" to a CSV so you can see your own
-- Gloria Mark stats (median / average stay) at the end of the day.
--
-- Install:
--   1. Install Hammerspoon:  brew install --cask hammerspoon   (or hammerspoon.org)
--   2. Copy this file to ~/.hammerspoon/screen-timer.lua
--   3. Add this line to ~/.hammerspoon/init.lua:
--        require("screen-timer")
--   4. Reload Hammerspoon config (menu bar icon > Reload Config)
--      Grant Accessibility permission when macOS asks — that's how it
--      reads the frontmost window title.
--
-- Click the menu bar item for: today's stays, median, average, longest,
-- and to open the CSV log.
--
-- Config (edit below): granularity = "app+window+title" (default) is the
-- closest match to Mark's "one screen": it resets on app switch, on a
-- real window switch (by window ID, even if two windows share a title),
-- and on a title change inside a window (which is how browser tabs show up).
-- "app+window" ignores title changes — no spurious resets from e.g.
-- "(2) Inbox", but browser tabs in one window blur together.
-- "app" resets only on app switch.
--
-- Chrome apps (bundle ID com.google.Chrome.app.* — e.g. Metamate 3):
-- their window title is EMPTY and session navigation inside the app
-- changes neither window ID nor title, so it was invisible in v2.
-- Verified by probe 2026-10-21: switching sessions (ds-clone ->
-- playground boss) changed only the AX title of the window's first
-- AXGroup. v3 therefore adds that AX title to the key (and the menu bar
-- label) for Chrome apps, in every granularity except "app".

local CONFIG = {
  granularity = "app+window+title", -- "app+window+title" | "app+window" | "app"
  logPath = os.getenv("HOME") .. "/screen-stays.csv",
  minLogSeconds = 2,           -- don't log accidental <2s flickers
  nameWidth = 18,              -- menu bar: name field is exactly this many
                               -- chars (padded, or cut with …). The clock
                               -- after it is never truncated. (v3.12)
}

local menubar = hs.menubar.new()
local startTime = os.time()
local currentKey, currentApp, currentTitle, currentWinId, currentAx = nil, "", "", "", ""
local staysToday = {}  -- records {sec, app, title, ax} for stays finished today

local function fmt(sec)
  if sec < 3600 then return string.format("%02d:%02d", sec // 60, sec % 60) end
  return string.format("%d:%02d:%02d", sec // 3600, (sec % 3600) // 60, sec % 60)
end

-- For Chrome apps only: find the session/page title hidden in the AX tree.
-- Probe-verified shape: AXWindow -> AXGroup with AXTitle = "<session> - ..."
-- BFS, depth <= 6, node-capped — the Metamate tree was only ~14 elements.
local function axAttr(el, name)
  local ok, v = pcall(function() return el:attributeValue(name) end)
  if ok then return v end
  return nil
end

-- BFS the window's AX tree; visit(el, depth) returns a string to stop with
-- that value, or nil to keep walking.
local function axWalk(win, visit)
  local okAX, ax = pcall(function() return hs.axuielement.windowElement(win) end)
  if not okAX or not ax then return "" end
  local queue, seen = { { ax, 0 } }, 0
  local head = 1
  while head <= #queue and seen < 300 do
    local el, depth = queue[head][1], queue[head][2]
    head = head + 1; seen = seen + 1
    local hit = visit(el, depth)
    if hit then return hit end
    if depth < 7 then
      local kids = axAttr(el, "AXChildren")
      if type(kids) == "table" then
        for _, k in ipairs(kids) do queue[#queue + 1] = { k, depth + 1 } end
      end
    end
  end
  return ""
end

-- Selected tab title for tabbed apps (iTerm2, Terminal.app): their tabs
-- live in an AXTabGroup of AXRadioButtons; the selected one carries the
-- tab's name. This is how tab switches inside one window become visible —
-- the window itself never changes. (v3.6)
local function selectedTabTitle(win)
  return axWalk(win, function(el)
    if axAttr(el, "AXRole") == "AXTabGroup" then
      local tabs = axAttr(el, "AXChildren")
      if type(tabs) == "table" then
        for _, tab in ipairs(tabs) do
          if axAttr(tab, "AXRole") == "AXRadioButton" then
            local sel = axAttr(tab, "AXSelected")
            local val = axAttr(tab, "AXValue")
            if sel == true or val == true or val == 1 then
              local t = axAttr(tab, "AXTitle")
              if type(t) == "string" and t ~= "" then return t end
            end
          end
        end
      end
    end
    return nil
  end)
end

local TAB_BUNDLES = { ["com.googlecode.iterm2"] = true, ["com.apple.Terminal"] = true }

local function axTitleFor(win, bundle)
  if bundle and TAB_BUNDLES[bundle] then
    local tab = selectedTabTitle(win)
    if tab ~= "" then return tab end
    -- fall through to generic title search if no tab group was found
  end
  return axWalk(win, function(el)
    local t = axAttr(el, "AXTitle")
    if type(t) == "string" and t ~= "" then return t end
    return nil
  end)
end

-- Debounced AX title. v3: raw AX title in the key — streaming UI made it
-- flap, timer reset every second and never counted up in PWA apps.
-- v3.1: required 3 *consecutive* identical polls — but AX reads in
-- Metamate intermittently return "" mid-stream, which kept resetting the
-- count, so real session switches were never accepted either.
-- v3.2: sightings-based. Empty/failed reads are ignored (they neither
-- accept nor reset a candidate). A candidate title seen twice within a
-- 5-second window is accepted as a session switch. A different
-- app/window is still accepted immediately. Accepted switches are
-- logged to ~/screen-timer-debug.log. All AX work is pcall-wrapped so
-- an AX error can never kill the 1s tick.
local stableAx, candAx, candHits, candExpires, axWinKey = "", "", 0, 0, ""
local function debouncedAx(win, winKey, bundle)
  if winKey ~= axWinKey then -- new window: accept immediately
    axWinKey = winKey
    local ok, raw = pcall(axTitleFor, win, bundle)
    stableAx = (ok and raw) or ""
    candAx, candHits = "", 0
    return stableAx
  end
  local ok, raw = pcall(axTitleFor, win, bundle)
  if not ok or raw == nil or raw == "" then
    if os.time() > candExpires then candAx, candHits = "", 0 end
    return stableAx
  end
  if raw == stableAx then candAx, candHits = "", 0; return stableAx end
  if raw == candAx then candHits = candHits + 1 else candAx, candHits = raw, 1 end
  candExpires = os.time() + 5
  if candHits >= 2 then
    local f = io.open(os.getenv("HOME") .. "/screen-timer-debug.log", "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") ..
      "AX session accepted: '" .. stableAx .. "' -> '" .. raw .. "'\n"); f:close() end
    stableAx = raw; candAx, candHits = "", 0
  end
  return stableAx
end

local function frontmost()
  local app = hs.application.frontmostApplication()
  if not app then return "", "", "", "", "" end
  local name = app:name() or ""
  local title, winId, axTitle = "", "", ""
  local win = app:focusedWindow()
  if win then
    title = win:title() or ""
    -- hs.window:id() is a stable per-window ID for the life of that window.
    -- Two windows with the same title get different IDs; one window keeps
    -- its ID across tab switches (the title is what catches those).
    local ok, id = pcall(function() return win:id() end)
    if ok and id then winId = tostring(id) end
    local okB, bundle = pcall(function() return app:bundleID() end)
    if okB and bundle and (bundle:find("^com%.google%.Chrome%.app%.") or TAB_BUNDLES[bundle]) then
      axTitle = debouncedAx(win, name .. "|" .. winId, bundle)
    end
  end
  local key
  if CONFIG.granularity == "app" then
    key = name
  elseif CONFIG.granularity == "app+window" then
    key = name .. " | #" .. winId .. " | ax:" .. axTitle
  else -- "app+window+title"
    key = name .. " | #" .. winId .. " | " .. title .. " | ax:" .. axTitle
  end
  return key, name, title, winId, axTitle
end

local function logStay(sec, app, title, winId, axTitle)
  if sec < CONFIG.minLogSeconds then return end
  table.insert(staysToday, { sec = sec, app = app, title = title, ax = axTitle })
  local isNew = false
  local f = io.open(CONFIG.logPath, "r"); if f then f:close() else isNew = true end
  f = io.open(CONFIG.logPath, "a")
  if f then
    if isNew then f:write("end_time,app,window_id,window_title,ax_title,duration_seconds\n") end
    local esc = function(s) return '"' .. tostring(s):gsub('"', '""') .. '"' end
    f:write(string.format("%s,%s,%s,%s,%s,%d\n",
      os.date("%Y-%m-%d %H:%M:%S"), esc(app), esc(winId), esc(title), esc(axTitle), sec))
    f:close()
  end
end

local function medianOf(list)
  if #list == 0 then return 0 end
  local s = { table.unpack(list) }; table.sort(s)
  return s[math.ceil(#s / 2)]
end

local function csvParseLine(line)
  local fields, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == '"' then
      local buf, j = {}, i + 1
      while j <= n do
        local ch = line:sub(j, j)
        if ch == '"' then
          if line:sub(j + 1, j + 1) == '"' then buf[#buf + 1] = '"'; j = j + 2
          else j = j + 1; break end
        else buf[#buf + 1] = ch; j = j + 1 end
      end
      fields[#fields + 1] = table.concat(buf)
      if line:sub(j, j) == "," then i = j + 1 else i = n + 1 end
    else
      local j = line:find(",", i, true)
      if j then fields[#fields + 1] = line:sub(i, j - 1); i = j + 1
      else fields[#fields + 1] = line:sub(i); i = n + 1 end
    end
  end
  return fields
end

local function jsonEsc(s)
  return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end))
end

local function dayStaysFromCSV()
  local today = os.date("%Y-%m-%d")
  local f = io.open(CONFIG.logPath, "r")
  if not f then return {} end
  local out = {}
  for line in f:lines() do
    if line:sub(1, 10) == today then
      local fld = csvParseLine(line)
      -- end_time,app,window_id,window_title,ax_title,duration_seconds
      if #fld >= 6 then
        local y, mo, d, h, mi, s = fld[1]:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
        local dur = tonumber(fld[6])
        if y and dur then
          local endT = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
            hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
          out[#out + 1] = { app = fld[2], title = fld[4], ax = fld[5],
            dur = dur, startT = endT - dur, endT = endT }
        end
      end
    end
  end
  f:close()
  table.sort(out, function(a, b) return a.startT < b.startT end)
  return out
end

-- Returns a TABLE of lines, one line per menu item (v3.3). Before this,
-- all lines were \n-joined into a single menu item title — Hammerspoon /
-- AppKit menu items don't render newlines, so the whole summary showed
-- as one big line.
-- Simple unicode bar: bar(50, 100, 10) -> "█████░░░░░"
local function bar(value, max, width)
  if max <= 0 then return string.rep("░", width) end
  local filled = math.floor(value / max * width + 0.5)
  if filled > width then filled = width end
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

-- Stay-length buckets shared by the day histogram and the per-app
-- sparklines: <10s, 10-30s, 30s-2m, 2-10m, 10-25m, >=25m.
local BUCKETS = {
  { "<10s", 0, 9 }, { "10-30s", 10, 29 }, { "30s-2m", 30, 119 },
  { "2-10m", 120, 599 }, { "10-25m", 600, 1499 }, { "≥25m", 1500, math.huge },
}
local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
-- Per-app stay-length DISTRIBUTION as a 6-glyph sparkline (v3.8, replaces
-- the old share-of-total bar, which only compared totals between apps).
-- Each glyph is one bucket, height = stay count in it, scaled to the
-- app's fullest bucket. Zero-count buckets render as the baseline ▁.
local function sparkline(secsList)
  local counts, maxCount = {}, 0
  for i, b in ipairs(BUCKETS) do
    counts[i] = 0
    for _, d in ipairs(secsList) do if d >= b[2] and d <= b[3] then counts[i] = counts[i] + 1 end end
    if counts[i] > maxCount then maxCount = counts[i] end
  end
  if maxCount == 0 then return string.rep("▁", #BUCKETS) end
  local out = {}
  for i = 1, #BUCKETS do
    local idx = counts[i] == 0 and 1 or (1 + math.ceil(counts[i] / maxCount * 7))
    out[i] = SPARK[idx]
  end
  return table.concat(out)
end

local function stats()
  -- Source of truth is the CSV (v3.11): the old in-memory staysToday was
  -- wiped by every config reload while the dashboard (CSV-based) kept
  -- the full day. Menu and dashboard now read the same data.
  local records = {}
  for _, st in ipairs(dayStaysFromCSV()) do
    records[#records + 1] = { sec = st.dur, app = st.app, title = st.title, ax = st.ax }
  end
  if #records == 0 then return { "No finished stays yet today" } end
  -- loginwindow = locked/idle screen. Its "stays" (e.g. 11h overnight)
  -- poison every other stat, so they're split out and only reported as
  -- a single locked total. (v3.6)
  local durations, totalSum, lockedTotal = {}, 0, 0
  local apps = {} -- name -> {secs={}, total=0, subs={label->{count,total}}}
  for _, r in ipairs(records) do
    if r.app == "loginwindow" then
      lockedTotal = lockedTotal + r.sec
    else
    durations[#durations + 1] = r.sec; totalSum = totalSum + r.sec
    local a = apps[r.app]; if not a then a = { secs = {}, total = 0, subs = {} }; apps[r.app] = a end
    a.secs[#a.secs + 1] = r.sec; a.total = a.total + r.sec
    -- Within-app key: PWA session (AX title) > window/tab title > app only.
    -- AX titles look like "ds-clone - Anurag (Meta)" — keep only the first
    -- segment so the account name never appears in the summary.
    local sub
    if r.ax ~= "" then sub = r.ax:match("^(.-) %- ") or r.ax
    elseif r.title ~= "" then sub = r.title
    else sub = "(untitled window)" end
    if #sub > 45 then sub = sub:sub(1, 42) .. "..." end
    local s = a.subs[sub]; if not s then s = { count = 0, total = 0 }; a.subs[sub] = s end
    s.count = s.count + 1; s.total = s.total + r.sec
    end
  end
  if #durations == 0 then
    return { "No active stays yet today",
      string.format("Locked (loginwindow): %s", fmt(lockedTotal)) }
  end
  table.sort(durations)
  -- Focus vs fragmentation: the shape of the day matters more than the
  -- median. Count deep stays (>=25 min) and flutter (<30s).
  local focusCount, focusTotal, flutter = 0, 0, 0
  for _, d in ipairs(durations) do
    if d >= 1500 then focusCount = focusCount + 1; focusTotal = focusTotal + d end
    if d < 30 then flutter = flutter + 1 end
  end
  local lines = { string.format("Stays today: %d  •  Active: %s", #durations, fmt(totalSum)),
    string.format("Median: %s  •  Longest: %s", fmt(medianOf(durations)), fmt(durations[#durations])),
    string.format("Focus ≥25m: %d stays, %s  •  <30s: %d%% of stays",
      focusCount, fmt(focusTotal), math.floor(flutter / #durations * 100 + 0.5)) }
  if lockedTotal > 0 then
    lines[#lines + 1] = string.format("Locked (loginwindow): %s — excluded above", fmt(lockedTotal))
  end
  -- Duration histogram: where the day actually went, bucket by bucket.
  -- Bar comes FIRST (v3.8): menu text is a proportional font, so padded
  -- labels never align — a fixed-width bar at column 0 always does.
  lines[#lines + 1] = "—"
  lines[#lines + 1] = "Stay lengths:"
  local counts, maxCount = {}, 0
  for i, b in ipairs(BUCKETS) do
    counts[i] = 0
    for _, d in ipairs(durations) do if d >= b[2] and d <= b[3] then counts[i] = counts[i] + 1 end end
    if counts[i] > maxCount then maxCount = counts[i] end
  end
  for i, b in ipairs(BUCKETS) do
    lines[#lines + 1] = string.format("%s %s · %d", bar(counts[i], maxCount, 14), b[1], counts[i])
  end
  lines[#lines + 1] = "—"
  lines[#lines + 1] = "By app:"
  local appList = {}
  for name, a in pairs(apps) do appList[#appList + 1] = { name = name, data = a } end
  table.sort(appList, function(x, y) return x.data.total > y.data.total end)
  -- Top 6 apps, each with its top 6 tabs/sessions; everything past the
  -- cut is rolled up into a single line (per app, and for apps overall)
  -- so nothing silently disappears from the summary.
  local TOP = 6
  local otherApps, otherAppStays, otherAppTotal = 0, 0, 0
  for i, entry in ipairs(appList) do
    if i > TOP then
      otherApps = otherApps + 1
      otherAppStays = otherAppStays + #entry.data.secs
      otherAppTotal = otherAppTotal + entry.data.total
    else
      local a = entry.data
      -- Leading glyphs are the app's stay-length distribution sparkline
      -- (buckets <10s .. ≥25m, height = stays in bucket). Fixed 6 chars
      -- at column 0 keeps every app's columns vertically aligned.
      lines[#lines + 1] = string.format("%s %s — %d stays, %s total, median %s",
        sparkline(a.secs), entry.name, #a.secs, fmt(a.total), fmt(medianOf(a.secs)))
      -- Within-app breakdown, only when the app actually has distinct
      -- windows/tabs/sessions (Chrome, PWAs like Metamate, multi-doc apps)
      local subList, subCount = {}, 0
      for label, s in pairs(a.subs) do subList[#subList + 1] = { label = label, data = s }; subCount = subCount + 1 end
      if subCount >= 2 then
        table.sort(subList, function(x, y) return x.data.total > y.data.total end)
        local restStays, restTotal = 0, 0
        for j, se in ipairs(subList) do
          if j <= TOP then
            lines[#lines + 1] = string.format("↳ %s — %d stays, %s total",
              se.label, se.data.count, fmt(se.data.total))
          else
            restStays = restStays + se.data.count; restTotal = restTotal + se.data.total
          end
        end
        if restStays > 0 then
          lines[#lines + 1] = string.format("↳ +%d more — %d stays, %s total",
            subCount - TOP, restStays, fmt(restTotal))
        end
      end
    end
  end
  if otherApps > 0 then
    lines[#lines + 1] = string.format("+%d more apps — %d stays, %s total",
      otherApps, otherAppStays, fmt(otherAppTotal))
  end
  return lines
end

-- ===================== Dashboard (v3.9) =====================
-- The menu is text-only (no color, proportional font). The dashboard is
-- the pretty layer: an hs.webview panel with a colored day timeline and
-- per-app stay histograms, Stats-app style. Data comes from today's CSV
-- rows (so it survives config reloads), plus the in-progress stay.

local function dashboardJSON()
  local stays = dayStaysFromCSV()
  -- append the in-progress stay so the panel is live
  if currentApp ~= "" then
    local now = os.time()
    stays[#stays + 1] = { app = currentApp, title = currentTitle, ax = currentAx,
      dur = now - startTime, startT = startTime, endT = now, live = true }
  end
  local apps, order = {}, {}
  local totalActive, lockedTotal = 0, 0
  local durations = {}
  for _, st in ipairs(stays) do
    if st.app == "loginwindow" then
      lockedTotal = lockedTotal + st.dur
    else
      totalActive = totalActive + st.dur
      durations[#durations + 1] = st.dur
      local a = apps[st.app]
      if not a then
        a = { name = st.app, total = 0, secs = {}, buckets = { 0, 0, 0, 0, 0, 0 }, subs = {} }
        apps[st.app] = a; order[#order + 1] = a
      end
      a.total = a.total + st.dur
      a.secs[#a.secs + 1] = st.dur
      for i, b in ipairs(BUCKETS) do
        if st.dur >= b[2] and st.dur <= b[3] then a.buckets[i] = a.buckets[i] + 1; break end
      end
      local label
      if st.ax ~= "" then label = st.ax:match("^(.-) %- ") or st.ax
      elseif st.title ~= "" then label = st.title
      else label = "(untitled window)" end
      local s = a.subs[label]
      if not s then s = { label = label, count = 0, total = 0 }; a.subs[label] = s end
      s.count = s.count + 1; s.total = s.total + st.dur
    end
  end
  table.sort(order, function(x, y) return x.total > y.total end)
  table.sort(durations)
  local focusCount, focusTotal, flutter = 0, 0, 0
  for _, d in ipairs(durations) do
    if d >= 1500 then focusCount = focusCount + 1; focusTotal = focusTotal + d end
    if d < 30 then flutter = flutter + 1 end
  end
  local dayStart = os.time({ year = tonumber(os.date("%Y")), month = tonumber(os.date("%m")),
    day = tonumber(os.date("%d")), hour = 0, min = 0, sec = 0 })
  local p = {}
  p[#p + 1] = '{"date":"' .. os.date("%a %b %d") .. '","dayStart":' .. dayStart ..
    ',"now":' .. os.time() .. ',"stats":{"stays":' .. #durations ..
    ',"active":' .. totalActive .. ',"locked":' .. lockedTotal ..
    ',"median":' .. medianOf(durations) ..
    ',"longest":' .. (durations[#durations] or 0) ..
    ',"focusCount":' .. focusCount .. ',"focusTotal":' .. focusTotal ..
    ',"flutterPct":' .. (#durations > 0 and math.floor(flutter / #durations * 100 + 0.5) or 0) .. '},"apps":['
  local appChunks = {}
  for _, a in ipairs(order) do
    local subs = {}
    for _, s in pairs(a.subs) do subs[#subs + 1] = s end
    table.sort(subs, function(x, y) return x.total > y.total end)
    local subChunks = {}
    for i, s in ipairs(subs) do
      if i > 6 then break end
      subChunks[#subChunks + 1] = '{"label":"' .. jsonEsc(s.label) .. '","count":' .. s.count .. ',"total":' .. s.total .. '}'
    end
    appChunks[#appChunks + 1] = '{"name":"' .. jsonEsc(a.name) .. '","total":' .. a.total ..
      ',"count":' .. #a.secs .. ',"median":' .. medianOf(a.secs) ..
      ',"buckets":[' .. table.concat(a.buckets, ",") .. '],"subs":[' .. table.concat(subChunks, ",") .. ']}'
  end
  p[#p + 1] = table.concat(appChunks, ",")
  p[#p + 1] = '],"timeline":['
  local tlChunks = {}
  for _, st in ipairs(stays) do
    tlChunks[#tlChunks + 1] = '{"app":"' .. jsonEsc(st.app) .. '","start":' .. st.startT ..
      ',"end":' .. st.endT .. (st.live and ',"live":true' or '') .. '}'
  end
  p[#p + 1] = table.concat(tlChunks, ",")
  p[#p + 1] = "]}"
  return table.concat(p)
end

local DASHBOARD_HTML = [==[
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
:root{color-scheme:light dark}
*{box-sizing:border-box;margin:0;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
body{padding:18px 20px;background:Canvas;color:CanvasText}
h1{font-size:19px;font-weight:700;margin-bottom:2px}
.sub{opacity:.55;font-size:12px;margin-bottom:14px}
.cards{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}
.card{flex:1;min-width:105px;border:1px solid rgba(128,128,128,.25);border-radius:12px;padding:10px 12px}
.card .v{font-size:20px;font-weight:700}
.card .k{font-size:11px;opacity:.6;text-transform:uppercase;letter-spacing:.04em;margin-top:2px}
h2{font-size:13px;font-weight:700;margin:16px 0 8px;opacity:.85}
.tl{position:relative;height:44px;border-radius:8px;background:rgba(128,128,128,.12);overflow:hidden}
.seg{position:absolute;top:0;bottom:0;min-width:1px}
.seg.live{opacity:.55}
.tlaxis{display:flex;justify-content:space-between;font-size:10px;opacity:.5;margin-top:3px}
.legend{display:flex;gap:12px;flex-wrap:wrap;font-size:11px;margin-top:8px}
.legend span{display:inline-flex;align-items:center;gap:5px}
.dot{width:9px;height:9px;border-radius:3px;display:inline-block}
.app{border:1px solid rgba(128,128,128,.25);border-radius:12px;padding:12px 14px;margin-bottom:10px}
.apphead{display:flex;align-items:baseline;gap:8px;margin-bottom:8px}
.appname{font-size:15px;font-weight:700}
.appmeta{font-size:12px;opacity:.6}
.hist{display:flex;align-items:flex-end;gap:6px;height:64px;margin:4px 0 2px}
.col{flex:1;display:flex;flex-direction:column;align-items:center;gap:3px;height:100%;justify-content:flex-end}
.bar{width:100%;border-radius:4px 4px 0 0;min-height:2px}
.col .n{font-size:11px;font-weight:600}
.col .b{font-size:10px;opacity:.55}
.subs{margin-top:8px;border-top:1px solid rgba(128,128,128,.18);padding-top:7px}
.subs div{display:flex;justify-content:space-between;font-size:12px;padding:1.5px 0}
.subs .t{opacity:.6;white-space:nowrap;margin-left:14px}
.subs .l{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.winbtns{position:fixed;top:12px;right:14px;display:flex;gap:6px;z-index:10}
.winbtns button{width:26px;height:26px;border-radius:50%;border:1px solid rgba(128,128,128,.35);background:rgba(128,128,128,.14);color:CanvasText;font-size:13px;line-height:1;cursor:pointer}
.winbtns button:hover{background:rgba(128,128,128,.3)}
#x:hover{background:#e81123;color:#fff;border-color:#e81123}
</style></head><body>
<div class="winbtns"><button id="rf" title="Refresh">↻</button><button id="x" title="Close">✕</button></div>
<h1>Screen Timer — <span id="date"></span></h1>
<div class="sub">Stays so far today. The panel reflects the moment it was opened — reopen to refresh.</div>
<div class="cards" id="cards"></div>
<h2>Day timeline</h2>
<div class="tl" id="tl"></div>
<div class="tlaxis"><span>00:00</span><span>06:00</span><span>12:00</span><span>18:00</span><span>now</span></div>
<div class="legend" id="legend"></div>
<h2>By app — stay-length distribution</h2>
<div id="apps"></div>
<script>
function post(m){ try{ window.webkit.messageHandlers.dashboard.postMessage(m); }catch(e){} }
document.getElementById("x").onclick = function(){ post("close"); };
document.getElementById("rf").onclick = function(){ post("refresh"); };
const DATA = __DATA__;
const PALETTE = ["#3b82f6","#14b8a6","#f59e0b","#ef4444","#8b5cf6","#ec4899","#22c55e","#f97316","#06b6d4","#a3a380"];
const LOCK = "#9ca3af";
const colorOf = {}; let ci = 0;
function color(app){ if(app==="loginwindow") return LOCK; if(!(app in colorOf)) colorOf[app]=PALETTE[ci++ % PALETTE.length]; return colorOf[app]; }
function fmt(s){ s=Math.round(s); if(s<3600) return String(Math.floor(s/60)).padStart(2,"0")+":"+String(s%60).padStart(2,"0"); return Math.floor(s/3600)+":"+String(Math.floor(s%3600/60)).padStart(2,"0")+":"+String(s%60).padStart(2,"0"); }
function hm(t){ const d=new Date(t*1000); return String(d.getHours()).padStart(2,"0")+":"+String(d.getMinutes()).padStart(2,"0"); }
document.getElementById("date").textContent = DATA.date;
const st = DATA.stats;
const cards = [["Stays", st.stays],["Active", fmt(st.active)],["Median stay", fmt(st.median)],["Longest", fmt(st.longest)],
  ["Focus ≥25m", st.focusCount+" · "+fmt(st.focusTotal)],["Stays <30s", st.flutterPct+"%"]];
if(st.locked>0) cards.push(["Locked", fmt(st.locked)]);
document.getElementById("cards").innerHTML = cards.map(c=>'<div class="card"><div class="v">'+c[1]+'</div><div class="k">'+c[0]+'</div></div>').join("");
const span = Math.max(DATA.now - DATA.dayStart, 3600);
document.getElementById("tl").innerHTML = DATA.timeline.map(s=>{
  const l=((s.start-DATA.dayStart)/span*100).toFixed(2), w=Math.max((s.end-s.start)/span*100,0.15).toFixed(2);
  return '<div class="seg'+(s.live?" live":"")+'" style="left:'+l+'%;width:'+w+'%;background:'+color(s.app)+'" title="'+s.app.replace(/"/g,"")+" · "+hm(s.start)+"–"+hm(s.end)+" · "+fmt(s.end-s.start)+'"></div>';
}).join("");
document.getElementById("legend").innerHTML = [...new Set(DATA.timeline.map(s=>s.app))].map(a=>'<span><i class="dot" style="background:'+color(a)+'"></i>'+a+"</span>").join("");
const BUCKETS = ["<10s","10–30s","30s–2m","2–10m","10–25m","≥25m"];
document.getElementById("apps").innerHTML = DATA.apps.map(a=>{
  const max = Math.max(...a.buckets, 1);
  const cols = a.buckets.map((n,i)=>'<div class="col"><div class="n">'+(n||"")+'</div><div class="bar" style="height:'+Math.max(n/max*44, n?3:1.5)+'px;background:'+color(a.name)+'"></div><div class="b">'+BUCKETS[i]+'</div></div>').join("");
  const subs = a.subs.length>1 ? '<div class="subs">'+a.subs.map(s=>'<div><span class="l">'+s.label.replace(/</g,"&lt;")+'</span><span class="t">'+s.count+" stays · "+fmt(s.total)+"</span></div>").join("")+"</div>" : "";
  return '<div class="app"><div class="apphead"><span class="appname">'+a.name.replace(/</g,"&lt;")+'</span><span class="appmeta">'+a.count+" stays · "+fmt(a.total)+" total · median "+fmt(a.median)+'</span></div><div class="hist">'+cols+"</div>"+subs+"</div>";
}).join("");
</script></body></html>
]==]

local function openDashboard()
  -- Toggle (v3.10): choosing "Open dashboard" while it's open closes it.
  -- (v3.9 had no close path short of Reload Config — sorry.) Esc also
  -- closes it via closeOnEscape where supported, and deleting the
  -- webview when its window is closed by hand keeps the toggle in sync.
  if SCREEN_TIMER and SCREEN_TIMER.webview then
    local wv = SCREEN_TIMER.webview
    SCREEN_TIMER.webview = nil
    pcall(function() wv:delete() end)
    return
  end
  local html = DASHBOARD_HTML:gsub("__DATA__", function() return dashboardJSON() end)
  local sf = hs.screen.mainScreen():frame()
  local rect = { x = sf.x + (sf.w - 900) / 2, y = sf.y + (sf.h - 680) / 2, w = 900, h = 680 }
  -- JS bridge for the on-panel ✕ / ↻ buttons (v3.11). If the usercontent
  -- API is unavailable, fall back to a plain webview (toggle/Esc still work).
  local ucc = nil
  pcall(function()
    ucc = hs.webview.usercontent.new("dashboard")
    ucc:setCallback(function(msg)
      local body = (type(msg) == "table" and msg.body) or msg
      if body == "close" then
        openDashboard() -- toggle off
      elseif body == "refresh" then
        if SCREEN_TIMER and SCREEN_TIMER.webview then
          -- parens are load-bearing: gsub returns (string, count) and the
          -- bare call forwarded the count as :html()'s 3rd argument
          SCREEN_TIMER.webview:html((DASHBOARD_HTML:gsub("__DATA__", function() return dashboardJSON() end)))
        end
      end
    end)
  end)
  local wv = ucc and hs.webview.new(rect, ucc) or hs.webview.new(rect)
  wv:windowTitle("Screen Timer — Dashboard")
  pcall(function() wv:closeOnEscape(true) end)
  pcall(function()
    wv:windowCallback(function(action)
      if action == "closing" and SCREEN_TIMER then SCREEN_TIMER.webview = nil end
    end)
  end)
  wv:html(html)
  wv:show()
  wv:bringToFront(true)
  SCREEN_TIMER = SCREEN_TIMER or {}
  SCREEN_TIMER.webview = wv
end

local function tick()
  local key, name, title, winId, axTitle = frontmost()
  if key ~= currentKey then
    if currentKey ~= nil then logStay(os.time() - startTime, currentApp, currentTitle, currentWinId, currentAx) end
    currentKey, currentApp, currentTitle, currentWinId, currentAx = key, name, title, winId, axTitle
    startTime = os.time()
  end
  -- Chrome apps: label with the session (first segment of the AX title)
  local display = name
  if axTitle ~= "" then display = axTitle:match("^(.-) %- ") or axTitle end
  -- Fixed-width name field (v3.12): pad short names, cut long ones with
  -- an ellipsis, so the clock never moves and is never truncated.
  local function fixedName(s, width)
    local okLen, len = pcall(function() return utf8.len(s) end)
    if not okLen or not len then len = #s end
    if len > width then
      local okCut, cut = pcall(function() return s:sub(1, utf8.offset(s, width) - 1) end)
      if okCut and cut then return cut .. "…" end
      return s:sub(1, width - 1) .. "…"
    end
    return s .. string.rep(" ", width - len)
  end
  local label = fixedName(display, CONFIG.nameWidth) .. " " .. fmt(os.time() - startTime)
  if menubar then menubar:setTitle("◉ " .. label) end
end

if menubar then
  menubar:setMenu(function()
    -- Info lines are NOT disabled on purpose (v3.7): macOS renders
    -- disabled menu items in gray — text and unicode bars alike — which
    -- made the whole summary look washed out. Enabled items with no fn
    -- render in full black and do nothing when clicked.
    local items = {
      { title = (currentAx ~= "" and ("AX session: " .. (currentAx:match("^(.-) %- ") or currentAx)) or "AX session: (none)") },
      { title = "-" },
    }
    for _, line in ipairs(stats()) do
      if line == "—" then
        items[#items + 1] = { title = "-" }
      else
        items[#items + 1] = { title = line }
      end
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Open dashboard / close", fn = function() local ok, err = pcall(openDashboard); if not ok then hs.alert.show("Dashboard error: " .. tostring(err)) end end },
    { title = "Open log (CSV)", fn = function() os.execute('open "' .. CONFIG.logPath .. '"') end }
    items[#items + 1] = { title = "Reset timer now", fn = function() startTime = os.time() end }
    return items
  end)
end

currentKey, currentApp, currentTitle, currentWinId, currentAx = frontmost()

-- v3.5 freeze fix: earlier versions discarded the hs.timer object returned
-- by doEvery. An unreferenced timer can be garbage-collected, which stops
-- ticking entirely — display freezes and no stays reach the CSV. The timer
-- and menubar are now anchored in a global table so they live as long as
-- Hammerspoon does. Ticks are also pcall-wrapped: an error is written to
-- ~/screen-timer-debug.log (throttled) instead of silently freezing.
SCREEN_TIMER = SCREEN_TIMER or {}
SCREEN_TIMER.menubar = menubar
local lastErrLog = 0
SCREEN_TIMER.timer = hs.timer.doEvery(1, function()
  local ok, err = pcall(tick)
  if not ok then
    if menubar then menubar:setTitle("◉ ⚠ error") end
    if os.time() - lastErrLog >= 60 then
      lastErrLog = os.time()
      local f = io.open(os.getenv("HOME") .. "/screen-timer-debug.log", "a")
      if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. "tick error: " .. tostring(err) .. "\n"); f:close() end
    end
  end
end)
tick()
