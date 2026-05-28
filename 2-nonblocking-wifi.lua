local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local NetworkSetting = require("ui/widget/networksetting")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local ToggleSwitch = require("ui/widget/toggleswitch")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template
local Screen = Device.screen

local WiFiQuickPopup = InputContainer:extend{
    network_list = nil,
    connect_callback = nil,
    disconnect_callback = nil,
    is_wifi_on = false,
    is_scanning = false,
    is_closed = false,
    auto_connected = false,
    width = nil,
    height = nil,
}

local cached_network_list = nil

-- Module-level scan state — survives popup close so auto-connect always runs.
local bg_scan = nil  -- nil or { pid, read_fd, callbacks }

local function fireBgScanCallbacks(network_list, err)
    if not bg_scan then return end
    local cbs = bg_scan.callbacks
    bg_scan = nil
    if network_list then
        cached_network_list = network_list
    end
    for _, cb in ipairs(cbs) do
        cb(network_list, err)
    end
end

local function cancelBgScan()
    if not bg_scan then return end
    UIManager:unschedule(pollBgScan)
    -- Kill the subprocess if still running
    if bg_scan.pid then
        ffiutil.terminateSubProcess(bg_scan.pid)
        -- Reap the zombie
        ffiutil.isSubProcessDone(bg_scan.pid, true)
    end
    -- Close the read end of the pipe
    if bg_scan.read_fd then
        local C = require("ffi").C
        C.close(bg_scan.read_fd)
    end
    bg_scan = nil
end

local function pollBgScan()
    if not bg_scan then return end
    -- Wait until the child process has fully exited before reading.
    -- readAllFromFD is a blocking loop (reads until EOF), so reading
    -- while the child is still running would freeze the UI.
    local done = ffiutil.isSubProcessDone(bg_scan.pid)
    if not done then
        UIManager:scheduleIn(0.25, pollBgScan)
        return
    end
    local network_list, err
    if bg_scan.read_fd then
        local str = ffiutil.readAllFromFD(bg_scan.read_fd)
        if str and #str > 0 then
            local ok, t = pcall(buffer.decode, str)
            if ok and t then
                network_list, err = t[1], t[2]
            end
        end
    end
    fireBgScanCallbacks(network_list, err)
end

local function startBgScan(callback)
    if bg_scan then
        if callback then table.insert(bg_scan.callbacks, callback) end
        return
    end
    bg_scan = { callbacks = callback and {callback} or {} }
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local NM = require("ui/network/manager")
        local nl, e = NM:getNetworkList()
        if nl and #nl == 0 then
            nl, e = NM:getNetworkList()
        end
        local ok, str = pcall(buffer.encode, table.pack(nl, e))
        ffiutil.writeToFD(write_fd, ok and str or "", true)
    end, true)
    if not pid then
        fireBgScanCallbacks(nil, _("Failed to start network scan"))
        return
    end
    bg_scan.pid = pid
    bg_scan.read_fd = read_fd
    UIManager:scheduleIn(0.25, pollBgScan)
end

local function sortNetworks(network_list)
    table.sort(network_list, function(l, r)
        return (l.signal_quality or 0) > (r.signal_quality or 0)
    end)
end

local function enableKoboWifi()
    logger.info("Non-blocking Wi-Fi patch: enabling Kobo Wi-Fi")
    os.execute("./enable-wifi.sh")
    NetworkMgr:setWifiState(true)
end

local function obtainIPAndNotify(ssid, connect_callback)
    NetworkMgr:obtainIP()
    -- Broadcast NetworkConnected so plugins (KOSync, etc.) are notified
    NetworkMgr.wifi_was_on = true
    G_reader_settings:makeTrue("wifi_was_on")
    UIManager:broadcastEvent(Event:new("NetworkConnected"))
    if connect_callback then
        connect_callback()
    end
    UIManager:show(InfoMessage:new{
        tag = "NetworkMgr",
        text = T(_("Connected to network %1"), BD.wrap(util.fixUtf8(ssid, "?"))),
        timeout = 3,
    })
