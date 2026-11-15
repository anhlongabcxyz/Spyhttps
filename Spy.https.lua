local Options = {
    SaveLogs = false,
    MaxEntries = 150,
    PreviewLimit = 200,
    StartPaused = false,
    Follow = false,
    HookDirect = true,
    BlockedURLs = {},
}
do
    local user = ({ ... })[1]
    if type(user) == "table" then
        for k, v in pairs(user) do Options[k] = v end
    end
end

local VERSION = "v2.0"
local GAME = game
local genv = (getgenv and getgenv()) or _G

if type(genv.HttpSpy) == "table" and type(genv.HttpSpy.Unload) == "function" then
    pcall(genv.HttpSpy.Unload)
end

local cloneref = cloneref or function(x) return x end
local newcc = newcclosure or function(f) return f end
local setclip = setclipboard or toclipboard or (type(Clipboard) == "table" and Clipboard.set) or nil

local Players = cloneref(GAME:GetService("Players"))
local UIS = cloneref(GAME:GetService("UserInputService"))
local CoreGui = cloneref(GAME:GetService("CoreGui"))

local State = {
    enabled = not Options.StartPaused,
    unloaded = false,
    follow = Options.Follow == true,
    filter = "",
}

local Blocked, BlockPatterns, ResponseHooks, Proxies = {}, {}, {}, {}
for k, v in pairs(Options.BlockedURLs or {}) do
    if type(k) == "number" then Blocked[v] = true else Blocked[k] = v and true or nil end
end

local busy = setmetatable({}, { __mode = "k" })

local Conns = {}
local OnRequest = Instance.new("BindableEvent")

local function fmtNum(n)
    local s = tostring(math.floor(n))
    local out = string.reverse(string.gsub(string.reverse(s), "(%d%d%d)", "%1,"))
    if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
    return out
end

local function fmtTime(dt)
    if dt < 1 then return string.format("%d ms", math.floor(dt * 1000 + 0.5)) end
    return string.format("%.2f s", dt)
end
local function clip(s, n)
    s = tostring(s)
    if #s > n then return string.sub(s, 1, n) .. "..." end
    return s
end

local function deepCopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local c = {}
    seen[t] = c
    for k, v in pairs(t) do c[deepCopy(k, seen)] = deepCopy(v, seen) end
    return c
end

