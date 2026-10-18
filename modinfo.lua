local function zh_en(zh, en)  -- Other languages don't work
    local chinese_languages =
    {
        zh = "zh", -- Chinese for Steam
        zhr = "zh", -- Chinese for WeGame
        ch = "zh", -- Chinese mod
        chs = "zh", -- Chinese mod
        sc = "zh", -- simple Chinese
        zht = "zh", -- traditional Chinese for Steam
        tc = "zh", -- traditional Chinese
        cht = "zh", -- Chinese mod
    }

    if chinese_languages[locale] ~= nil then
        lang = chinese_languages[locale]
    else
        lang = en
    end

    return lang ~= "zh" and en or zh
end

name = zh_en("说说你的ping", "Say about your ping")
description = zh_en(
[[
开启后将在屏幕右下角显示你的Ping值，你可以点击它，点击后你的角色会在聊天中宣告你的Ping是多少。
右键可以拖拽Ping值的显示位置。更多信息/更新日志请在创意工坊上查看
]],
[[
After enabling, your Ping value will be displayed at the bottom right corner of the screen. You can click on it, and your character will announce your Ping in the chat.
Right-click to drag the display position of the Ping value. More information/Changelog can be found at the Creative Workshop
]]
)
author = "冰冰羊"
version = "4.2.8"
priority = -2
api_version = 10

dst_compatible = true
client_only_mod = true

icon_atlas = "atlas-0.xml"
icon = "atlas-0.tex"
configuration_options =
{
    {
        name = "lang",
        label = zh_en("语言", "Language"),
        hover = zh_en("选择你想要使用的语言", "Select the language you want to use"),
        options =
        {
            {description = "English(英语)", data = "en", hover = ""},
            {description = "中文(Chinese)", data = "zh", hover = ""},
            {description = zh_en("自动", "Auto"), data = "auto", hover = zh_en("根据游戏语言自动设置", "Automatically set according to the game language")},
        },
        default = "auto",
        client = true,
    },
    {
        name = "remember",
        label = zh_en("记住你设置的Ping的显示位置？", "Remember Ping position?"),
        hover = zh_en("如果你设置到了奇怪的地方 可以关闭此选项来复原位置\n这样就可以重新设置位置了，模组依然会保存你最后设置的位置", "If you set it to a strange place, you can turn off this option to restore the position\nYou can reset the position, and the mod will still save your last set position"),
        options =
        {
            {description = zh_en("是", "Yes"), hover = "" , data = true},
            {description = zh_en("否", "No"), hover = "", data = false},
        },
        default = true,
        client = true,
    },
    {
        name = "Chat_Command",
        label = zh_en("允许其他人使用聊天命令", "Allow Chat Commands"),
        hover = zh_en("开启后其他玩家可以使用聊天命令让你发送Ping值", "When enabled, other players can use chat commands to make you send your ping."),
        options =
        {
            {description = zh_en("是", "Yes"), hover = "" , data = true},
            {description = zh_en("否", "No"), hover = "", data = false},
        },
        default = true,
        client = true,
    },
    {
        name = "Ping_Style",
        label = zh_en("Ping小部件显示内容", "Ping widget display content"),
        hover = "",
        options =
        {
            {description = zh_en("延迟+客户端/服务器性能", "Ping + Performance"), hover = zh_en("Ping: 22(网络性能优秀)", "Ping: 22 (Client Performance: Good)"), data = true},
            {description = zh_en("仅延迟", "Only Ping"), hover = "Ping: 44" , data = false},
        },
        default = true,
        client = true,
    },
    {
        name = "Announce_Style",
        label = zh_en("宣告样式", "Announce style"),
        hover = zh_en("请选择你的宣告样式", "Please choose your announce style"),
        options =
        {
            {description = zh_en("表情(如果有)+文字+其它", "Emoji + Text + Others"), hover = zh_en("󰀗低延迟: 44ms。我时刻准备着！   解锁过的表情才会显示", "󰀗Low delay: 44ms. I'm always ready! Only unlocked emoticons will be displayed"), data = true},
            {description = zh_en("仅延迟", "Only Ping"), hover = "Ping: 44ms", data = false},
        },
        default = true,
        client = true,
    },
}