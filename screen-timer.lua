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

local function stats()
  if #staysToday == 0 then return { "No finished stays yet today" } end
  -- loginwindow = locked/idle screen. Its "stays" (e.g. 11h overnight)
  -- poison every other stat, so they're split out and only reported as
  -- a single locked total. (v3.6)
  local durations, totalSum, lockedTotal = {}, 0, 0
  local apps = {} -- name -> {secs={}, total=0, subs={label->{count,total}}}
  for _, r in ipairs(staysToday) do
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
  lines[#lines + 1] = "—"
  lines[#lines + 1] = "Stay lengths:"
  local buckets = {
    { "<10s", 0, 9 }, { "10-30s", 10, 29 }, { "30s-2m", 30, 119 },
    { "2-10m", 120, 599 }, { "10-25m", 600, 1499 }, { "≥25m", 1500, math.huge },
  }
  local counts, maxCount = {}, 0
  for i, b in ipairs(buckets) do
    counts[i] = 0
    for _, d in ipairs(durations) do if d >= b[2] and d <= b[3] then counts[i] = counts[i] + 1 end end
    if counts[i] > maxCount then maxCount = counts[i] end
  end
  for i, b in ipairs(buckets) do
    lines[#lines + 1] = string.format("%-7s %s %d", b[1], bar(counts[i], maxCount, 14), counts[i])
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
      lines[#lines + 1] = string.format("%s %s — %d stays, %s total, median %s",
        bar(a.total, appList[1].data.total, 10), entry.name, #a.secs, fmt(a.total), fmt(medianOf(a.secs)))
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
  local label = (display ~= "" and display .. " " or "") .. fmt(os.time() - startTime)
  if menubar then menubar:setTitle("◉ " .. label) end
end

if menubar then
  menubar:setMenu(function()
    local items = {
      { title = (currentAx ~= "" and ("AX session: " .. (currentAx:match("^(.-) %- ") or currentAx)) or "AX session: (none)"), disabled = true },
      { title = "-" },
    }
    for _, line in ipairs(stats()) do
      if line == "—" then
        items[#items + 1] = { title = "-" }
      else
        items[#items + 1] = { title = line, disabled = true }
      end
    end
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = "Open log (CSV)", fn = function() os.execute('open "' .. CONFIG.logPath .. '"') end }
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