local function serialize(v, indent, seen)
    indent = indent or ""
    seen = seen or {}
    local tv = type(v)
    if tv == "string" then return string.format("%q", v) end
    if tv ~= "table" then return tostring(v) end
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    if #keys == 0 then seen[v] = nil return "{}" end
    local inner = indent .. "    "
    local parts = {}
    for _, k in ipairs(keys) do
        local ks = (type(k) == "string" and string.match(k, "^[%a_][%w_]*$")) and k
            or ("[" .. serialize(k, inner, seen) .. "]")
        parts[#parts + 1] = inner .. ks .. " = " .. serialize(v[k], inner, seen)
    end
    seen[v] = nil
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function isBlocked(url)
    if Blocked[url] then return true end
    for _, p in ipairs(BlockPatterns) do
        if string.find(url, p, 1, true) then return true end
    end
    return false
end

local function guarded(fn, ...)
    local th = coroutine.running()
    local was = busy[th]
    busy[th] = true
    local res = table.pack(pcall(fn, ...))
    busy[th] = was
    return res
end

local function fireOnRequest(data)
    pcall(function() OnRequest:Fire(data) end)
end

local logName
if Options.SaveLogs and writefile and appendfile then
    logName = string.format("HttpSpy_%d_%s.txt", GAME.PlaceId, os.date("%Y-%m-%d_%H-%M-%S"))
    pcall(writefile, logName, "HttpSpy " .. VERSION .. " - " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
end

local rgb = Color3.fromRGB
local C = {
    bg = rgb(15, 15, 19),
    panel = rgb(23, 23, 29),
    panel2 = rgb(31, 31, 39),
    stroke = rgb(44, 44, 54),
    strokeHi = rgb(85, 85, 100),
    text = rgb(232, 232, 240),
    dim = rgb(155, 155, 170),
    faint = rgb(105, 105, 120),
    accent = rgb(230, 60, 72),
    green = rgb(80, 205, 125),
    red = rgb(235, 75, 85),
}
local BADGE = {
    GET = rgb(85, 155, 255),
    POST = rgb(255, 165, 65),
    PUT = rgb(175, 115, 255),
    PATCH = rgb(175, 115, 255),
    DELETE = rgb(235, 75, 85),
    OBJ = rgb(90, 205, 205),
    WS = rgb(70, 205, 160),
    INFO = rgb(140, 140, 155),
}

local function new(class, props, kids)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then o[k] = v end
    end
    for _, c in ipairs(kids or {}) do c.Parent = o end
    if props and props.Parent then o.Parent = props.Parent end
    return o
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function stroke(col) return new("UIStroke", { Color = col, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) end
local function padding(t, r, b, l)
    return new("UIPadding", {
        PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r),
        PaddingBottom = UDim.new(0, b), PaddingLeft = UDim.new(0, l),
    })
end

local function button(props, kids)
    local st = stroke(C.stroke)
    local base = {
        AutoButtonColor = false, BackgroundColor3 = C.panel2, BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.text,
    }
    for k, v in pairs(props) do base[k] = v end
    local all = { corner(5), st }
    for _, k in ipairs(kids or {}) do all[#all + 1] = k end
    local b = new("TextButton", base, all)
    b.MouseEnter:Connect(function() st.Color = C.strokeHi end)
    b.MouseLeave:Connect(function() st.Color = C.stroke end)
    return b
end

local function copyTo(btn, text, idleColor)
    local label = btn:GetAttribute("label") or btn.Text
    btn:SetAttribute("label", label)
    local ok = setclip ~= nil and pcall(setclip, text)
    btn.Text = ok and "Copied" or "No clipboard"
    btn.TextColor3 = ok and C.green or C.red
    task.delay(1.2, function()
        if btn.Parent then
            btn.Text = label
            btn.TextColor3 = idleColor or C.dim
        end
    end)
end

local Gui = new("ScreenGui", {
    Name = "ServerDead_" .. tostring(math.random(100000, 999999)),
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
})
if type(syn) == "table" and syn.protect_gui then pcall(syn.protect_gui, Gui) end
if not pcall(function() Gui.Parent = (gethui and gethui()) or CoreGui end) then
    Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

local Main = new("Frame", {
    Size = UDim2.fromOffset(620, 400),
    Position = UDim2.new(0.5, -310, 0.5, -200),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Parent = Gui,
}, { corner(8), stroke(C.stroke) })
local TitleBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
    Parent = Main,
}, {
    corner(8),
    new("Frame", {
        Size = UDim2.new(1, 0, 0, 8), Position = UDim2.new(0, 0, 1, -8),
        BackgroundColor3 = C.panel, BorderSizePixel = 0,
    }),
})

new("TextLabel", {
    Size = UDim2.new(0, 70, 1, 0), Position = UDim2.fromOffset(12, 0),
    BackgroundTransparency = 1, Text = "HttpSpy", TextColor3 = C.text,
    Font = Enum.Font.GothamBold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TitleBar,
})
new("TextLabel", {
    Size = UDim2.new(0, 60, 1, 0), Position = UDim2.fromOffset(76, 1),
    BackgroundTransparency = 1, Text = VERSION, TextColor3 = C.faint,
    Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TitleBar,
})

local TitleButtons = new("Frame", {
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
    Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X,
    BackgroundTransparency = 1, Parent = TitleBar,
}, {
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
    }),
})

local StatusBtn = button({ Size = UDim2.fromOffset(96, 22), TextSize = 11, Font = Enum.Font.GothamBold, LayoutOrder = 1, Parent = TitleButtons })
local MinBtn = button({ Size = UDim2.fromOffset(22, 22), Text = "-", TextSize = 14, LayoutOrder = 2, Parent = TitleButtons })
local CloseBtn = button({ Size = UDim2.fromOffset(22, 22), Text = "X", TextSize = 13, TextColor3 = C.red, LayoutOrder = 3, Parent = TitleButtons })