end

function WiFiQuickPopup:init()
    self.width = self.width or math.min(Screen:getWidth() - Screen:scaleBySize(80), Screen:scaleBySize(500))
    self.height = self.height or math.min(Screen:getHeight() * 2 / 3, Screen:scaleBySize(680))
    self.network_list = self.network_list or cached_network_list or {}
    self.is_wifi_on = NetworkMgr:isWifiOn()

    -- Attach to an in-progress background scan if one exists
    if bg_scan then
        self.is_scanning = true
        table.insert(bg_scan.callbacks, function(network_list, err)
            self.is_scanning = false
            if not self.is_closed then
                if network_list then
                    sortNetworks(network_list)
                    self.network_list = network_list
                else
                    UIManager:show(InfoMessage:new{ text = err or _("An error occurred while scanning.") })
                end
                self:refresh()
            end
        end)
    end

    -- Setup gesture events once (not on every rebuild)
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            }
        }
    end

    self:rebuild()

    if self.is_wifi_on and not cached_network_list and not bg_scan then
        UIManager:nextTick(function()
            if self[1] then
                self:startScan()
            end
        end)
    end
end

function WiFiQuickPopup:buildHeader()
    -- Kobo native-style header: toggle switch + status label + refresh icon
    local toggle_w = Screen:scaleBySize(80)
    local toggle_h = Screen:scaleBySize(34)
    local h_pad = Size.padding.large

    -- ON/OFF toggle switch (pill-shaped, 2-position)
    self.wifi_toggle = ToggleSwitch:new{
        width = toggle_w,
        height = toggle_h,
        toggle = {_("OFF"), _("ON")},
        alternate = false,
        font_face = "cfont",
        font_size = 14,
        fgcolor = Blitbuffer.COLOR_BLACK,
        values = {1, 2},
        name = "wifi_toggle",
        config = self,   -- provides :onConfigChoose stub
        callback = function(position)
            -- Delay toggle to next tick so the switch paints first
            UIManager:nextTick(function()
                if self[1] then
                    self:toggleWifi()
                end
            end)
        end,
    }
    self.wifi_toggle:setPosition(self.is_wifi_on and 2 or 1)

    -- Status label: "WI-FI: ENABLED" or "WI-FI: DISABLED"
    local status_text = self.is_wifi_on and _("WI-FI: ENABLED") or _("WI-FI: DISABLED")
    self.wifi_status_label = TextWidget:new{
        text = status_text,
        face = Font:getFace("cfont", 18),
        bold = true,
    }

    -- Refresh button using nerdfont glyph (right-aligned)
    self.refresh_button = Button:new{
        text = "\u{F0453}",  -- 󰑓 nf-md-refresh
        text_font_face = "cfont",
        text_font_size = 22,
        text_font_bold = false,
        bordersize = 0,
        padding = Size.padding.default,
        enabled = self.is_wifi_on and not self.is_scanning,
        callback = function()
            self:startScan(true)
        end,
    }

    -- Left side: toggle + spacing + label
    local toggle_row_h = math.max(toggle_h, self.wifi_status_label:getSize().h)
    local toggle_and_label = HorizontalGroup:new{
        align = "center",
        self.wifi_toggle,
        HorizontalSpan:new{ width = Size.padding.default },
        self.wifi_status_label,
    }

    -- Full header row: left-aligned toggle+label, right-aligned refresh icon
    local header_row_dimen = Geom:new{ w = self.width, h = toggle_row_h }
    self.header_row = OverlapGroup:new{
        dimen = header_row_dimen,
        LeftContainer:new{
            dimen = header_row_dimen:copy(),
            toggle_and_label,
        },
        RightContainer:new{
            dimen = header_row_dimen:copy(),
            self.refresh_button,
        },
    }

    -- Horizontal line separator below header
    self.header_line = LineWidget:new{
        dimen = Geom:new{ w = self.width, h = Size.line.thick },
        background = Blitbuffer.COLOR_DARK_GRAY,
    }

    self.header_group = VerticalGroup:new{
        align = "left",
        self.header_row,
        VerticalSpan:new{ width = Size.padding.default },
        self.header_line,
    }
    return self.header_group
