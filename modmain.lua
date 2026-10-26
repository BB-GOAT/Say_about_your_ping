-- 自动查询全局变量
GLOBAL.setmetatable(env, {
    __index = function(t, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})

_G = GLOBAL
local _G = _G

local function Import(modulename, env)
    local f = _G.kleiloadlua(modulename)
    if f and type(f) == "function" then
        _G.setfenv(f, env or _G)
        return f()
    else
        local info = debug.getinfo(2)
        local filename, line = info.source or "???", info.currentline or "???"
        print("[警告] Import文件失败，文件名: " .. modulename .. "\n本函数调用于 " .. tostring(filename) .. ":" .. tostring(line))
    end
end
local utils = Import(MODROOT .. "utils.lua", env) -- 加载模组工具
local MOD_util = utils.MOD_util
-- 语言检测
local lang = GetModConfigData("lang", true) or "auto"
if lang == "auto" then
    lang = _G.LanguageTranslator.defaultlang
end

local chinese_languages =
{
    zh = "zh",  -- Chinese for Steam
    zhr = "zh", -- Chinese for WeGame
    ch = "zh",  -- Chinese mod
    chs = "zh", -- Chinese mod
    sc = "zh",  -- simple Chinese
    zht = "zh", -- traditional Chinese for Steam
    tc = "zh",  -- traditional Chinese
    cht = "zh", -- Chinese mod
}

if chinese_languages[lang] ~= nil then
    lang = chinese_languages[lang]
else
    lang = "en"
end

modimport("languages/" .. lang .. ".lua")                -- 加载翻译文件

local player_pings = {}                                  -- 存储玩家的Ping值
rawset(_G, "SayAboutYourPing_PlayerPings", player_pings) -- 允许其它模组获取Ping值数据

---------------------------------------------------------------------通过Luajit提供的接口获取玩家Ping值---------------------------------------------------------------------

local GetClientPing = TheNet.GetClientPing
if GetClientPing then
    AddSimPostInit(function()
        _G.staticScheduler:ExecutePeriodic(1, function()
            for _, client in ipairs(AllPlayers or {}) do
                local userid = client.userid
                if userid ~= nil and userid ~= "" then
                    local ping = TheNet:GetClientPing(userid)
                    if ping ~= nil and ping >= 0 and player_pings[userid] ~= ping then
                        player_pings[userid] = ping -- 原生值为权威数据，仅在变化时广播
                        SendModRPCToShard(SHARD_MOD_RPC["show_ping"]["send_ping"], nil, userid, ping)
                        SendModRPCToClient(CLIENT_MOD_RPC["show_ping"]["sync_ping"], nil, userid, ping)
                    end
                end
            end
        end)
    end)
end

local function printinvalid(rpcname, player)
    print(string.format("[Say about your ping(Server)] Invalid %s RPC from (%s) %s", rpcname, player.userid or "", player.name or ""))

    --This event is for MODs that want to handle players sending invalid rpcs
    TheWorld:PushEvent("invalidrpc", { player = player, rpcname = rpcname })
end

-- 服务器：将接收到的数据转发给其它人
AddModRPCHandler("show_ping", "send_ping", function(player, ping)
    if not checknumber(ping) then
        printinvalid("show_ping.send_ping", player)
        return
    end
    if GetClientPing then
        if not player.show_ping_send_native_active then
            player.show_ping_send_native_active = true
            SendModRPCToClient(CLIENT_MOD_RPC["show_ping"]["native_active"], player.userid) -- 取消玩家的上报task
        end
        return
    end
    SendModRPCToShard(SHARD_MOD_RPC["show_ping"]["send_ping"], nil, player.userid, ping)
    SendModRPCToClient(CLIENT_MOD_RPC["show_ping"]["sync_ping"], nil, player.userid, ping)
end)

-- 多层世界数据传输
AddShardModRPCHandler("show_ping", "send_ping", function(shardId, userid, ping)
    if TheShard:GetShardId() ~= tostring(shardId) then
        SendModRPCToClient(CLIENT_MOD_RPC["show_ping"]["sync_ping"], nil, userid, ping)
    end
end)

-- 客户端：接收数据
local playerstatusscreen
AddClientModRPCHandler("show_ping", "sync_ping", function(userid, ping)
    player_pings[userid] = ping
    if playerstatusscreen and playerstatusscreen.scroll_list then
        if not playerstatusscreen.scroll_list.inst:IsValid() then return end
        playerstatusscreen.scroll_list:RefreshView() -- 刷新一次计分板数据
    end
end)

-- 客户端：服务器表示已启用原生采集，取消本地上报任务
local reporter_task
AddClientModRPCHandler("show_ping", "native_active", function()
    if reporter_task then
        reporter_task:Cancel()
        reporter_task = nil
    end
end)

---------------------------------------------------------------------以下为客户端部分---------------------------------------------------------------------

if TheNet:IsDedicated() then return end

if GetModConfigData("Sync_Ping") then -- 是否开启“共享Ping值”
    -- 将Ping值显示在计分板内
    AddClassPostConstruct("screens/playerstatusscreen", function(self)
        local old_DoInit = self.DoInit
        function self:DoInit(...)
            old_DoInit(self, ...)

            if not self.scroll_list.sayaboutyourping_old_update then
                -- 滚动列表时刷新
                if self.scroll_list and self.scroll_list.updatefn then
                    self.scroll_list.sayaboutyourping_old_update = self.scroll_list.updatefn
                    self.scroll_list.updatefn = function(playerListing, client, i, ...)
                        self.scroll_list.sayaboutyourping_old_update(playerListing, client, i, ...)
                        if not playerListing.shown then return end
                        if client.netscore ~= nil then
                            local perf_id = math.min(client.netscore + 1, 3)
                            local ping = player_pings[playerListing.userid]
                            if ping and perf_id and not playerListing.ishost then
                                playerListing.perf:SetHoverText(STRINGS.UI.PLAYERSTATUSSCREEN.PERF_CLIENT_LEVELS[perf_id] .. "\tPing: ".. ping .."ms")
                            end
                        end
                    end
                end

                self.scroll_list:RefreshView()

                playerstatusscreen = self
            end
        end
    end)

    ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

    -- Ping值变化 + 服务器未启用原生采集功能 发送RPC同步至服务器
    local lastPingVal
    MOD_util:AddPlayerPostInit(function(world, player)
        if player ~= ThePlayer then return end
        reporter_task = player:DoPeriodicTask(1, function()
            local pingVal = TheNet:GetPing()
            if lastPingVal ~= pingVal then
                SendModRPCToServer(MOD_RPC["show_ping"]["send_ping"], pingVal)
                lastPingVal = pingVal
            end
        end)
    end)
end

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

if not TUNING.SAYABOUTYOURPING_MODCONFIGDATA then TUNING.SAYABOUTYOURPING_MODCONFIGDATA = {} end
if TUNING.SAYABOUTYOURPING_MODCONFIGDATA["show_ping_client"] then
    print("说说你的Ping-服务器版: 检测到客户端版说说你的Ping已开启,停止加载服务器版的部分功能")
    return
end

local ping = Import(MODROOT .. "ping.lua")
local myname = TheNet:GetLocalUserName()
local last_say
local function Say(str)
    TheNet:Say(str)
    last_say = GetTime()
end

-- 捕获聊天信息，存在关键词就发送自己的Ping
if not TheNet:GetIsServer() and GetModConfigData("Chat_Command", true) then -- 判断当前机器是不是服务端，非服务端才能执行这个代码，否则崩溃
    local oldNetworking_Say = _G.Networking_Say
    _G.Networking_Say = function(guid, userid, name, prefab, message, ...)
        local low_str = string.lower(message or "")
        if low_str == "#所有人宣告ping" or
            low_str == "#@" .. myname .. " ping" or
            low_str == STRINGS.LMB .. ' ' .. "#@" .. myname .. " ping" or -- 兼容快捷宣告(NoMu)触发的，如果有人想在自定义宣告中触发本模组的指令
            low_str == "#allping"
        then
            if not last_say or GetTime() - last_say > 10 then
                if TheNet:GetPing() <= 2 then
                    Say(string.format(STRINGS.SAYABOUTYOURPING.PING_LOCAL, TheNet:GetPing()))
                elseif TheNet:GetPing() <= 30 then
                    Say(string.format(STRINGS.SAYABOUTYOURPING.PING_LOW, TheNet:GetPing()))
                elseif TheNet:GetPing() <= 50 then
                    Say(string.format(STRINGS.SAYABOUTYOURPING.PING_MEDIUM, TheNet:GetPing()))
                elseif TheNet:GetPing() <= 120 then
                    Say(string.format(STRINGS.SAYABOUTYOURPING.PING_HIGH, TheNet:GetPing()))
                elseif TheNet:GetPing() <= 500 then
                    Say(string.format(STRINGS.SAYABOUTYOURPING.PING_VERY_HIGH, TheNet:GetPing()))
                else
                    Say(string.format(STRINGS.SAYABOUTYOURPING.PING_EXTREME, TheNet:GetPing()))
                end
            end
        end
        return oldNetworking_Say(guid, userid, name, prefab, message, ...)
    end
end

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

AddClassPostConstruct("widgets/controls", function(self)
    self.ping = self.bottom_root:AddChild(ping())
    self.ping:SetPosition(625, 35)
end)

local function ModFollowMouse(self)
    --GetWorldPosition获得的坐标是基于屏幕原点的，默认为左下角，当单独设置了原点的时候，这个函数返回的结果和GetPosition的结果一样了，达不到我们需要的效果
    --因为官方没有提供查询原点坐标的接口，所以需要修改设置原点的两个函数，将原点位置记录在widget上
    --注意：虽然默认的屏幕原点为左下角，但是每个widget默认的坐标原点为其父级的屏幕坐标；
    --而当你单独设置了原点坐标后，不仅其屏幕原点改变了，而且坐标原点的位置也改变为屏幕原点了
    local old_sva = self.SetVAnchor
    self.SetVAnchor = function(_self, anchor)
        self.v_anchor = anchor
        return old_sva(_self, anchor)
    end

    local old_sha = self.SetHAnchor
    self.SetHAnchor = function(_self, anchor)
        self.h_anchor = anchor
        return old_sha(_self, anchor)
    end

    --默认的原点坐标为父级的坐标，如果widget上有v_anchor和h_anchor这两个变量，就说明改变了默认的原点坐标
    --我们会在GetMouseLocalPos函数里检查这两个变量，以对这种情况做专门的处理
    --这个函数可以将鼠标坐标从屏幕坐标系下转换到和wiget同一个坐标系下
    local function GetMouseLocalPos(ui, mouse_pos)                   --ui: 要拖拽的widget, mouse_pos: 鼠标的屏幕坐标(Vector3对象)
        local g_s = ui:GetScale()                                    --ui的全局缩放值
        local l_s = Vector3(0, 0, 0)
        l_s.x, l_s.y, l_s.z = ui:GetLooseScale()                     --ui本身的缩放值
        local scale = Vector3(g_s.x / l_s.x, g_s.y / l_s.y, g_s.z / l_s.z) --父级的全局缩放值

        local ui_local_pos = ui:GetPosition()                        --ui的相对位置（也就是SetPosition的时候传递的坐标）
        ui_local_pos = Vector3(ui_local_pos.x * scale.x, ui_local_pos.y * scale.y, ui_local_pos.z * scale.z)
        local ui_world_pos = ui:GetWorldPosition()
        --如果修改过ui的屏幕原点，就重新计算ui的屏幕坐标（基于左下角为原点的）
        if not (not ui.v_anchor or ui.v_anchor == ANCHOR_BOTTOM) or not (not ui.h_anchor or ui.h_anchor == ANCHOR_LEFT) then
            local screen_w, screen_h = TheSim:GetScreenSize()    --获取屏幕尺寸（宽度，高度）
            if ui.v_anchor and ui.v_anchor ~= ANCHOR_BOTTOM then --如果修改了原点的垂直坐标
                ui_world_pos.y = ui.v_anchor == ANCHOR_MIDDLE and screen_h / 2 + ui_world_pos.y or
                screen_h - ui_world_pos.y
            end
            if ui.h_anchor and ui.h_anchor ~= ANCHOR_LEFT then --如果修改了原点的水平坐标
                ui_world_pos.x = ui.h_anchor == ANCHOR_MIDDLE and screen_w / 2 + ui_world_pos.x or
                screen_w - ui_world_pos.x
            end
        end

        local origin_point = ui_world_pos - ui_local_pos --原点坐标
        mouse_pos = mouse_pos - origin_point

        return Vector3(mouse_pos.x / scale.x, mouse_pos.y / scale.y, mouse_pos.z / scale.z) --鼠标相对于UI父级坐标的局部坐标
    end

    --定义自己的鼠标跟随，以适应所有情况(垃圾科雷)
    self.BBGoat_FollowMouse = function(_self)
        if _self.followhandler == nil then
            _self.followhandler = TheInput:AddMoveHandler(function(x, y)
                local loc_pos = GetMouseLocalPos(_self, Vector3(x, y, 0)) --主要是将原本的x,y坐标进行了坐标系的转换，使用转换后的坐标来更新widget位置
                _self:UpdatePosition(loc_pos.x, loc_pos.y)
            end)
            _self:SetPosition(GetMouseLocalPos(_self, TheInput:GetScreenPosition()))
        end
    end
end
AddClassPostConstruct("widgets/widget", ModFollowMouse)