local Toolbar = new("Frame", {
    Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 38),
    BackgroundTransparency = 1, Parent = Main,
})
local FilterBox = new("TextBox", {
    Position = UDim2.new(0, 8, 0.5, -12), Size = UDim2.new(1, -262, 0, 24),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, ClearTextOnFocus = false,
    PlaceholderText = "Filter by URL or method", PlaceholderColor3 = C.faint,
    Text = "", TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left, ClipsDescendants = true, Parent = Toolbar,
}, { corner(5), stroke(C.stroke), padding(0, 8, 0, 8) })
local FollowBtn = button({ Position = UDim2.new(1, -246, 0.5, -12), Size = UDim2.fromOffset(80, 24), TextColor3 = C.dim, Parent = Toolbar })
local ClearBtn = button({ Position = UDim2.new(1, -160, 0.5, -12), Size = UDim2.fromOffset(64, 24), Text = "Clear", TextColor3 = C.dim, Parent = Toolbar })
local CountLabel = new("TextLabel", {
    Position = UDim2.new(1, -90, 0.5, -12), Size = UDim2.fromOffset(82, 24),
    BackgroundTransparency = 1, Text = "0 logs", TextColor3 = C.faint,
    Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right,
    Parent = Toolbar,
})

local LIST_PAD = 6
local Logs = new("ScrollingFrame", {
    Position = UDim2.fromOffset(8, 72), Size = UDim2.new(1, -14, 1, -82),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.None,
    ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 5,
    ScrollBarImageColor3 = C.strokeHi, VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
    Parent = Main,
}, { padding(2, 6, 2, 0) })
local Layout = new("UIListLayout", { Padding = UDim.new(0, LIST_PAD), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Logs })

local EmptyLabel = new("TextLabel", {
    Position = UDim2.fromOffset(8, 72), Size = UDim2.new(1, -16, 1, -82),
    BackgroundTransparency = 1, Text = "No requests yet", TextColor3 = C.faint,
    Font = Enum.Font.Gotham, TextSize = 13, Parent = Main,
})

local NewPill = button({
    AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16),
    Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X,
    BackgroundColor3 = C.accent, TextColor3 = rgb(255, 255, 255), Font = Enum.Font.GothamBold,
    TextSize = 12, Visible = false, ZIndex = 5, Parent = Main,
}, { padding(0, 12, 0, 12) })

local Grip = new("TextButton", {
    AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -2, 1, -2), Size = UDim2.fromOffset(14, 14),
    BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 6, Parent = Main,
}, {
    new("Frame", {
        AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -2, 1, -2), Size = UDim2.fromOffset(6, 6),
        BackgroundColor3 = C.faint, BorderSizePixel = 0, ZIndex = 6,
    }, { corner(1) }),
})

local Icon = button({
    Size = UDim2.fromOffset(44, 44), Position = UDim2.new(0.5, -22, 0, 8),
    BackgroundColor3 = C.panel, Text = "H", TextSize = 20, Font = Enum.Font.GothamBold,
    Visible = false, ZIndex = 10, Parent = Gui,
})

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
local function isMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

local function makeDraggable(handle, target, onClick)
    local dragging, moved, startInput, startPos = false, false, nil, nil
    handle.InputBegan:Connect(function(input)
        if not isPointer(input) then return end
        dragging, moved = true, false
        startInput, startPos = input.Position, target.Position
        local con
        con = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                con:Disconnect()
                dragging = false
                if not moved and onClick then onClick() end
            end
        end)
    end)
    Conns[#Conns + 1] = UIS.InputChanged:Connect(function(input)
        if not dragging or not isMove(input) then return end
        local d = input.Position - startInput
        if not moved and d.Magnitude < 4 then return end
        moved = true
        target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end)
end

makeDraggable(TitleBar, Main)

