-- OwnTracks Recorder hook: push an ntfy alert when someone enters or leaves a place.
-- Places are the "waypoints" sent to each phone by `fgps qr`; the phone's OS
-- detects the crossing and posts a `transition` message.

local url = os.getenv("NTFY_URL") or "http://ntfy:80"
local topic = os.getenv("NTFY_TOPIC") or "family"
local token = os.getenv("NTFY_TOKEN") or ""

-- Quote a string for /bin/sh.
local function sh(s)
	return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Minimal JSON string encoder (place names come from user input).
local function js(s)
	s = tostring(s):gsub('[%c"\\]', function(c)
		return string.format("\\u%04x", c:byte())
	end)
	return '"' .. s .. '"'
end

function otr_init()
	if token == "" then
		otr.log("alerts.lua: NTFY_TOKEN not set, alerts disabled")
	end
end

function otr_exit()
end

function otr_hook(topic_, _type, data)
	if _type ~= "transition" or token == "" then
		return
	end

	local user = topic_:match("^owntracks/([^/]+)/") or "someone"
	local name = user:sub(1, 1):upper() .. user:sub(2)
	local place = data["desc"] or "a place"
	local verb, tag = "left", "wave"
	if data["event"] == "enter" then
		verb, tag = "arrived at", "house"
	end
	local when = os.date("%H:%M", tonumber(data["tst"]) or os.time())

	local body = "{" ..
		'"topic":' .. js(topic) .. "," ..
		'"title":' .. js(name .. " " .. verb .. " " .. place) .. "," ..
		'"message":' .. js("at " .. when) .. "," ..
		'"tags":[' .. js(tag) .. "]}"

	-- Background it so a slow ntfy never blocks the Recorder.
	os.execute("curl -fsS -m 10 -H " .. sh("Authorization: Bearer " .. token) ..
		" -d " .. sh(body) .. " " .. sh(url) .. " >/dev/null 2>&1 &")
end
