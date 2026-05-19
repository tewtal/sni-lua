-- store + http demo
--
-- Shows the two side-effecting APIs that never block the frame:
--
--   store.*  persistent per-script state. store.get/set is a key-value
--            cache; store.load/save read/replace the whole document. The
--            app auto-saves it (debounced, and on exit) to a JSON file
--            keyed by this script's path -- nothing to flush yourself.
--
--   http.*   async HTTP. http.get/post/put/delete return immediately; the
--            callback runs on a LATER frame (on the UI thread, VM idle, no
--            re-entrancy). Response table: { ok, status, headers, body,
--            error }. ok=false means a transport failure (see .error); a
--            4xx/5xx still has ok=true with the status set.
--
-- It needs no SNES connection -- load it standalone to see it work.

-- A position watch, only so there's something live on screen.
local samus_x = snes.watch(0x0AF6, 2, "high")

local WHITE  = 0xFFFFFFFF
local GREEN  = 0xFF40FF40
local YELLOW = 0xFFFFD040
local GREY   = 0xFF909090

-- HTTP state the callback fills in; on_frame only reads it.
local net = { status = "idle", body = nil }

-- How many times this script has ever been loaded, persisted across runs.
local runs = 0

function on_init()
  -- store.get returns nil the very first time, then the saved number.
  runs = (store.get("runs") or 0) + 1
  store.set("runs", runs)                 -- auto-saved by the app
  store.set("last_loaded_unix", os.time())
  print(("store: this is run #%d"):format(runs))

  -- Fire one request at load. httpbin echoes JSON back so we can show it.
  net.status = "requesting..."
  http.post(
    "https://httpbin.org/post",
    http.json({ script = "store_http_demo", run = runs }),
    { headers = { ["content-type"] = "application/json" } },
    function(r)
      if not r.ok then
        net.status = "error: " .. (r.error or "?")
        return
      end
      net.status = ("HTTP %d"):format(r.status)
      -- httpbin returns our body back under "json"; pull a field out.
      local parsed = http.parse(r.body)
      if parsed and parsed.json then
        net.body = ("echoed run = %s"):format(tostring(parsed.json.run))
      end
      print("http: " .. net.status .. "  " .. (net.body or ""))
    end
  )
end

function on_frame()
  gfx.font("small")
  gfx.text(8, 8,  ("Run #%d  (persisted via store)"):format(runs), GREEN)
  gfx.text(8, 18, "HTTP: " .. net.status,
           net.status:find("error") and YELLOW or WHITE)
  if net.body then
    gfx.text(8, 28, net.body, GREY)
  end

  local sx = snes.u16(samus_x)
  gfx.text(8, 44,
           sx and ("Samus X = %d"):format(sx) or "Samus X = (no SNES data)",
           GREY)
end
