local modname = debug.getinfo(1).source:match("%.%./mods/([^/]+)/")
local Widget = require "widgets/widget"
local TextButton = require "widgets/textbutton"
local my_userid = TheNet:GetUserID()
local function Say(str, whisper)
    TheNet:Say(str, whisper)
end

local function SayPing(ping, netscore, performance, packetloss, whisper) -- Ping，客户端网络性能，服务器性能，丢包率，是否为悄悄话
    local netscore = netscore and netscore + 1 -- LUA的Table表下标是从1开始的，所以+1
    local performance = performance and performance + 1

    if GetModConfigData("Announce_Style", modname, true) then -- 表情+文字
        local function CheckEmoji(emoji) -- 检查玩家是否有这个Emoji表情
            if TheInventory:CheckOwnership('emoji_' .. emoji) then
                return ':' .. emoji .. ':'
            else
                return ''
            end
        end

        local pingMessages = {
            {maxPing = 0, message = CheckEmoji('flex') .. STRINGS.SAYABOUTYOURPING.PING_NO_DELAY },
            {maxPing = 2, message = CheckEmoji('beefalo') .. STRINGS.SAYABOUTYOURPING.PING_LOCAL },
            {maxPing = 30, message = CheckEmoji('heart') .. STRINGS.SAYABOUTYOURPING.PING_LOW },
            {maxPing = 50, message = CheckEmoji('web') .. STRINGS.SAYABOUTYOURPING.PING_MEDIUM },
            {maxPing = 120, message = CheckEmoji('web') .. STRINGS.SAYABOUTYOURPING.PING_HIGH },
            {maxPing = 500, message = CheckEmoji('ghost') .. STRINGS.SAYABOUTYOURPING.PING_VERY_HIGH },
            {maxPing = math.huge, message = CheckEmoji('skull') .. STRINGS.SAYABOUTYOURPING.PING_EXTREME }
        }

        local function GetPingMessage(ping)
            for _, pingInfo in ipairs(pingMessages) do
                if ping < pingInfo.maxPing then
                    return string.format(pingInfo.message, ping)
                end
            end
        end

        local netscoreMessage_list = {
            STRINGS.SAYABOUTYOURPING.NETSCORE_GOOD,
            STRINGS.SAYABOUTYOURPING.NETSCORE_OKAY,
            STRINGS.SAYABOUTYOURPING.NETSCORE_BAD
        }
        local performanceMessage_list = {
            STRINGS.SAYABOUTYOURPING.PERFORMANCE_GOOD,
            STRINGS.SAYABOUTYOURPING.PERFORMANCE_OKAY,
            STRINGS.SAYABOUTYOURPING.PERFORMANCE_BAD
        }

        local netscoreMessage = netscoreMessage_list[netscore] and "   " .. netscoreMessage_list[netscore] or "" -- 客户端网络性能
        local performanceMessage = (performance and netscore and netscore == 1 and (STRINGS.SAYABOUTYOURPING.BUT .. performanceMessage_list[performance])) or (performance and "   " .. performanceMessage_list[performance]) or "" -- 服务器性能
        local message = GetPingMessage(ping) .. netscoreMessage .. performanceMessage .. (packetloss > 0 and ("   " .. STRINGS.SAYABOUTYOURPING.PACKETLOSS .. packetloss .. "%") or "") -- 最终消息
        Say(message, whisper)

    else -- 仅延迟
        Say(STRINGS.LMB.. "Ping: " ..ping.. "ms", whisper)
    end
end

local function LoadAndSetWidgetPosition(widget, identifier)
    local data = {}

    -- 从文件中加载数据
    TheSim:GetPersistentString("Say_about_your_ping.json", function(load_success, str)
        if load_success and string.len(str) > 0 then
            data = json.decode(str) or {}
        else
            print("[说说你的Ping] 未成功读取到数据记录文件，恢复Ping小部件至默认位置")
        end

        -- 获取特定控件的位置信息
        local widget_data = data[identifier]
        if widget_data then
            widget:SetPosition(widget_data.x, widget_data.y)
        end
    end)