end

-- Stub required by ToggleSwitch when it fires events
function WiFiQuickPopup:onConfigChoose(values, name, event, args, position)
    -- no-op: toggle callback handles the action
end

function WiFiQuickPopup:updateHeader()
    -- Update toggle position in-place
    self.wifi_toggle:setPosition(self.is_wifi_on and 2 or 1)

    -- Update status label text
    local status_text = self.is_wifi_on and _("WI-FI: ENABLED") or _("WI-FI: DISABLED")
    self.wifi_status_label:setText(status_text)

    -- Update refresh button enabled state
    if self.is_wifi_on and not self.is_scanning then
        self.refresh_button:enable()
    else
        self.refresh_button:disable()
    end
end

function WiFiQuickPopup:makeBody()
    if not self.is_wifi_on then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.body_height },
            TextWidget:new{ text = _("Wi-Fi is off."), face = Font:getFace("cfont") },
        }
    end

    if self.is_scanning then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.body_height },
            TextWidget:new{ text = _("Scanning for networks..."), face = Font:getFace("cfont") },
        }
    end

    if #self.network_list == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.body_height },
            TextWidget:new{ text = _("No networks found."), face = Font:getFace("cfont") },
        }
    end

    -- Build network list through NetworkSetting but extract only the inner
    -- VerticalGroup (pagination + ListView), skipping the redundant outer
    -- FrameContainer with its own border/padding.
    self.network_setting = NetworkSetting:new{
        network_list = self.network_list,
        connect_callback = self.auto_connected and nil or self.connect_callback,
        width = self.width,
        height = self.body_height,
    }
    -- NetworkSetting.popup is a FrameContainer wrapping a VerticalGroup.
    -- We only need the inner VerticalGroup (pagination bar + ListView).
    return self.network_setting.popup[1]
end

function WiFiQuickPopup:rebuild()
    -- Build header (or reuse existing toggle/label)
    local header
    if not self.header_group then
        header = self:buildHeader()
    else
        self:updateHeader()
        header = self.header_group
    end

    -- Compute body height from actual header geometry
    local header_h = header:getSize().h
    local padding = Size.padding.default
    local border = Size.border.window
    -- Total chrome: top/bottom padding + top/bottom border + header
    local chrome_h = 2 * padding + 2 * border + header_h
    self.body_height = self.height - chrome_h

    self.popup = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = padding,
        bordersize = border,
        radius = Size.radius.window,
        VerticalGroup:new{
            align = "left",
            header,
            self:makeBody(),
        },
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        self.popup,
    }
end

function WiFiQuickPopup:refresh()
    self:rebuild()
    UIManager:setDirty(self, function()
        return "ui", self.popup.dimen
    end)
end

function WiFiQuickPopup:autoConnect(network_list)
    -- network_list is already sorted at scan completion; skip redundant sort.
    for _, network in ipairs(network_list) do
        if network.connected then
            local connect_callback = self.connect_callback
            self.connect_callback = nil
            obtainIPAndNotify(network.ssid, connect_callback)
            return true
        end
    end

    local err_msg = _("Connection failed")
    local attempted = false
    for _, network in ipairs(network_list) do
        if network.password then
            attempted = true
            logger.dbg("Non-blocking Wi-Fi patch: attempting preferred network", util.fixUtf8(network.ssid, "?"))
            local success
            success, err_msg = NetworkMgr:authenticateNetwork(network)
            if success then
                network.connected = true
                local connect_callback = self.connect_callback
                self.connect_callback = nil
                obtainIPAndNotify(network.ssid, connect_callback)
                return true
            end
            logger.dbg("Non-blocking Wi-Fi patch: authentication failed:", err_msg)
        end
    end

    return false, err_msg, attempted
end

