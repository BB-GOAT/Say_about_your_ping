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

function MOD_util:DoTaskInTime(time, fn)
    self.bbgoat_instance = self.bbgoat_instance or CreateEntity("bbgoat_instance")
    return self.bbgoat_instance:DoTaskInTime(time, fn)
end

function MOD_util:DoPeriodicTask(interval, fn)
    self.bbgoat_instance = self.bbgoat_instance or CreateEntity("bbgoat_instance")
    return self.bbgoat_instance:DoPeriodicTask(interval, fn)
end

-------------------------------------------------------------------------------------------

local native_lib
if TheNet:GetIsServer() and GetModConfigData("Sync_Ping") then
    local ok, ffi = _G.pcall(_G.require, "ffi")
    if ok and ffi.os == "Windows" and ffi.abi("64bit") then
        local cdef_ok = pcall(ffi.cdef, [[
            int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char*, int, unsigned short*, int);
            int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const unsigned short*, int, char*, int, const char*, int*);
            unsigned long __stdcall GetFullPathNameW(const unsigned short*, unsigned long, unsigned short*, void*);
            unsigned long __stdcall GetFileAttributesW(const unsigned short*);
            int PN_Status(void);
            int PN_QueryByUserid(const char* userid);
            int PN_QueryByUseridAvg(const char* userid);
        ]])
        if cdef_ok then
            -- 宽字符路径辅助：UTF-8 <-> UTF-16、绝对化（DLL 加载需要真实文件系统路径）
            local function Wide(text)
                local count = ffi.C.MultiByteToWideChar(65001, 8, text, -1, nil, 0)
                if count <= 0 then return nil end
                local buffer = ffi.new("unsigned short[?]", count)
                if ffi.C.MultiByteToWideChar(65001, 8, text, -1, buffer, count) <= 0 then return nil end
                return buffer
            end
            local function Utf8(wide)
                local count = ffi.C.WideCharToMultiByte(65001, 0, wide, -1, nil, 0, nil, nil)
                if count <= 0 then return nil end
                local buffer = ffi.new("char[?]", count)
                if ffi.C.WideCharToMultiByte(65001, 0, wide, -1, buffer, count, nil, nil) <= 0 then return nil end
                return ffi.string(buffer)
            end
            local function Full(path)
                local wpath = Wide(path)
                if not wpath then return nil end
                local buffer = ffi.new("unsigned short[32768]")
                if ffi.C.GetFullPathNameW(wpath, 32768, buffer, nil) <= 0 then return nil end
                return Utf8(buffer)
            end
            -- 候选目录：本地 mods 目录 + workshop 目录（本地开发目录与实际加载目录可能不同）
            local candidates = { Full(MODROOT) }
            local id = tostring(modname):match("^workshop%-(%d+)")
            local injector = _G.rawget(_G, "GameInjector")
            if id and injector and type(injector.DS_LUAJIT_get_workshop_dir) == "function" then
                local ok2, folder = pcall(injector.DS_LUAJIT_get_workshop_dir)
                if ok2 and type(folder) == "string" and folder ~= "" then
                    candidates[#candidates + 1] = Full(folder .. "/" .. id)
                end
            end
            -- 取 DLL 物理存在的第一个候选再加载，避免 io2 虚拟路径误导
            for _, dir in ipairs(candidates) do
                if dir and tonumber(ffi.C.GetFileAttributesW(Wide(dir .. "/pingspy_x64.dll"))) ~= 4294967295 then
                    local load_ok, lib = pcall(ffi.load, dir .. "/pingspy_x64.dll")
                    if load_ok then
                        native_lib = lib
                        break
                    end
                end
            end
        end
    end
end
return {
    MOD_util = MOD_util,
    native_lib = native_lib
}