end

local function SaveData(identifier, data)
    local save_data = LoadAndSetWidgetPosition() or {}
    save_data[identifier] = data
    -- 保存数据到本地文件
    TheSim:SetPersistentString("Say_about_your_ping.json", json.encode(save_data))
end

local function SaveWidgetPosition(widget, identifier)
    if not widget then return end

    local pos = widget:GetPosition()
    -- 将位置保存到文件中
    SaveData(identifier, { x = pos.x, y = pos.y })
end


local Ping = Class(Widget, function(self, owner)
    Widget._ctor(self, "Ping")
    self.root = self:AddChild(Widget("root"))

    self.ping = self.root:AddChild(TextButton())
    self.ping:SetFont(NUMBERFONT)
    self.ping:SetTextSize(40)

    self.vip = TheNet:GetUserID() == "KU_pvwb-aTV" -- 我知道你想干什么
    self.lastPingVal = nil
    self.lastpacketloss = nil
    self.cd = nil -- 宣告CD
    self.UpdatePingcd = nil -- 更新Ping值小部件的CD
    self.netscore = nil -- 客户端网络性能
    self.performance = nil -- 服务器性能
    self.need_update = true -- 需要更新显示数据

    self:StartUpdating()

    self.ping.OnMouseButton = function(_self, button, down, x, y)
        if button == MOUSEBUTTON_RIGHT and down then    --鼠标右键按下
            _self:BBGoat_FollowMouse()     --开启控件的鼠标跟随
        elseif button == MOUSEBUTTON_RIGHT then            --鼠标右键抬起
            _self:StopFollowMouse()        --停止控件的跟随
            SaveWidgetPosition(_self, "Position")
        end
    end

    -- 初始化小部件位置
    if GetModConfigData("remember", modname, true) then
        LoadAndSetWidgetPosition(self.ping, "Position")
    end

    self.ping:SetOnClick(function()
        if not self.cd then
            SayPing(self.lastPingVal, self.netscore, self.performance, self.lastpacketloss, TheInput:IsKeyDown(KEY_CTRL)) -- 宣告网络情况
            self.cd = true
            self.inst:DoTaskInTime(self.vip and 0 or 2, function() self.cd = nil end)
        end
    end)
end)

local COLOUR = {
    RED = RGB(242, 99, 99),
    YELLOW = RGB(222, 222, 99),
    GREEN = RGB(59, 242, 99)
}
local function GetColour(packetloss, default) -- 根据丢包率决定颜色(默认颜色)
    if packetloss > 25 then
        return COLOUR.RED
    elseif packetloss > 0 then
        return COLOUR.YELLOW
    else
        return default
    end
end
local Ping_Style = GetModConfigData("Ping_Style", modname, true)
local math_floor = math.floor
local type = type
local pairs = pairs