do
    local resizing, startInput, startSize = false, nil, nil
    Grip.InputBegan:Connect(function(input)
        if not isPointer(input) then return end
        resizing, startInput, startSize = true, input.Position, Main.AbsoluteSize
        local con
        con = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                con:Disconnect()
                resizing = false
            end
        end)
    end)
    Conns[#Conns + 1] = UIS.InputChanged:Connect(function(input)
        if not resizing or not isMove(input) then return end
        local d = input.Position - startInput
        Main.Size = UDim2.fromOffset(math.max(460, startSize.X + d.X), math.max(260, startSize.Y + d.Y))
    end)
end

local Records = {}
local newBelow = 0
local wantBottomAt = nil

local function maxScroll()
    return math.max(0, Logs.CanvasSize.Y.Offset - Logs.AbsoluteWindowSize.Y)
end
local function isAtBottom()
    return Logs.CanvasPosition.Y >= maxScroll() - 10
end
local function scrollBottom()
    Logs.CanvasPosition = Vector2.new(0, maxScroll())
end
local function refreshPill()
    if isAtBottom() then newBelow = 0 end
    NewPill.Visible = newBelow > 0
    NewPill.Text = newBelow .. " new - jump to bottom"
end
local function requestStick()
    if State.follow and isAtBottom() then wantBottomAt = os.clock() end
end

Layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    Logs.CanvasSize = UDim2.fromOffset(0, Layout.AbsoluteContentSize.Y + 6)
    if wantBottomAt and os.clock() - wantBottomAt < 1 then scrollBottom() end
    wantBottomAt = nil
    refreshPill()
end)
Logs:GetPropertyChangedSignal("CanvasPosition"):Connect(refreshPill)
NewPill.MouseButton1Click:Connect(function()
    newBelow = 0
    scrollBottom()
    refreshPill()
end)

local function matches(rec)
    return State.filter == "" or string.find(rec.search, State.filter, 1, true) ~= nil
end