function WiFiQuickPopup:startScan(skip_autoconnect)
    if self.is_scanning or not self.is_wifi_on then
        return
    end

    self.is_scanning = true
    self.auto_connected = false
    self:refresh()

    startBgScan(function(network_list, err)
        self.is_scanning = false

        if network_list == nil then
            if not self.is_closed then
                UIManager:show(InfoMessage:new{ text = err or _("An error occurred while scanning.") })
                self:refresh()
            end
            return
        end

        -- Sort once here; autoConnect and makeBody will use pre-sorted data.
        sortNetworks(network_list)
        self.network_list = network_list

        -- Skip auto-connect if already connected to a network
        local already_connected = false
        for _, network in ipairs(network_list) do
            if network.connected then
                already_connected = true
                break
            end
        end

        if not skip_autoconnect and not already_connected then
            local connected, err_msg, attempted = self:autoConnect(network_list)
            self.auto_connected = connected and true or false
            if attempted and not connected then
                UIManager:show(InfoMessage:new{
                    text = err_msg,
                    timeout = 3,
                })
            end
        end

        if not self.is_closed then
            self:refresh()
        end
    end)
end

function WiFiQuickPopup:toggleWifi()
    if self.is_wifi_on then
        -- Kill any in-flight background scan before tearing down WiFi,
        -- otherwise the orphaned subprocess and poll timer would interfere
        -- with the next WiFi-on cycle.
        cancelBgScan()
        self.is_scanning = false
        NetworkMgr._nonblocking_wifi_orig_toggleWifiOff(NetworkMgr, function()
            self.is_wifi_on = false
            self.network_list = {}
            cached_network_list = nil
            self:refresh()
            -- Chain the caller's disconnect callback (e.g., from promptWifiOff)
            if self.disconnect_callback then
                self.disconnect_callback()
            end
        end, true)
    else
        -- Guard against repeated taps while enabling
        if self.wifi_toggling then return end
        self.wifi_toggling = true
        self.wifi_toggle:setPosition(2)
        UIManager:setDirty(self, function()
            return "ui", self.popup.dimen
        end)
        UIManager:nextTick(function()
            if not self[1] then return end
            -- Notify plugins that a connection attempt is starting
            UIManager:broadcastEvent(Event:new("NetworkConnecting"))
            if Device:isKobo() then
                enableKoboWifi()
            else
                NetworkMgr:turnOnWifi()
            end
            self.wifi_toggling = false
            self.is_wifi_on = NetworkMgr:isWifiOn()
            if self.is_wifi_on then
                self:startScan()
            else
                UIManager:show(InfoMessage:new{ text = _("Error connecting to the network") })
                self:refresh()
            end
        end)
    end
end

function WiFiQuickPopup:onTapClose(arg, ges_ev)
    if ges_ev.pos:notIntersectWith(self.popup.dimen) then
        UIManager:close(self)
        return true
    end
end

function WiFiQuickPopup:onCloseWidget()
    self.is_closed = true
    if not NetworkMgr.pending_connectivity_check then
        NetworkMgr.pending_connection = false
    end
    if self.popup and self.popup.dimen then
        UIManager:setDirty(nil, "ui", self.popup.dimen)
    end
end

if not NetworkMgr._nonblocking_wifi_patch_applied then
    NetworkMgr._nonblocking_wifi_orig_toggleWifiOn = NetworkMgr.toggleWifiOn
    function NetworkMgr:toggleWifiOn(complete_callback, long_press, interactive)
        UIManager:show(WiFiQuickPopup:new{
            connect_callback = complete_callback,
        })
    end
    NetworkMgr._nonblocking_wifi_orig_toggleWifiOff = NetworkMgr.toggleWifiOff
    function NetworkMgr:toggleWifiOff(complete_callback, interactive)
        UIManager:show(WiFiQuickPopup:new{
            disconnect_callback = complete_callback,
        })
    end
    NetworkMgr._nonblocking_wifi_patch_applied = true
end

return WiFiQuickPopup