function Ping:OnUpdate(dt)
    local NetworkStatistics = TheNet:GetNetworkStatistics() or {}
    local pingVal = NetworkStatistics.ping or -1
    local msgs_sent_lastsec = NetworkStatistics.msgs_sent_lastsec or 0
    local msgs_resent_lastsec = NetworkStatistics.msgs_resent_lastsec or 0
    local packetloss = msgs_resent_lastsec > 0 and msgs_sent_lastsec > 0 and (math_floor(msgs_resent_lastsec / msgs_sent_lastsec * 1000 + 0.5) / 10) or 0 -- 上一秒的丢包率

    if pingVal ~= self.lastPingVal then
        self.need_update = true
    end

    if packetloss ~= self.lastpacketloss then
        self.need_update = true
    end

    local ClientObjs = TheNet:GetClientTable()
    if type(ClientObjs) == "table" then
        for _, k in pairs(ClientObjs) do
            if k.performance ~= nil then
                self.performance = type(k.performance) == "number" and k.performance > 0 and math.min(k.performance, 3) or nil -- 设置服务器性能，优秀时为nil，因为不需要宣告
                self.need_update = true
            end

            if k.userid == my_userid and k.netscore ~= nil then
                self.netscore = k.netscore -- 设置客户端网络性能
                self.need_update = true
            end
        end
    end

    if self.need_update then
        self.lastPingVal = pingVal
        self.lastpacketloss = packetloss
        self.need_update = false

        if pingVal == -1 then
            self.ping:SetText(STRINGS.SAYABOUTYOURPING.PING_SERVER)
            self.ping:SetTextColour(RGB(0, 255, 255))
        else
            local ping_text = "Ping: " .. pingVal .. "ms"
            local packetloss_text = STRINGS.SAYABOUTYOURPING.PACKETLOSS .. packetloss .. "%"
            if Ping_Style then
                if (self.netscore) == 2 then -- 客户端网络性能较差
                    self.ping:SetTextColour(COLOUR.RED)
                    self.ping:SetText(ping_text .. "\n" .. (packetloss > 0 and packetloss_text or STRINGS.SAYABOUTYOURPING.PING_NETSCORE_BAD))
                elseif (self.performance) == 2 then -- 服务器性能较差
                    self.ping:SetTextColour(COLOUR.RED)
                    self.ping:SetText((packetloss > 0 and packetloss_text or ping_text) .. "\n" .. STRINGS.SAYABOUTYOURPING.PING_PERFORMANCE_BAD)
                elseif (self.performance) == 1 then -- 服务器性能一般
                    self.ping:SetTextColour(GetColour(packetloss, COLOUR.YELLOW))
                    self.ping:SetText(ping_text .. "\n" .. (packetloss > 0 and packetloss_text or STRINGS.SAYABOUTYOURPING.PING_PERFORMANCE_OKAY))
                elseif (self.netscore) == 1 then -- 客户端网络性能一般
                    self.ping:SetTextColour(GetColour(packetloss, COLOUR.YELLOW))
                    self.ping:SetText(ping_text .. "\n" .. (packetloss > 0 and packetloss_text or STRINGS.SAYABOUTYOURPING.PING_NETSCORE_OKAY))
                elseif (self.netscore) == 0 and pingVal > 50 then -- 客户端网络性能优秀,延迟>50
                    self.ping:SetTextColour(GetColour(packetloss, COLOUR.YELLOW))
                    self.ping:SetText(ping_text .. "\n" .. (packetloss > 0 and packetloss_text or STRINGS.SAYABOUTYOURPING.PING_NETSCORE_GOOD))
                elseif (self.netscore) == 0 and pingVal <= 50 then -- 客户端网络性能优秀,延迟<=50
                    self.ping:SetTextColour(GetColour(packetloss, COLOUR.GREEN))
                    self.ping:SetText(ping_text .. "\n" .. (packetloss > 0 and packetloss_text or STRINGS.SAYABOUTYOURPING.PING_NETSCORE_GOOD))
                else
                    self.ping:SetText(ping_text .. (packetloss > 0 and ("\n" .. packetloss_text) or "")) -- 默认显示状态
                    if pingVal <= 50 then
                        self.ping:SetTextColour(GetColour(packetloss, COLOUR.GREEN)) -- 绿色
                    elseif pingVal <= 120 then
                        self.ping:SetTextColour(GetColour(packetloss, COLOUR.YELLOW)) -- 黄色
                    else
                        self.ping:SetTextColour(COLOUR.RED) -- 红色
                    end
                end
            else
                self.ping:SetText(ping_text) -- 仅显示延迟模式（根据Ping来决定颜色）
                if pingVal <= 50 then
                    self.ping:SetTextColour(COLOUR.GREEN) -- 绿色
                elseif pingVal <= 120 then
                    self.ping:SetTextColour(COLOUR.YELLOW) -- 黄色
                else
                    self.ping:SetTextColour(COLOUR.RED) -- 红色
                end
            end
        end
    end
end

return Ping