local function updateCount()
    local visible = 0
    for _, r in ipairs(Records) do
        if r.frame and r.frame.Visible then visible += 1 end
    end
    CountLabel.Text = State.filter ~= "" and (visible .. " / " .. #Records) or (#Records .. (#Records == 1 and " log" or " logs"))
    EmptyLabel.Visible = visible == 0
    EmptyLabel.Text = #Records == 0 and "No requests yet" or "Nothing matches the filter"
end

local function trim()
    while #Records > Options.MaxEntries do
        local old = table.remove(Records, 1)
        if old.frame then
            local h = old.frame.Visible and (old.frame.AbsoluteSize.Y + LIST_PAD) or 0
            old.frame:Destroy()
            old.frame = nil

            if h > 0 and not wantBottomAt then
                Logs.CanvasPosition = Vector2.new(0, math.max(0, Logs.CanvasPosition.Y - h))
            end
        end
    end
end

local function infoText(rec)
    local p = {}
    if rec.statusCode then
        local msg = (type(rec.statusMsg) == "string" and rec.statusMsg ~= "") and (" " .. rec.statusMsg) or ""
        p[#p + 1] = "HTTP " .. tostring(rec.statusCode) .. msg
    end
    if rec.state == "pending" then
        p[#p + 1] = "waiting for response..."
    elseif rec.state == "blocked" then
        p[#p + 1] = "Blocked"
    elseif rec.state == "error" then
        p[#p + 1] = "Error: " .. clip(rec.err or "?", 160)
    elseif rec.count then
        p[#p + 1] = "Returned " .. fmtNum(rec.count) .. (rec.count == 1 and " object" or " objects")
    elseif rec.body then
        p[#p + 1] = #rec.body == 0 and "Empty response" or ("Response: " .. fmtNum(#rec.body) .. " characters")
    elseif rec.note then
        p[#p + 1] = rec.note
    end
    if rec.sent then p[#p + 1] = "Sent: " .. fmtNum(#rec.sent) .. " characters" end
    if rec.dt and (rec.state == "done" or rec.state == "error") then p[#p + 1] = fmtTime(rec.dt) end
    return table.concat(p, "  |  ")
end

local function writeLog(rec)
    if not logName then return end
    pcall(appendfile, logName, string.format("[%s] %-6s %-16s %s\n         %s\n", rec.time, rec.badge, rec.source, rec.url, infoText(rec)))
end

local function smallButton(text, order, parent)
    return button({
        Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X,
        Text = text, TextSize = 11, TextColor3 = C.dim, LayoutOrder = order, Parent = parent,
    }, { padding(0, 8, 0, 8) })
end

local function buildEntry(rec)
    if State.unloaded then return end
    local wasBottom = isAtBottom()
    local col = BADGE[rec.badge] or BADGE.INFO
    local isSys = rec.badge == "INFO"

    local frame = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = C.panel, BorderSizePixel = 0, LayoutOrder = rec.id,
    }, {
        corner(6),
        padding(7, 8, 8, 10),
        new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
    })
    local frameStroke = stroke(C.stroke)
    frameStroke.Parent = frame

    local header = new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = 1, Parent = frame })
    local left = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = header }, {
        new("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
            VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
    new("TextLabel", {
        Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = col, BackgroundTransparency = 0.82, Text = rec.badge, TextColor3 = col,
        Font = Enum.Font.GothamBold, TextSize = 11, LayoutOrder = 1, Parent = left,
    }, { corner(4), padding(0, 6, 0, 6) })
    new("TextLabel", {
        Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1,
        Text = rec.time .. (rec.source ~= "" and ("   " .. rec.source) or ""), TextColor3 = C.faint,
        Font = Enum.Font.Gotham, TextSize = 11, LayoutOrder = 2, Parent = left,
    })

    local btns = new("Frame", {
        AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
        Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1, Parent = header,
    }, {
        new("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
            HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })

    local respBtn
    if isSys then
        btns.Visible = false
    else
        local urlBtn = smallButton("URL", 1, btns)
        urlBtn.MouseButton1Click:Connect(function() copyTo(urlBtn, rec.url) end)
        if rec.request then
            local reqBtn = smallButton("Request", 2, btns)
            reqBtn.MouseButton1Click:Connect(function() copyTo(reqBtn, serialize(rec.request)) end)
        end
        respBtn = smallButton("Copy response", 3, btns)
        respBtn.TextColor3 = C.text
        respBtn.Visible = false
        respBtn.MouseButton1Click:Connect(function()
            copyTo(respBtn, rec.body or rec.copyText or "", C.text)
        end)
    end

    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Text = clip(rec.url, 500), TextColor3 = isSys and C.dim or C.text, TextWrapped = true,
        Font = isSys and Enum.Font.Gotham or Enum.Font.RobotoMono, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        LayoutOrder = 2, Parent = frame,
    })

    local info = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Text = "", TextColor3 = C.dim, TextWrapped = true, Font = Enum.Font.GothamMedium, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 3, Parent = frame,
    })

    local preview = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = C.bg, BorderSizePixel = 0, Visible = false, LayoutOrder = 4, Parent = frame,
    }, { corner(4), padding(6, 8, 6, 8) })
    local previewText = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Text = "", TextColor3 = rgb(200, 220, 200), TextWrapped = true, Font = Enum.Font.RobotoMono,
        TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        Parent = preview,
    })

    rec.refresh = function()
        if not rec.frame or not rec.frame.Parent then return end
        requestStick()
        local text = infoText(rec)
        info.Text = text
        info.Visible = text ~= ""
        local bad = rec.state == "error" or rec.state == "blocked"
        info.TextColor3 = bad and C.red or (rec.state == "pending" and C.faint or C.dim)
        frameStroke.Color = bad and rgb(90, 40, 46) or C.stroke
        local body = rec.body
        local show = type(body) == "string" and #body > 0 and #body <= Options.PreviewLimit
        preview.Visible = show
        if show then previewText.Text = body end

        if respBtn then
            local copyable = (type(body) == "string" and #body > 0) or (rec.copyText and #rec.copyText > 0)
            respBtn.Visible = copyable and true or false
        end
    end

    rec.frame = frame
    frame.Visible = matches(rec)
    rec.refresh()
    frame.Parent = Logs
    Records[#Records + 1] = rec

    if frame.Visible then
        if State.follow and wasBottom then
            wantBottomAt = os.clock()
        else
            newBelow += 1
        end
    end
    trim()
    updateCount()
end

local Seq = 0
local function newRecord(badge, source, url)
    Seq += 1
    local rec = {
        id = Seq, badge = badge, source = source, url = url or "",
        t0 = os.clock(), time = os.date("%H:%M:%S"), state = "pending",
    }
    rec.search = string.lower(badge .. " " .. source .. " " .. rec.url)

    task.defer(buildEntry, rec)
    return rec
end

local function finishRecord(rec, fields)
    for k, v in pairs(fields) do rec[k] = v end
    rec.dt = os.clock() - rec.t0
    if rec.refresh then task.defer(rec.refresh) end
    writeLog(rec)
end

local function sysRecord(text)
    local rec = newRecord("INFO", "", text)
    finishRecord(rec, { state = "done" })
end

local function paintStatus()
    StatusBtn.Text = State.enabled and "ENABLED" or "DISABLED"
    StatusBtn.TextColor3 = State.enabled and C.green or C.red
    StatusBtn.BackgroundColor3 = State.enabled and rgb(24, 44, 32) or rgb(50, 26, 30)
    Icon.TextColor3 = State.enabled and C.text or C.red
end
local function paintFollow()
    FollowBtn.Text = State.follow and "Following" or "Follow"
    FollowBtn.TextColor3 = State.follow and C.text or C.dim
    FollowBtn.BackgroundColor3 = State.follow and rgb(48, 30, 36) or C.panel2
end

local function setEnabled(v)
    State.enabled = v and true or false
    paintStatus()
end

local function clearLogs()
    for _, r in ipairs(Records) do
        if r.frame then r.frame:Destroy() r.frame = nil end
    end
    table.clear(Records)
    newBelow = 0
    Logs.CanvasPosition = Vector2.zero
    refreshPill()
    updateCount()
end

StatusBtn.MouseButton1Click:Connect(function() setEnabled(not State.enabled) end)
FollowBtn.MouseButton1Click:Connect(function()
    State.follow = not State.follow
    paintFollow()
    if State.follow then scrollBottom() end
end)
ClearBtn.MouseButton1Click:Connect(clearLogs)

FilterBox:GetPropertyChangedSignal("Text"):Connect(function()
    State.filter = string.lower(FilterBox.Text)
    for _, r in ipairs(Records) do
        if r.frame then r.frame.Visible = matches(r) end
    end
    newBelow = 0
    refreshPill()
    updateCount()
end)

MinBtn.MouseButton1Click:Connect(function()
    Main.Visible = false
    Icon.Visible = true
end)
makeDraggable(Icon, Icon, function()
    Icon.Visible = false
    Main.Visible = true
end)

paintStatus()
paintFollow()

local WATCH = {
    HttpGet = "GET", HttpGetAsync = "GET",
    HttpPost = "POST", HttpPostAsync = "POST",
    GetObjects = "OBJ",
}
local HookedSet = {}

local function wrapFor(target, fn)
    if iscclosure and not iscclosure(target) then return fn end
    return newcc(fn)
end

local function handleGameCall(method, invoke, ...)
    local kind = WATCH[method]
    local url = tostring((...))
    local source = "game:" .. method

    if isBlocked(url) then
        if State.enabled then finishRecord(newRecord(kind, source, url), { state = "blocked" }) end
        if kind == "OBJ" then return {} end
        return ""
    end
    if not State.enabled then return invoke(...) end

    local rec = newRecord(kind, source, url)
    if kind == "POST" then
        local data, ctype = select(2, ...)
        if data ~= nil then rec.sent = tostring(data) end
        rec.request = { Url = url, Data = data, ContentType = ctype }
    end

    local res = guarded(invoke, ...)
    if not res[1] then
        finishRecord(rec, { state = "error", err = tostring(res[2]) })
        error(res[2], 0)
    end

    local out = res[2]
    if kind == "OBJ" then
        local names = {}
        if type(out) == "table" then
            for i, o in ipairs(out) do
                names[i] = typeof(o) == "Instance" and (o.ClassName .. "  " .. o.Name) or tostring(o)
            end
        end
        finishRecord(rec, { state = "done", count = #names, copyText = table.concat(names, "\n") })
    else
        finishRecord(rec, { state = "done", body = out == nil and "" or tostring(out) })
    end
    task.defer(fireOnRequest, { Url = url, Method = method })
    return table.unpack(res, 2, res.n)
end

local function handleRequest(old, req)
    if State.unloaded or type(req) ~= "table" or busy[coroutine.running()] then
        return old(req)
    end

    local url = tostring(req.Url)
    local method = string.upper(tostring(req.Method or "GET"))
    local snapshot = deepCopy(req)

    if isBlocked(url) then
        if State.enabled then
            local r = newRecord(method, "request", url)
            r.request = snapshot
            finishRecord(r, { state = "blocked" })
        end
        return { Success = false, StatusCode = 403, StatusMessage = "Blocked by HttpSpy", Headers = {}, Body = "" }
    end

    local send = req
    local host = string.match(url, "^https?://([^/:]+)")
    if host and Proxies[host] then
        send = {}
        for k, v in pairs(req) do send[k] = v end
        local s, e = string.find(url, host, 1, true)
        send.Url = string.sub(url, 1, s - 1) .. Proxies[host] .. string.sub(url, e + 1)
    end

    local rec
    if State.enabled then
        rec = newRecord(method, "request", url)
        rec.request = snapshot
        if type(req.Body) == "string" and #req.Body > 0 then rec.sent = req.Body end
        task.defer(fireOnRequest, snapshot)
    end

    local res = guarded(old, send)
    if not res[1] then
        if rec then finishRecord(rec, { state = "error", err = tostring(res[2]) }) end
        error(res[2], 0)
    end

    local response = res[2]
    local hook = ResponseHooks[url]
    if hook then
        local ok, r = pcall(hook, response)
        if ok and r ~= nil then response = r end
    end

    if rec then
        local f = { state = "done" }
        if type(response) == "table" then
            f.statusCode = response.StatusCode
            f.statusMsg = response.StatusMessage
            f.body = response.Body == nil and "" or tostring(response.Body)
        else
            f.body = tostring(response)
        end
        finishRecord(rec, f)
    end
    return response
end

local installed = {}

if hookmetamethod or getrawmetatable then
    local oldNamecall
    local hookFn = newcc(function(self, ...)
        if not State.unloaded and rawequal(self, GAME) then
            local method = getnamecallmethod()
            if WATCH[method] and not busy[coroutine.running()] then
                return handleGameCall(method, function(...)
                    if setnamecallmethod then setnamecallmethod(method) end
                    return oldNamecall(self, ...)
                end, ...)
            end
        end
        return oldNamecall(self, ...)
    end)
    local ok = pcall(function()
        if hookmetamethod then
            oldNamecall = hookmetamethod(GAME, "__namecall", hookFn)
        else
            local mt = getrawmetatable(GAME)
            oldNamecall = mt.__namecall
            if setreadonly then setreadonly(mt, false) elseif make_writeable then make_writeable(mt) end
            mt.__namecall = hookFn
            if setreadonly then setreadonly(mt, true) end
        end
    end)
    installed[#installed + 1] = ok and "namecall ok" or "namecall failed"
end

if hookfunction then

    if Options.HookDirect then
        local n = 0
        for method in pairs(WATCH) do
            local ok, fn = pcall(function() return GAME[method] end)
            if ok and type(fn) == "function" and not HookedSet[fn] then
                HookedSet[fn] = true
                local old
                local hooked = pcall(function()
                    old = hookfunction(fn, wrapFor(fn, function(self, ...)
                        if State.unloaded or not rawequal(self, GAME) or busy[coroutine.running()] then
                            return old(self, ...)
                        end
                        return handleGameCall(method, function(...) return old(self, ...) end, ...)
                    end))
                end)
                if hooked then n += 1 end
            end
        end
        installed[#installed + 1] = "Calls: " .. n
    end

    local candidates = {
        type(syn) == "table" and syn.request or nil,
        type(http) == "table" and http.request or nil,
        http_request,
        request,
        type(fluxus) == "table" and fluxus.request or nil,
    }
    local n = 0
    for i = 1, 5 do
        local fn = candidates[i]
        if type(fn) == "function" and not HookedSet[fn] then
            HookedSet[fn] = true
            local old
            local hooked = pcall(function()
                old = hookfunction(fn, wrapFor(fn, function(req)
                    return handleRequest(old, req)
                end))
            end)
            if hooked then n += 1 end
        end
    end
    installed[#installed + 1] = "request: " .. n

    local wsCandidates = {
        { type(WebSocket) == "table" and WebSocket.connect or nil, "WebSocket.connect" },
        { type(syn) == "table" and type(syn.websocket) == "table" and syn.websocket.connect or nil, "syn.websocket" },
    }
    local w = 0
    for _, c in ipairs(wsCandidates) do
        local fn, label = c[1], c[2]
        if type(fn) == "function" and not HookedSet[fn] then
            HookedSet[fn] = true
            local old
            local hooked = pcall(function()
                old = hookfunction(fn, wrapFor(fn, function(...)
                    if State.unloaded or not State.enabled or busy[coroutine.running()] then
                        return old(...)
                    end
                    local url = tostring((...))
                    if isBlocked(url) then
                        finishRecord(newRecord("WS", label, url), { state = "blocked" })
                        error("HttpSpy: Blocked url", 0)
                    end
                    local rec = newRecord("WS", label, url)
                    local res = guarded(old, ...)
                    if not res[1] then
                        finishRecord(rec, { state = "error", err = tostring(res[2]) })
                        error(res[2], 0)
                    end
                    finishRecord(rec, { state = "done", note = "Connected" })
                    return table.unpack(res, 2, res.n)
                end))
            end)
            if hooked then w += 1 end
        end
    end
    installed[#installed + 1] = "websocket: " .. w
else
    installed[#installed + 1] = "Executor doesn't support hookfunction"
end

sysRecord("HttpSpy " .. VERSION .. " loaded  -  " .. table.concat(installed, "  |  ")
    .. (logName and ("\nSaving to: " .. logName) or ""))

local API = { Version = VERSION, OnRequest = OnRequest.Event }

local function Unload()
    if State.unloaded then return end

    State.unloaded = true
    for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
    pcall(function() Gui:Destroy() end)
    pcall(function() OnRequest:Destroy() end)
    if genv.HttpSpy == API then genv.HttpSpy = nil end
end
CloseBtn.MouseButton1Click:Connect(Unload)

function API.Unload() Unload() end
function API:SetEnabled(v) setEnabled(v) end
function API:IsEnabled() return State.enabled end
function API:Clear() clearLogs() end
function API:BlockUrl(url) Blocked[url] = true end
function API:UnblockUrl(url) Blocked[url] = nil end
function API:BlockPattern(text) BlockPatterns[#BlockPatterns + 1] = text end
function API:HookRequest(url, fn) ResponseHooks[url] = fn end
function API:UnhookRequest(url) ResponseHooks[url] = nil end
function API:ProxyHost(host, proxy) Proxies[host] = proxy end
function API:RemoveProxy(host) Proxies[host] = nil end
function API:ToggleGui(visible) Gui.Enabled = visible and true or false end
function API:SetGuiPosition(pos) Main.Position = pos end
function API:SetGuiSize(size) Main.Size = size end

API.HookSynRequest = API.HookRequest
API.UnHookSynRequest = API.UnhookRequest
API.WhitelistUrl = API.UnblockUrl

genv.HttpSpy = API
return API
