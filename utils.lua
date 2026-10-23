--给玩家加api 好处是不用官方的any接口
local MOD_util = {}
local allplayerfn = {}
local allplayerfn_once = {}
function MOD_util:AddPlayerPostInit(fn, onlyonce)
    if onlyonce then
        allplayerfn_once[fn] = true
    else
        allplayerfn[fn] = true
    end
end

AddPrefabPostInit("world", function(world)
    local a = true
    world:ListenForEvent("playeractivated", function(self, data) -- 仅对自己有效
        if a then
            a = false
            for fn, v in pairs(allplayerfn_once) do
                fn(self, data)
            end
        end
        for fn, v in pairs(allplayerfn) do
            fn(self, data)
        end
    end)
end)

-- function MOD_util:DoTaskInTime(time, fn)
--     self.bbgoat_instance = self.bbgoat_instance or CreateEntity("bbgoat_instance")
--     return self.bbgoat_instance:DoTaskInTime(time, fn)
-- end

-------------------------------------------------------------------------------------------

return {
    MOD_util = MOD_util,
}