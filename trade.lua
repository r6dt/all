repeat task.wait() until game:IsLoaded()
-- Run on sender(s) AND receiver. Receiver automatically accepts incoming requests.
-- Use exact Roblox username and exact inventory item names.
-- ตามตัวรับตามขั้นต่ำ เทรดตามจำนวน และทำ EmptyAction หลังยืนยันสำเร็จ
local CONFIG = {
    -- ===============================================================================================================
    Receivers = {"zPr4m0t"}, -- ชื่อตัวรับ ใช้ไฟล์นี้และรายชื่อเดียวกันทั้งตัวส่ง/ตัวรับ ตามเซิฟผ่าน API
    HopWhenNotReadyWithReceiver = true, -- ตัวส่งยังไม่ครบเงื่อนไขตามตัวรับและอยู่ห้องตัวรับ ให้ย้ายออก
    ReceiverHopWhenStuck = true, -- ตัวรับย้ายเมื่อห้องเต็มและคนเดิมต่อเนื่อง 5 นาที
    -- ===============================================================================================================
    JoinConditions = {
        Mode = "any", -- any = ผ่านอย่างน้อยหนึ่งเงื่อนไข | all = ผ่านทุกเงื่อนไขที่เปิด
        Items = {
            ["Gems"] = 1000,
            ["Trait Reroll"] = 500,
            -- ["Lucky Spin"] = 5
        },
        Units = {
            Enabled = false,
            MinIncome = "1m",
            MaxIncome = 0,
            Count = 3
        },
    },
    -- ===============================================================================================================
    Trade = {
        KeepEquippedGear = false, -- ไม่เทรดเกียร์ที่กำลังสวมไว้ 1 ชิ้น ส่งส่วนที่เหลือได้ เช่น มี 10ชิ้น สวมอยู่ 1 ชิ้น จะเทรดได้ 9 ชิ้น
        Items = {
            ["Gems"] = "all",
            ["Trait Reroll"] = "all",
            ["Lucky Spin"] = "all",
            ["Jackpot Spin"] = "all",
            ["Angel's Halo"] = "all",
            ["Sakuna's Sash"] = "all",
            ["Enol's Drums"] = "all",
            ["Obita's Mask"] = "all",
            ["Mazun's Coat"] = "all"
        },
        Units = {
            Enabled = false,
            Names = {}, -- ว่าง = ทุกชื่อที่ผ่านรายได้
            MinIncome = "1m", -- รองรับตัวย่อของเกม; 0 = ไม่จำกัดเพดาน -- k, m, b, t, qd, qi, sx, sp, oc, no, dc, udc, ddc, tdc, qadc, qidc, sxdc, spdc, ocdc, nodc, vg, uvg, dvg, tvg, qavg, qivg, sxvg, spvg, ocvg
            MaxIncome = 0,
            Amount = "all", -- หรือจำนวนตัวที่ต้องการส่งให้ครบ
            SendOrder = "lowest", -- lowest = รายได้น้อยก่อน | highest = มากก่อน
            SkipLocked = true,
            SkipSlotted = true,
            KeepPerName = 1, -- เก็บรายได้สูงสุดของแต่ละชื่อไว้จำนวนนี้
        },
    },
    -- ===============================================================================================================
    EmptyAction = "hop", -- hop | autochange | none
    FarmSync = {
        FromFolderId = "",
        ToFolderId = "",
        WithoutReplacement = false 
    },
    -- ===============================================================================================================
}

-- ค่าภายในระบบ ไม่จำเป็นต้องปรับในการใช้งานทั่วไป
local INTERNAL = {
    LogMaxBytes = 262144, -- logหลักสูงสุดประมาณ256KB เก็บข้อความล่าสุดในไฟล์เดียว ไม่สร้างสำรอง
    DataLoadNoticeSeconds = 5, -- แสดงสถานะรอโหลดทุกกี่วินาที ไม่ตัดจบเมื่อเกิน60วินาที
    StateDirectory = "FlexibleTradeState", -- โฟลเดอร์สถานะใน workspace ของ executor
    AutochangeRetrySeconds = 30, -- ลองใหม่เฉพาะ FarmSync คืน false ชัดเจน
    AutochangeResponseTimeout = 60, -- เกินเวลานี้ถือว่าผลไม่แน่นอน ไม่ส่งซ้ำ
    ServerRateLimitWait = 60, -- เมื่อค้นหาเซิร์ฟโดน429 เริ่มพักกี่วินาที แล้วเพิ่มเวลาหากยังโดน
    PlaceId = 113290951185459,
    ServerRetrySeconds = 8, -- Retry receivers after unavailable/full servers
    HopRetrySeconds = 30,
    ReceiverStuckSeconds = 300,
    ReceiverHopRetrySeconds = 30,
    HopPoolSize = 15, -- สุ่มจากห้องที่คนน้อยที่สุดไม่เกินจำนวนนี้
    HopJitterMin = 2, -- หน่วงก่อน hop แบบสุ่ม หน่วยวินาที
    HopJitterMax = 12,
    RequestInterval = 8,
    TradeTimeout = 120,
    ConfirmRetryInterval = 1,
    AdvanceGap = 0.35,
    ObserveSeconds = 10,
}
local env = getgenv and getgenv() or _G
-- Compact on-screen status; log calls below are redirected to this panel.
local nativePrint, nativeWarn = print, warn
local logPath
local logBytes = 0
local lastLog
local logFailureShown = false
local function record(message)
    if message == lastLog then return end
    lastLog = message
    local ok, err = pcall(function()
        assert(type(INTERNAL.LogMaxBytes) == "number" and INTERNAL.LogMaxBytes >= 16384
            and INTERNAL.LogMaxBytes < math.huge, "Invalid LogMaxBytes")
        if not logPath then
            assert(type(writefile) == "function" and type(appendfile) == "function"
                and type(readfile) == "function" and type(isfile) == "function", "File logging unavailable")
            local player = game:GetService("Players").LocalPlayer
            if not isfolder("TradeLogs") then makefolder("TradeLogs") end
            local path = "TradeLogs/" .. tostring(player.UserId) .. ".log"
            if not isfile(path) then writefile(path, "Trade / Autochange log\n") end
            logBytes = #readfile(path)
            local header = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " SESSION START " .. player.Name .. "\n"
            appendfile(path, header)
            logBytes = logBytes + #header
            logPath = path
            nativePrint("[ItemTrade] Log:", logPath)
        end
        local line = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. game:GetService("Players").LocalPlayer.Name .. " " .. message .. "\n"
        if logBytes + #line > INTERNAL.LogMaxBytes then
            local previous = readfile(logPath)
            previous = previous:sub(-math.floor(INTERNAL.LogMaxBytes / 2))
            previous = previous:match("[^\n]*\n(.*)") or ""
            writefile(logPath, previous)
            assert(readfile(logPath) == previous, "Log rewrite verification failed")
            logBytes = #previous
        end
        appendfile(logPath, line)
        logBytes = logBytes + #line
    end)
    if not ok and not logFailureShown then
        logFailureShown = true
        nativeWarn("[ItemTrade] Log unavailable:", err)
    end
end
local statusLabel, detailLabel, balanceLabel, statusDot
local uiAlive = true
local latestStatus = "Starting..."
local latestError = false
local function showStatus(isError, ...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    local message = table.concat(parts, " "):gsub("%[ItemTrade%] ?", ""):gsub("%[Autochange%] ?", "")
    record(message)
    latestStatus, latestError = message, isError
    if statusLabel and uiAlive then
        statusLabel.Text = message
        statusLabel.TextColor3 = isError and Color3.fromRGB(255, 130, 130) or Color3.fromRGB(240, 245, 255)
        statusDot.BackgroundColor3 = isError and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(68, 224, 170)
    end
end
local function print(...) showStatus(false, ...) end
local function warn(...) showStatus(true, ...) end
if env.ItemTradeAutochangeUncertain then nativeWarn("Autochange outcome unknown; check FarmSync before running again") return end
if env.ItemTradeRunning then nativeWarn("[ItemTrade] Already running; stop the old script first") return end
env.ItemTradeRunning = true
env.ItemTradeStop = false
local connection, cancel, activePartner
local rosterConnections = {}
local manualHopRequested = false
local manualHopButton

local uiOK, uiError = pcall(function()
    local player = game:GetService("Players").LocalPlayer
    local isReceiver = false
    for _, name in ipairs(CONFIG.Receivers) do
        if name:lower() == player.Name:lower() then isReceiver = true break end
    end
    local playerGui = player:WaitForChild("PlayerGui", 15)
    assert(playerGui, "PlayerGui unavailable")
    -- ล้างเฉพาะ UI ของสคริปต์นี้จากการรันครั้งก่อน
    if typeof(env.FlexibleTradeStatusGui) == "Instance" then
        pcall(function() env.FlexibleTradeStatusGui:Destroy() end)
    end
    local old = playerGui:FindFirstChild("JackpotTradeStatus")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    local uiVisible = false
    gui.Enabled = uiVisible
    gui.Name = "JackpotTradeStatus"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 2147483647 -- ลำดับสูงสุดของ ScreenGui ให้แผงสถานะอยู่ด้านหน้า
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.IgnoreGuiInset = true -- วางแผงจากขอบหน้าจอโดยตรง
    -- เลือกชั้นของ executor ก่อน แล้ว fallback เมื่อไม่รองรับ/ไม่มีสิทธิ์
    local uiRoot
    local candidates = {}
    local hiddenUI = env.gethui or gethui
    if type(hiddenUI) == "function" then
        local ok, root = pcall(hiddenUI)
        if ok and typeof(root) == "Instance" then table.insert(candidates, root) end
    end
    table.insert(candidates, game:GetService("CoreGui"))
    table.insert(candidates, playerGui)
    for _, root in ipairs(candidates) do
        local ok = pcall(function() gui.Parent = root end)
        if ok and gui.Parent == root then uiRoot = root break end
    end
    assert(uiRoot, "Cannot attach trade UI")
    env.FlexibleTradeStatusGui = gui
    local frontBusy = false
    local function bringToFront()
        if not uiAlive or not uiVisible or frontBusy then return end
        frontBusy = true
        local ok, err = pcall(function()
            gui.Enabled = true
            gui.DisplayOrder = 2147483647
            -- แทรก UI ของเราใหม่เพื่ออยู่ท้ายลำดับเมื่อ ScreenGui อื่นมี DisplayOrder เท่ากัน
            gui.Parent = nil
            gui.Parent = uiRoot
        end)
        if not ok then
            pcall(function() gui.Parent = playerGui end)
            uiRoot = playerGui
            nativeWarn("[ItemTrade UI] Front refresh:", err)
        end
        frontBusy = false
    end
    local input = game:GetService("UserInputService")
    local hotkey = input.InputBegan:Connect(function(key)
    if (key.KeyCode == Enum.KeyCode.LeftAlt or key.KeyCode == Enum.KeyCode.RightAlt)
        and not input:GetFocusedTextBox() then

        uiVisible = not uiVisible
        gui.Enabled = uiVisible

        if uiVisible then 
            bringToFront() 
        end
    end
    end)
    local siblingAdded = uiRoot.ChildAdded:Connect(function(child)
        if child ~= gui and child:IsA("ScreenGui") then task.defer(bringToFront) end
    end)
    gui.Destroying:Connect(function()
        uiAlive = false
        hotkey:Disconnect()
        siblingAdded:Disconnect()
        if env.FlexibleTradeStatusGui == gui then env.FlexibleTradeStatusGui = nil end
    end)
    task.spawn(function()
        while uiAlive do
            task.wait(3)
            -- ไม่ย้าย parent ขณะกดปุ่มบน UI เพื่อไม่ขัดจังหวะ STOP/HOP
            if uiAlive and not input:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then bringToFront() end
        end
    end)
    local panel = Instance.new("Frame")
    panel.Position = UDim2.fromOffset(10, 10)
    panel.Size = UDim2.new(0, 320, 0, isReceiver and 205 or 165)
    panel.BackgroundColor3 = Color3.fromRGB(10, 15, 25)
    panel.BackgroundTransparency = 0.45
    panel.BorderSizePixel = 0
    panel.Parent = gui
    local limit = Instance.new("UISizeConstraint")
    limit.MaxSize = Vector2.new(460, isReceiver and 244 or 204)
    limit.Parent = panel
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 14)
    corner.Parent = panel
    local border = Instance.new("UIStroke")
    border.Color = Color3.fromRGB(80, 120, 160)
    border.Transparency = 0.4
    border.Parent = panel
    local function label(y, height, size, text)
    local item = Instance.new("TextLabel")
    item.BackgroundTransparency = 1
    item.Position = UDim2.fromOffset(14, y)
    item.Size = UDim2.new(1, -28, 0, height)
    item.Font = Enum.Font.GothamBold
    item.TextSize = math.clamp(size * 0.75, 9, 14)
    item.TextColor3 = Color3.fromRGB(240, 245, 255)
    item.TextXAlignment = Enum.TextXAlignment.Left
    item.TextYAlignment = Enum.TextYAlignment.Center
        item.TextWrapped = true
        item.Text = text
        item.Parent = panel
        return item
    end
    label(9, 26, 18, player.Name)
    detailLabel = label(37, 32, 12, "Receivers: " .. table.concat(CONFIG.Receivers, ", "))
    detailLabel.TextColor3 = Color3.fromRGB(158, 176, 203)
    balanceLabel = label(73, 30, 14, "Items: ...")
    balanceLabel.TextScaled = true
    balanceLabel.TextColor3 = Color3.fromRGB(255, 210, 99)
    statusLabel = label(108, 55, 13, latestStatus)
    statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.fromOffset(8, 8)
    statusDot.Position = UDim2.new(1, -20, 0, 20)
    statusDot.BackgroundColor3 = Color3.fromRGB(68, 224, 170)
    statusDot.BorderSizePixel = 0
    statusDot.Parent = panel
    local button = Instance.new("TextButton")
    button.Position = UDim2.fromOffset(14, 170)
    button.Size = UDim2.new(1, -28, 0, 24)
    button.BackgroundColor3 = Color3.fromRGB(160, 50, 65)
    button.BackgroundTransparency = 0.25
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.TextColor3 = Color3.new(1,1,1)
    button.Text = "STOP"
    button.Parent = panel
    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0,8)
    btnCorner.Parent = button
    button.Activated:Connect(function()
        env.ItemTradeStop = true
        button.Text = "STOP REQUESTED"
        showStatus(false, "Stopping; waiting for current operation...")
    end)
    if isReceiver then
        manualHopButton = Instance.new("TextButton")
        manualHopButton.Position = UDim2.fromOffset(14, 140)
        manualHopButton.Size = UDim2.new(1, -28, 0, 24)
        manualHopButton.BackgroundColor3 = Color3.fromRGB(45,120,190)
        manualHopButton.BackgroundTransparency = 0.25
        manualHopButton.TextColor3 = Color3.new(1, 1, 1)
        manualHopButton.Font = Enum.Font.GothamBold
        manualHopButton.TextSize = 12
        manualHopButton.Text = "HOP TO LOW POPULATION SERVER"
        manualHopButton.Parent = panel
        local hopCorner = Instance.new("UICorner")
        hopCorner.CornerRadius = UDim.new(0,8)
        hopCorner.Parent = manualHopButton
        manualHopButton.Activated:Connect(function()
            if env.ItemTradeStop or not env.ItemTradeRunning or manualHopRequested then return end
            manualHopRequested = true
            manualHopButton.Text = "HOP REQUESTED"
            showStatus(false, "Hop requested; waiting for current trade to finish")
        end)
    end
end)
if not uiOK then nativeWarn("Status UI failed:", uiError) end

local function main()
    assert(game.PlaceId == INTERNAL.PlaceId, "Run in the supported game (113290951185459)")
    assert(CONFIG.EmptyAction == "autochange" or CONFIG.EmptyAction == "hop" or CONFIG.EmptyAction == "none",
        "EmptyAction must be autochange, hop, or none")
    assert(#CONFIG.Receivers > 0, "Set at least one receiver username")
    local receiverNames = {}
    for _, name in ipairs(CONFIG.Receivers) do
        assert(type(name) == "string" and name ~= "", "Invalid receiver username")
        receiverNames[name:lower()] = true
    end
    local Players = game:GetService("Players")
    local RS = game:GetService("ReplicatedStorage")
    local player = Players.LocalPlayer
    local receiverMode = receiverNames[player.Name:lower()] == true
    print("[Autochange] Account:", player.Name, "Receiver mode:", receiverMode)
    if not receiverMode and CONFIG.EmptyAction == "autochange" and (CONFIG.FarmSync.FromFolderId == "" or CONFIG.FarmSync.ToFolderId == "") then
        warn("[Autochange] Folder IDs are empty. Fill FromFolderId and ToFolderId before autochange can run.")
    end
    local function module(path)
        print("[Autochange] Loading module:", path)
        local finished = false
        task.delay(20, function()
            if not finished then warn("[Autochange] Still waiting for module:", path) end
        end)
        local node = RS
        for name in path:gmatch("[^.]+") do
            node = node:WaitForChild(name, 20)
            assert(node, "Missing module: " .. path)
        end
        local result = require(node)
        finished = true
        return result
    end
    assert(type(INTERNAL.DataLoadNoticeSeconds) == "number" and INTERNAL.DataLoadNoticeSeconds >= 1
        and INTERNAL.DataLoadNoticeSeconds < math.huge, "Invalid DataLoadNoticeSeconds")
    local loadingStarted, nextLoadNotice = os.clock(), 0
    local function loadingNotice(stage)
        if os.clock() >= nextLoadNotice then
            print("[ItemTrade] Waiting for data:", stage, math.floor(os.clock() - loadingStarted), "seconds - STOP to cancel")
            nextLoadNotice = os.clock() + INTERNAL.DataLoadNoticeSeconds
        end
    end
    while not game:IsLoaded() or player:GetAttribute("__LOADED") ~= true do
        if env.ItemTradeStop then return end
        loadingNotice("__LOADED")
        task.wait(0.25)
    end
    if env.ItemTradeStop then return end
    local data = module("Framework.Features.Data.DataController")
    -- Loaded flag มาก่อนได้ รอ inventory snapshot ที่อ่านได้จริงด้วย
    while not env.ItemTradeStop do
        local ok, inventory = pcall(function() return data.Inventory() end)
        if player:GetAttribute("__LOADED") == true and ok and type(inventory) == "table" then break end
        loadingNotice("inventory snapshot")
        task.wait(0.25)
    end
    if env.ItemTradeStop then return end
    print("[ItemTrade] Player data ready:", player.Name)
    local rules = module("Framework.Features.Trading.TradeConfig")
    local Network = module("Packages.Network")
    local wanted = {}
    local registry = module("Framework.Features.Inventory.EntryRegistry")
    local function positive(n) return type(n) == "number" and n > 0 and n < math.huge and n % 1 == 0 end
    assert(CONFIG.JoinConditions.Mode == "all" or CONFIG.JoinConditions.Mode == "any", "Invalid ModeItemsForJoin")
    local tradeItems = {} -- รายการที่ใช้จริงหลังกรอง ไม่แก้ CONFIG ของผู้ใช้
    local skippedItems = {}
    for name, count in pairs(CONFIG.Trade.Items) do
        local reason
        if type(name) ~= "string" or name == "" then
            reason = "invalid item name"
        elseif count ~= "all" and not positive(count) then
            reason = "quantity must be a positive integer or all"
        else
            local entry = registry.getEntryConfig(name)
            if not entry then reason = "name not found in game item registry"
            elseif entry.kind == "Unit" then reason = "Unit belongs in Trade.Units"
            elseif table.find(rules.UNTRADEABLE_ENTRIES, name) then reason = "blocked by game trade rules"
            end
        end
        if reason then
            skippedItems[#skippedItems+1] = tostring(name)
            warn("[Config] Skipped:", tostring(name), "Reason:", reason)
        else
            tradeItems[name], wanted[name] = count, true
        end
    end
    local joinWanted = {}
    for name, count in pairs(CONFIG.JoinConditions.Items) do
        assert(type(name) == "string" and positive(count), "Invalid join config")
        joinWanted[name] = true
    end

    local function configuredItemAmount(selection)
        selection = selection or wanted
        assert(player:GetAttribute("__LOADED") == true, "Player data not ready")
        local inventory = data.Inventory()
        assert(type(inventory) == "table", "Inventory unavailable; not treating it as zero")
        local total, amounts = 0, {}
        for name in pairs(selection) do amounts[name] = 0 end
        for _, entry in pairs(inventory) do
            assert(type(entry) == "table", "Invalid inventory entry")
            if selection[entry.name] then
                assert(type(entry.amount) == "number" and entry.amount >= 0 and entry.amount < math.huge, "Invalid item amount: " .. entry.name)
                total = total + entry.amount
                amounts[entry.name] = amounts[entry.name] + entry.amount
            end
        end
        return total, amounts
    end
    local formatter = module("Packages.NumberFormatter")
    local function incomeLimit(value)
        local n = type(value) == "number" and value or formatter.ParseCompact(value)
        assert(type(n) == "number" and n >= 0 and n < math.huge, "Invalid income limit: " .. tostring(value))
        return n
    end
    local U, J = CONFIG.Trade.Units, CONFIG.JoinConditions.Units
    local tradeMin, tradeMax = incomeLimit(U.MinIncome), incomeLimit(U.MaxIncome)
    local joinMin, joinMax = incomeLimit(J.MinIncome), incomeLimit(J.MaxIncome)
    assert(tradeMax == 0 or tradeMax >= tradeMin, "Invalid trade income range")
    assert(joinMax == 0 or joinMax >= joinMin, "Invalid join income range")
    assert(positive(J.Count), "Invalid Unit Count")
    assert(U.Amount == "all" or positive(U.Amount), "Invalid Unit Amount")
    assert(type(U.KeepPerName) == "number" and U.KeepPerName >= 0 and U.KeepPerName % 1 == 0 and U.KeepPerName < math.huge, "Invalid KeepPerName")
    assert(U.SendOrder == "lowest" or U.SendOrder == "highest", "Invalid SendOrder")
    local names = {}
    for _, name in ipairs(U.Names) do assert(type(name) == "string", "Invalid unit name") names[name] = true end
    local function availableItems()
        local _, amounts = configuredItemAmount()
        if CONFIG.Trade.KeepEquippedGear then
            local equipped = data.EquippedGear()
            assert(type(equipped) == "table", "EquippedGear unavailable")
            local reserved = {}
            for _, name in pairs(equipped) do
                if type(name) == "string" and amounts[name] and not reserved[name] then
                    amounts[name] = math.max(0, amounts[name]-1)
                    reserved[name] = true
                end
            end
        end
        return amounts
    end
    local badIncome = {}
    local function eligibleUnits(minimum, maximum, useNames)
        if not U.Enabled then return {} end
        local bag, slots = data.Inventory(), data.Slots()
        assert(type(bag) == "table", "Inventory unavailable")
        if U.SkipSlotted then assert(type(slots) == "table", "Slots unavailable") end
        local placed, groups, result = {}, {}, {}
        if U.SkipSlotted then
            for _, slot in pairs(slots) do
                if type(slot) == "table" and slot.unitId then placed[slot.unitId] = true end
            end
        end
        for key, entry in pairs(bag) do
            local cfg = registry.getEntryConfig(entry.name)
            if cfg and cfg.kind == "Unit" then
                local ok, income = pcall(function() return cfg.income(entry.attributes) end)
                if ok and type(income) == "number" and income >= 0 and income < math.huge then
                    groups[entry.name] = groups[entry.name] or {}
                    table.insert(groups[entry.name], {key=key, name=entry.name, income=income,
                        protected=(U.SkipSlotted and placed[key]) or (U.SkipLocked and entry.attributes and entry.attributes.locked == true)})
                else
                    if not badIncome[key] then warn("Skipped Unit: unreadable income", entry.name, key) badIncome[key] = true end
                end
            end
        end
        for name, units in pairs(groups) do
            table.sort(units, function(a,b)
                if a.income == b.income then return tostring(a.key) < tostring(b.key) end
                return a.income > b.income
            end)
            for i, unit in ipairs(units) do
                if i > U.KeepPerName and not unit.protected and unit.income >= minimum
                    and (maximum == 0 or unit.income <= maximum)
                    and (not useNames or not next(names) or names[name]) then table.insert(result, unit) end
            end
        end
        table.sort(result, function(a,b)
            if a.income == b.income then return tostring(a.key) < tostring(b.key) end
            if U.SendOrder == "lowest" then return a.income < b.income end
            return a.income > b.income
        end)
        return result
    end
    local campaign -- แผนคงที่ข้ามหลายเทรด เก็บ key ของ Unit และยอด stack เดิม
    local function joinReady()
        if campaign and next(campaign.remaining) then return true end -- ส่งแผนเดิมให้ครบก่อน
        local _, amounts = configuredItemAmount(joinWanted)
        local any, all, count = false, true, 0
        for name, minimum in pairs(CONFIG.JoinConditions.Items) do
            local met = amounts[name] >= minimum
            any, all, count = any or met, all and met, count+1
        end
        if J.Enabled and U.Enabled then
            local met = #eligibleUnits(joinMin, joinMax, false) >= J.Count
            any, all, count = any or met, all and met, count+1
        end
        if count == 0 then return false end
        if CONFIG.JoinConditions.Mode == "any" then return any end
        return all
    end
    local function missingTradeItems()
        if campaign then return "" end
        local amounts = availableItems()
        local missing = {}
        for name, count in pairs(tradeItems) do
            if type(count) == "number" and amounts[name] < count then table.insert(missing, name .. " " .. amounts[name] .. "/" .. count) end
        end
        if U.Enabled and type(U.Amount) == "number" and #eligibleUnits(tradeMin, tradeMax, true) < U.Amount then
            table.insert(missing, "Units below required amount")
        end
        return table.concat(missing, ", ")
    end
    local function createCampaign()
        local bag, amounts = data.Inventory(), availableItems()
        local result = {remaining={}, labels={}, order={}}
        local remaining = {}
        for name, count in pairs(tradeItems) do remaining[name] = count == "all" and amounts[name] or count end
        local keys = {}
        for key in pairs(bag) do table.insert(keys,key) end
        table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)
        for _, key in ipairs(keys) do
            local entry = bag[key]
            if remaining[entry.name] then
                local n = math.min(entry.amount, remaining[entry.name])
                if n > 0 then
                    result.remaining[key],result.labels[key] = n,entry.name
                    table.insert(result.order,key)
                end
                remaining[entry.name] = remaining[entry.name]-n
            end
        end
        if U.Enabled then
            local units = eligibleUnits(tradeMin, tradeMax, true)
            for i=1,(U.Amount == "all" and #units or U.Amount) do
                local unit = assert(units[i], "Not enough Units")
                result.remaining[unit.key], result.labels[unit.key] = 1,unit.name
                table.insert(result.order,unit.key)
            end
        end
        return result
    end
    local function validateBatch(batch)
        local bag, amounts = data.Inventory(), availableItems()
        local units = {}
        for _, u in ipairs(eligibleUnits(tradeMin, tradeMax, true)) do units[u.key] = true end
        local totals = {}
        for key, amount in pairs(batch) do
            local entry = bag[key]
            assert(entry and entry.name == campaign.labels[key] and entry.amount >= amount, "Planned item missing/changed")
            local cfg = registry.getEntryConfig(entry.name)
            if cfg.kind == "Unit" then assert(units[key], "Planned Unit now protected or outside filters")
            else totals[entry.name] = (totals[entry.name] or 0)+amount end
        end
        for name, count in pairs(totals) do assert(amounts[name] >= count, "Gear reserve or inventory no longer sufficient") end
    end
    task.spawn(function()
        while env.ItemTradeRunning and uiAlive do
            local ok, amount, amounts = pcall(configuredItemAmount)
            if balanceLabel then
                local parts = {}
                if ok then
                    for name in pairs(tradeItems) do
                        table.insert(parts, name .. ": " .. tostring(amounts[name]))
                    end
                end
                if ok and U.Enabled then
                    local good, units = pcall(eligibleUnits, tradeMin, tradeMax, true)
                    table.insert(parts, good and ("Eligible Units: " .. #units) or "Units: unavailable")
                end
                if #skippedItems > 0 then table.insert(parts, "Skipped: " .. #skippedItems .. " (see log)") end
                balanceLabel.Text = ok and table.concat(parts, " | ") or "Items: waiting for data"
            end
            if detailLabel then
                detailLabel.Text = (receiverMode and "RECEIVER" or "SENDER / " .. CONFIG.EmptyAction) .. " → " .. table.concat(CONFIG.Receivers, ", ")
            end
            task.wait(0.5)
        end
    end)
    local function receiverHere()
        for _, candidate in ipairs(Players:GetPlayers()) do
            if receiverNames[candidate.Name:lower()] then return candidate end
        end
    end
    local hopAway
    local completedTrade = false
    local accountState, statePath
    local completionEvidence
    local HS = game:GetService("HttpService")
    local function saveAccountState(status)
        if receiverMode then return end
        accountState = {
            version = 2, action = CONFIG.EmptyAction, jobId = game.JobId, userId = player.UserId, username = player.Name,
            placeId = INTERNAL.PlaceId, status = status, updatedAt = os.time(),
            completionEvidence = completionEvidence, campaign = campaign,
        }
        local encoded = HS:JSONEncode(accountState)
        writefile(statePath, encoded)
        assert(readfile(statePath) == encoded, "State save verification failed; stopped")
        print("[ItemTrade] Saved account state:", status)
    end
    if not receiverMode then
        assert(type(isfile) == "function" and type(readfile) == "function"
            and type(writefile) == "function" and type(isfolder) == "function"
            and type(makefolder) == "function", "Executor file APIs required for account state")
        assert(type(INTERNAL.StateDirectory) == "string" and INTERNAL.StateDirectory:match("^[%w_-]+$"), "Invalid state directory")
        if not isfolder(INTERNAL.StateDirectory) then makefolder(INTERNAL.StateDirectory) end
        statePath = INTERNAL.StateDirectory .. "/" .. tostring(player.UserId) .. ".json"
        if isfile(statePath) then
            accountState = HS:JSONDecode(readfile(statePath))
            assert(type(accountState) == "table" and accountState.version == 2
                and accountState.userId == player.UserId and accountState.placeId == INTERNAL.PlaceId,
                "Invalid account state; inspect file, not treating as new account")
            campaign = accountState.campaign
            if campaign then
                assert(type(campaign.remaining) == "table" and type(campaign.labels) == "table" and type(campaign.order) == "table", "Invalid saved campaign")
                local seen = {}
                for _, key in ipairs(campaign.order) do
                    assert(type(key) == "string" and not seen[key], "Invalid campaign order")
                    seen[key] = true
                end
                for key, count in pairs(campaign.remaining) do
                    assert(seen[key] and positive(count) and type(campaign.labels[key]) == "string", "Invalid saved quantity")
                end
            end
            assert(accountState.status == "farming" or accountState.status == "awaiting_action"
                or accountState.status == "autochange_pending" or accountState.status == "done" or accountState.status == "hop_pending" or accountState.status == "trade_pending" or accountState.status == "batch_ready", "Unknown account state")
            assert(accountState.status ~= "autochange_pending",
                "Previous Autochange outcome unknown; inspect FarmSync and state file before retry")
            if accountState.status == "trade_pending" then
                local proof = accountState.completionEvidence
                local recovered
                if proof and type(proof.attemptId) == "string" and logPath and isfile(logPath) then
                    for line in readfile(logPath):gmatch("[^\n]+") do
                        local encoded = line:match("TRADE_RESULT (.+)$")
                        if encoded then
                            local ok, evidence = pcall(HS.JSONDecode, HS, encoded)
                            if ok and type(evidence) == "table" and evidence.attemptId == proof.attemptId
                                and evidence.userId == player.UserId and evidence.receiver == proof.receiver then
                                if evidence.result == "Completed" or evidence.result == "Cancelled" then recovered = evidence end
                            end
                        end
                    end
                end
                if recovered then
                    completionEvidence = proof
                    completionEvidence.completedAt = recovered.at
                    if recovered.result == "Completed" and campaign then
                        for key in pairs(proof.offer) do campaign.remaining[key] = nil end
                    end
                    saveAccountState(recovered.result == "Completed" and (campaign and next(campaign.remaining) and "batch_ready" or "awaiting_action") or (campaign and "batch_ready" or "farming"))
                    print("Recovered trade result from matching attempt:", recovered.result)
                else
                    error("Trade outcome unknown: no matching completion/cancellation evidence; no trade or action sent")
                end
            end
            assert(accountState.status == "farming" or accountState.action == CONFIG.EmptyAction, "Pending action differs from CONFIG; inspect state")
            if accountState.status == "done" then print("Action none already completed; stopped") return end
            if accountState.status == "hop_pending" and accountState.jobId ~= game.JobId then
                campaign = nil
                saveAccountState("farming")
            end
            completionEvidence = accountState.completionEvidence
            completedTrade = accountState.status == "awaiting_action" or accountState.status == "hop_pending"
            print("[ItemTrade] Restored account state:", accountState.status)
        else
            saveAccountState("farming")
        end
    end
    for _, value in ipairs({INTERNAL.AutochangeRetrySeconds, INTERNAL.AutochangeResponseTimeout}) do
        assert(type(value) == "number" and value >= 1 and value < math.huge, "Invalid Autochange timing")
    end
    local function autochangeAfterTrade()
        if receiverMode or activePartner or env.ItemTradeStop or not completedTrade then return false end
        local attempt = 0
        while not env.ItemTradeStop do
            assert(CONFIG.FarmSync.FromFolderId ~= "" and CONFIG.FarmSync.ToFolderId ~= "", "Set both FarmSync Folder IDs")
            while not (env.client and type(env.client.ChangeToFolder) == "function") do
                if env.ItemTradeStop or not completedTrade then return false end
                print("[Autochange] Waiting for FarmSync client")
                task.wait(1)
            end
            if env.ItemTradeStop or activePartner or not completedTrade then return false end
            attempt = attempt + 1
            saveAccountState("autochange_pending")
            env.ItemTradeAutochangeUncertain = true
            print("[Autochange] Sending request; attempt:", attempt)
            local finished, ok, result = false, false, nil
            task.spawn(function()
                ok, result = pcall(function()
                    return env.client:ChangeToFolder(CONFIG.FarmSync.FromFolderId, CONFIG.FarmSync.ToFolderId, CONFIG.FarmSync.WithoutReplacement, nil)
                end)
                record("FarmSync response: ok=" .. tostring(ok) .. " result=" .. tostring(result))
                finished = true
            end)
            local deadline = os.clock() + INTERNAL.AutochangeResponseTimeout
            while not finished and os.clock() < deadline do task.wait(0.25) end
            if not finished or not ok or result ~= false then
                local reason = not finished and "Request pending past timeout"
                    or not ok and "Request raised an error"
                    or result == true and "FarmSync returned true; awaiting account switch"
                    or "FarmSync outcome unknown"
                -- รวม true: ไม่มีหลักฐานว่าตัวใหม่เข้าแล้ว จึงไม่ยิงซ้ำหรือกลับเทรด
                warn("[Autochange]", reason, "No duplicate request; check FarmSync. Log:", logPath)
                while not env.ItemTradeStop do task.wait(1) end
                return true
            end
            saveAccountState("awaiting_action")
            env.ItemTradeAutochangeUncertain = false
            local retryAt = os.clock() + INTERNAL.AutochangeRetrySeconds
            while os.clock() < retryAt and not env.ItemTradeStop do
                print("[Autochange] Returned false; retry in", math.ceil(retryAt - os.clock()), "seconds")
                task.wait(1)
            end
        end
        return false
    end
    local function changeIfEmpty()
        if receiverMode or activePartner or env.ItemTradeStop or not completedTrade then return false end
        if CONFIG.EmptyAction == "autochange" then return autochangeAfterTrade() end
        if CONFIG.EmptyAction == "none" then
            saveAccountState("done")
            print("Trade completed; action none - stopped")
            return true
        end
        saveAccountState("hop_pending")
        hopAway(function() return completedTrade end)
        return true
    end
    local serverRetryAt = 0
    local serverBackoff = INTERNAL.ServerRateLimitWait
    assert(type(serverBackoff) == "number" and serverBackoff >= 10 and serverBackoff < math.huge,
        "ServerRateLimitWait must be at least 10 seconds")
    local function httpJSON(url, body)
        local http = env.request or env.http_request or request or http_request
        assert(type(http) == "function", "HTTP request unavailable")
        local HS = game:GetService("HttpService")
        local isServerList = not body and url:find("https://games.roblox.com/v1/games/", 1, true) == 1
            and url:find("/servers/Public", 1, true) ~= nil
        while true do
        if isServerList then
            local nextNotice = 0
            while not env.ItemTradeStop and os.clock() < serverRetryAt do
                if os.clock() >= nextNotice then
                    local remaining = math.ceil(serverRetryAt - os.clock())
                    print("[ItemTrade] HTTP 429: waiting", remaining, "seconds; will retry automatically")
                    if manualHopRequested and manualHopButton then manualHopButton.Text = "RETRY IN " .. remaining .. "s" end
                    nextNotice = os.clock() + 5
                end
                task.wait(0.25)
            end
            if env.ItemTradeStop then return {data = {}} end
        end
        local response = http({Url = url, Method = body and "POST" or "GET",
            Headers = {["Content-Type"] = "application/json"},
            Body = body and HS:JSONEncode(body) or nil})
        assert(type(response) == "table", "Invalid HTTP response")
        local status = tonumber(response.StatusCode or response.Status or response.status_code) or 0
        if status == 429 and isServerList then
            local retryAfter
            local headers = response.Headers or response.headers
            if type(headers) == "table" then
                for key, value in pairs(headers) do
                    if tostring(key):lower() == "retry-after" then retryAfter = tonumber(value) end
                end
            end
            if not retryAfter or retryAfter ~= retryAfter or retryAfter < 0 or retryAfter == math.huge then
                retryAfter = 0
            end
            serverRetryAt = os.clock() + math.max(serverBackoff, retryAfter) + math.random(3, 15)
            serverBackoff = math.min(serverBackoff * 2, math.max(300, INTERNAL.ServerRateLimitWait))
        else
        assert(status == 0 or (status >= 200 and status < 300), "HTTP " .. status)
        local result = response.Body or response.body
        if type(result) == "string" then result = HS:JSONDecode(result) end
        assert(type(result) == "table", "Invalid JSON response")
        if isServerList then serverBackoff = INTERNAL.ServerRateLimitWait end
        return result
        end
        end
    end
    local function pause(seconds)
        local untilTime = os.clock() + seconds
        while not env.ItemTradeStop and os.clock() < untilTime do task.wait(0.25) end
    end
    local function teleport(jobId, label)
        if env.ItemTradeStop then return end
        local TS = game:GetService("TeleportService")
        local failed = false
        local startedAt, phase = os.clock(), "requested"
        local phaseListener = player.OnTeleport:Connect(function(state)
            phase = tostring(state)
            print("Teleport phase:", phase, "target:", jobId)
        end)
        local listener = TS.TeleportInitFailed:Connect(function(p, result, message)
            if p == player then
                failed = true
                warn("[ItemTrade] Join failed:", label, result, message)
            end
        end)
        print("[ItemTrade] Joining:", label, "(autorun required after teleport)")
        local ok, err = pcall(function() TS:TeleportToPlaceInstance(INTERNAL.PlaceId, jobId, player) end)
        -- Keep only one teleport outstanding. Explicit failures allow the next receiver.
        local nextNotice = os.clock() + 30
        while ok and not failed and not env.ItemTradeStop do
            if os.clock() >= nextNotice then
                local elapsed = math.floor(os.clock() - startedAt)
                if elapsed >= 60 then
                    warn("Teleport outcome unknown; no duplicate request:", label, jobId, "phase:", phase, "elapsed:", elapsed)
                else
                    print("Teleport pending:", label, jobId, "phase:", phase, "elapsed:", elapsed)
                end
                nextNotice = os.clock() + 30
            end
            task.wait(0.25)
        end
        listener:Disconnect()
        phaseListener:Disconnect()
        if not ok then warn("[ItemTrade] Teleport failed:", err) end
    end
    local knownReceiverJobs = {}
    local userIds = {}
    local nextReceiver = 1
    local function routeToReceiver()
        if receiverHere() then return end
        for _ = 1, #CONFIG.Receivers do
            if env.ItemTradeStop or receiverHere() then return end
            if not joinReady() then
                print("[ItemTrade] Waiting for ItemsForJoin before following receiver")
                return
            end
            local name = CONFIG.Receivers[nextReceiver]
            nextReceiver = nextReceiver % #CONFIG.Receivers + 1
            local ok, presence = pcall(function()
                userIds[name] = userIds[name] or Players:GetUserIdFromNameAsync(name)
                local body = httpJSON("https://presence.roblox.com/v1/presence/users", {userIds = {userIds[name]}})
                return body.userPresences and body.userPresences[1]
            end)
            if ok and presence and presence.userPresenceType == 2
                and tonumber(presence.placeId) == INTERNAL.PlaceId
                and type(presence.gameId) == "string" and presence.gameId ~= ""
                and presence.gameId ~= game.JobId then
                knownReceiverJobs[presence.gameId] = true
                if joinReady() and not env.ItemTradeStop then teleport(presence.gameId, name) end
            else
                print("[ItemTrade] Receiver unavailable:", name, ok and "no joinable server returned" or presence)
            end
            pause(1)
        end
    end
    local rng = Random.new()
    assert(type(INTERNAL.HopPoolSize) == "number" and INTERNAL.HopPoolSize >= 1 and INTERNAL.HopPoolSize % 1 == 0, "Invalid HopPoolSize")
    assert(INTERNAL.HopJitterMin >= 0 and INTERNAL.HopJitterMax >= INTERNAL.HopJitterMin and INTERNAL.HopJitterMax < math.huge, "Invalid hop delay")
    hopAway = function(whileEligible)
        local function canHop()
            return not env.ItemTradeStop and not activePartner and (not whileEligible or whileEligible())
        end
        if receiverHere() then knownReceiverJobs[game.JobId] = true end
        local tried = {}
        while canHop() do
            local cursor, candidates = nil, {}
            for page = 1, 3 do
                local url = "https://games.roblox.com/v1/games/" .. INTERNAL.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true"
                if cursor then url = url .. "&cursor=" .. HS:UrlEncode(cursor) end
                local ok, body = pcall(httpJSON, url)
                if not ok then warn("Hop server search failed:", body) break end
                for _, server in ipairs(body.data or {}) do
                    if type(server.id) == "string" and server.id ~= game.JobId and not knownReceiverJobs[server.id]
                        and (not tried[server.id] or os.clock() - tried[server.id] > 120)
                        and tonumber(server.playing) and tonumber(server.maxPlayers)
                        and tonumber(server.playing) < tonumber(server.maxPlayers) then
                        table.insert(candidates, server)
                    end
                end
                cursor = body.nextPageCursor
                if #candidates >= INTERNAL.HopPoolSize or not cursor or cursor == "" then break end
            end
            table.sort(candidates, function(a,b) return tonumber(a.playing) < tonumber(b.playing) end)
            if #candidates > 0 then
                local target = candidates[rng:NextInteger(1, math.min(#candidates, INTERNAL.HopPoolSize))]
                local delay = rng:NextNumber(INTERNAL.HopJitterMin, INTERNAL.HopJitterMax)
                print("Random low-pop hop:", target.id, "players:", target.playing, "delay:", delay)
                pause(delay)
                if not canHop() then return end
                tried[target.id] = os.clock()
                teleport(target.id, "random low population")
            end
            if canHop() then pause(INTERNAL.HopRetrySeconds) end
        end
    end
    local function freeReceiverSlot()
        local function eligible()
            return CONFIG.HopWhenNotReadyWithReceiver and not receiverMode
                and not completedTrade and receiverHere() ~= nil
                and not joinReady()
        end
        if eligible() then
            print("[ItemTrade] No ItemsForJoin; leaving receiver server to free a slot")
            hopAway(eligible)
        end
    end
    if not receiverMode then
        while not next(tradeItems) and not U.Enabled and not campaign and not completedTrade and not env.ItemTradeStop do
            print("No valid trade items; waiting - no join/hop/autochange. Correct CONFIG and rerun.")
            pause(5)
        end
        if env.ItemTradeStop then return end
        local observeUntil = os.clock() + INTERNAL.ObserveSeconds
        repeat
            print("[ItemTrade] Observing inventory. Configured item total:", (configuredItemAmount()))
            task.wait(1)
            if env.ItemTradeStop then return end
        until os.clock() >= observeUntil
        if changeIfEmpty() then return end
        freeReceiverSlot()
        while not receiverHere() and not env.ItemTradeStop do
            if changeIfEmpty() then return end
            routeToReceiver()
            pause(INTERNAL.ServerRetrySeconds)
        end
        if env.ItemTradeStop then return end
    end
    local comm = Network.ClientComm.new(RS.Network, false, "TradeService")
    local tradingEnabled = comm:GetProperty("TradingEnabled")
    local propertyDeadline = os.clock() + 15
    while tradingEnabled:Get() == nil and os.clock() < propertyDeadline do task.wait(0.1) end
    print("[ItemTrade] TradingEnabled:", tradingEnabled:Get(), "AccountAge:", player.AccountAge,
        "Rolls:", data.Rolls(), "Receivers:", table.concat(CONFIG.Receivers, ", "))
    assert(tradingEnabled:Get() == true, "Trading unavailable or server property not loaded")
    assert(player.AccountAge >= rules.MIN_ACCOUNT_AGE, "Account too new to trade")
    assert(data.Rolls() >= rules.MIN_ROLLS, "Not enough rolls to unlock trading")
    -- ใช้ RemoteEvent โดยตรง ตาม Network.ClientRemoteSignal แบบไม่มี middleware
    local function loadTradeSignal(name)
        local started, nextNotice = os.clock(), 0
        print("Finding direct trade remote:", name)
        while not env.ItemTradeStop do
            local root = RS:FindFirstChild("Network")
            local service = root and root:FindFirstChild("TradeService")
            local folder = service and service:FindFirstChild("RE")
            local remote = folder and folder:FindFirstChild(name)
            if remote then
                assert(remote:IsA("RemoteEvent"), "Unexpected trade remote class: " .. name)
                print("Direct trade remote ready:", name)
                return {
                    Fire = function(_, ...) remote:FireServer(...) end,
                    Connect = function(_, callback) return remote.OnClientEvent:Connect(callback) end,
                }
            end
            local elapsed = os.clock() - started
            assert(elapsed < 20, "Missing Network.TradeService.RE." .. name .. "; no trade request sent")
            if elapsed >= nextNotice then
                print("Waiting for direct trade remote:", name, math.floor(elapsed), "seconds")
                nextNotice = elapsed + 5
            end
            task.wait(0.1)
        end
        error("Stopped while finding trade remote: " .. name)
    end
    local request = loadTradeSignal("RequestTrade")
    local respond = loadTradeSignal("RespondToRequest")
    local change = loadTradeSignal("ChangeOffer")
    local advance = loadTradeSignal("AdvanceTrade")
    cancel = loadTradeSignal("CancelTrade")
    local tradeEvent = loadTradeSignal("TradeEvent")
    local state, ended, fatal, plan, awaiting
    local rejectedTrade, nextCancelAt, rejectedAt
    local blockedSenders = {}
    local receiverMoving = false
    local lastAcceptedRequest = -math.huge
    local advances = {}
    local lastAdvanceAt = -math.huge
    local phaseChangedAt = 0
    local function stop(reason)
        if receiverMode then
            if not rejectedTrade then
                rejectedTrade, rejectedAt, nextCancelAt = reason, os.clock(), 0
                if activePartner then blockedSenders[activePartner.UserId] = os.clock() + 60 end
                warn("Rejecting this trade only:", reason)
            end
            return
        end
        fatal = reason
        if activePartner then cancel:Fire() end
    end
    local function onTradeEvent(event, payload)
        print("[ItemTrade] Event:", event, "Phase:", payload and payload.phase,
            "Reason:", payload and payload.reason)
        if event == "RequestReceived" and receiverMode then
            if env.ItemTradeStop or activePartner or rejectedTrade or fatal or receiverMoving or manualHopRequested then return end
            if not payload or typeof(payload.player) ~= "Instance"
                or not payload.player:IsA("Player") or payload.player == player then return end
            if type(payload.expiresAt) == "number"
                and payload.expiresAt <= workspace:GetServerTimeNow() then return end
            if (blockedSenders[payload.player.UserId] or 0) > os.clock() then
                respond:Fire(false)
                return
            end
            print("[ItemTrade] Accepting incoming request from:", payload.player.Name)
            lastAcceptedRequest = os.clock()
            respond:Fire(true)
        elseif event == "Started" then
            activePartner = payload.partner
            state, ended, advances = nil, nil, {}
            lastAdvanceAt, phaseChangedAt = -math.huge, os.clock()
            if not receiverMode and activePartner ~= awaiting then
                stop("Unexpected trade partner")
            end
        elseif event == "Updated" and activePartner then
            if payload.partner ~= activePartner then stop("Partner changed") return end
            if not state or payload.phase ~= state.phase then
                phaseChangedAt = os.clock()
            end
            -- A confirmed Ready that is reset by an offer change may be sent again.
            if state and state.ownReady and not payload.ownReady and payload.phase == "Offer" then
                advances.Offer = nil
                advances.Confirm = nil
            end
            state = payload
            print("[ItemTrade] Server state: ready=", payload.ownReady,
                "accepted=", payload.ownAccepted, "partnerReady=", payload.otherReady)
        elseif event == "Ended" and activePartner then
            ended = payload.reason
            if not receiverMode and ended == "Completed" and activePartner == awaiting and not fatal and plan then
                local saved, saveError = pcall(function()
                    assert(state and state.ownOffer, "Missing final offer evidence")
                    for key, amount in pairs(plan) do assert(state.ownOffer[key] == amount, "Final offer does not match plan") end
                    for key in pairs(state.ownOffer) do assert(plan[key], "Unexpected final item") end
                    assert(next(state.otherOffer) == nil, "Unexpected receiver offer")
                    completionEvidence = {attemptId = completionEvidence.attemptId, receiver = activePartner.Name, completedAt = os.time(), offer = plan}
                    record("TRADE_RESULT " .. HS:JSONEncode({attemptId = completionEvidence.attemptId,
                        userId = player.UserId, receiver = activePartner.Name, result = "Completed", at = os.time()}))
                    for key in pairs(plan) do campaign.remaining[key] = nil end
                    saveAccountState(next(campaign.remaining) and "batch_ready" or "awaiting_action")
                end)
                if saved then completedTrade = not next(campaign.remaining)
                else fatal = "Completed trade but state save failed: " .. tostring(saveError) end
            end
            if not receiverMode and ended == "Cancelled" then
                local saved, problem = pcall(function()
                    if completionEvidence and completionEvidence.attemptId then
                        record("TRADE_RESULT " .. HS:JSONEncode({attemptId = completionEvidence.attemptId,
                            userId = player.UserId, receiver = activePartner.Name, result = "Cancelled", at = os.time()}))
                    end
                    saveAccountState(campaign and "batch_ready" or "farming")
                end)
                if not saved then fatal = tostring(problem) end
            end
            if not receiverMode and ended ~= "Completed" and ended ~= "Cancelled" then
                fatal = "Trade ended with unverified outcome: " .. tostring(ended) .. "; pending state retained"
            end
            activePartner, state = nil, nil
            rejectedTrade, rejectedAt, nextCancelAt = nil, nil, nil
        end
    end
    print("Binding direct TradeEvent listener")
    local listenerDone, listenerAbandoned, listenerError = false, false, nil
    local listenerStarted = os.clock()
    task.spawn(function()
        local ok, result = pcall(function()
            return tradeEvent:Connect(function(...)
                if not listenerAbandoned then onTradeEvent(...) end
            end)
        end)
        if ok then
            if listenerAbandoned then result:Disconnect() else connection = result end
        else listenerError = result end
        listenerDone = true
    end)
    local nextListenerNotice = 5
    while not listenerDone do
        local elapsed = os.clock() - listenerStarted
        if env.ItemTradeStop or elapsed >= 20 then
            listenerAbandoned = true
            error("TradeEvent listener not connected; no trade request sent. Stop=" .. tostring(env.ItemTradeStop))
        end
        if elapsed >= nextListenerNotice then
            print("Binding TradeEvent listener:", math.floor(elapsed), "seconds")
            nextListenerNotice = elapsed + 5
        end
        task.wait(0.1)
    end
    assert(connection, "TradeEvent listener failed: " .. tostring(listenerError))
    print("TradeEvent listener ready")
    local function waitFor(predicate, seconds)
        local limit = os.clock() + seconds
        repeat
            if fatal then error(fatal) end
            if env.ItemTradeStop then return false end
            if predicate() then return true end
            task.wait(0.1)
        until os.clock() >= limit
        return false
    end
    local function exactOffer(offer)
        for key, amount in pairs(plan) do if offer[key] ~= amount then return false end end
        for key, amount in pairs(offer) do if plan[key] ~= amount then return false end end
        return true
    end
    local function advanceOnce()
        if not state or not activePartner or env.ItemTradeStop then return end
        local now = os.clock()
        if now - lastAdvanceAt < INTERNAL.AdvanceGap
            or now - phaseChangedAt < INTERNAL.AdvanceGap then return end
        local key
        if state.phase == "Offer" and not state.ownReady then key = "Offer"
        elseif state.phase == "Confirm" and not state.ownAccepted then key = "Confirm" end
        -- Ready toggles on the server: never resend it blindly.
        -- Accept is idempotent during Confirm, so retry until acknowledged.
        local retryAccept = key == "Confirm" and advances.Confirm
            and now - advances.Confirm >= INTERNAL.ConfirmRetryInterval
        if key and (not advances[key] or retryAccept) then
            print("[ItemTrade] Sending confirmation:", key)
            advances[key] = now
            lastAdvanceAt = now
            advance:Fire()
        end
    end
    print("[ItemTrade] Mode:", receiverMode and "RECEIVER (automatic acceptance)" or "SENDER")
    if receiverMode then
        if data.TradeRequestsEnabled() ~= true then
            loadTradeSignal("SetTradeRequestsEnabled"):Fire(true)
            assert(waitFor(function() return data.TradeRequestsEnabled() == true end, 10),
                "Could not enable incoming trade requests")
        end
        local tradeStarted
        local fullSince, fullRoster
        local nextHopAttempt, nextRosterNotice = 0, 0
        local function resetRosterTimer()
            fullSince, fullRoster = nil, nil
        end
        -- Events also catch someone leaving and rejoining between polling ticks.
        table.insert(rosterConnections, Players.PlayerAdded:Connect(resetRosterTimer))
        table.insert(rosterConnections, Players.PlayerRemoving:Connect(resetRosterTimer))
        local function checkStuckServer()
            if not CONFIG.ReceiverHopWhenStuck then return end
            local members = Players:GetPlayers()
            if Players.MaxPlayers <= 0 or #members < Players.MaxPlayers then
                resetRosterTimer()
                return
            end
            local ids = {}
            for _, member in ipairs(members) do table.insert(ids, tostring(member.UserId)) end
            table.sort(ids)
            local signature = table.concat(ids, ",")
            local now = os.clock()
            if fullRoster ~= signature then
                fullRoster, fullSince = signature, now
            end
            local elapsed = now - fullSince
            if now >= nextRosterNotice then
                print("[ItemTrade] Full server / same players:", math.floor(elapsed), "/", INTERNAL.ReceiverStuckSeconds, "seconds")
                nextRosterNotice = now + 15
            end
            if elapsed < INTERNAL.ReceiverStuckSeconds or now < nextHopAttempt
                or activePartner or now - lastAcceptedRequest < rules.REQUEST_DURATION + 2 then return end
            nextHopAttempt = now + INTERNAL.ReceiverHopRetrySeconds
            receiverMoving = true
            local observedSince = fullSince
            local ok, result = pcall(function()
                local body = httpJSON("https://games.roblox.com/v1/games/" .. INTERNAL.PlaceId
                    .. "/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true")
                local candidates = {}
                for _, server in ipairs(body.data or {}) do
                    local count, capacity = tonumber(server.playing), tonumber(server.maxPlayers)
                    if type(server.id) == "string" and server.id ~= game.JobId
                        and count and capacity and count < capacity and count < #members then
                        table.insert(candidates, server)
                    end
                end
                table.sort(candidates, function(a, b) return tonumber(a.playing) < tonumber(b.playing) end)
                for _, server in ipairs(candidates) do
                    -- Recheck after HTTP / failed teleport: any roster change cancels this attempt.
                    if env.ItemTradeStop or activePartner or fullSince ~= observedSince then return end
                    print("[ItemTrade] Receiver moving to low population server:", server.playing)
                    teleport(server.id, "receiver low population / " .. tostring(server.playing) .. " players")
                    if env.ItemTradeStop then return end
                    pause(1)
                end
                print("[ItemTrade] No successful receiver hop; will retry")
            end)
            receiverMoving = false
            if not ok then warn("[ItemTrade] Receiver server search failed; will retry:", result) end
        end
        while not env.ItemTradeStop do
            if fatal then error(fatal) end
            if activePartner then
                tradeStarted = tradeStarted or os.clock()
                if os.clock() - tradeStarted > INTERNAL.TradeTimeout then stop("Receiver trade timeout") end
                if state and not rejectedTrade then
                    local valid, problem = pcall(function()
                        assert(type(state.ownOffer) == "table" and next(state.ownOffer) == nil, "Receiver offered items")
                        assert(type(state.otherOffer) == "table", "Invalid incoming offer")
                        local count = 0
                        for _, entry in pairs(state.otherOffer) do
                            assert(type(entry) == "table" and (wanted[entry.name] or (U.Enabled and registry.getEntryConfig(entry.name) and registry.getEntryConfig(entry.name).kind == "Unit"))
                                and type(entry.amount) == "number" and entry.amount > 0 and entry.amount < math.huge,
                                "Incoming offer contains an invalid/unlisted item")
                            count = count + 1
                        end
                        if count > 0 and state.otherReady then advanceOnce() end
                    end)
                    if not valid then stop(tostring(problem)) end
                end
                if rejectedTrade and os.clock() >= nextCancelAt then
                    nextCancelAt = os.clock() + 3
                    local ok, problem = pcall(function() cancel:Fire() end)
                    warn("Waiting for cancellation confirmation:", rejectedTrade,
                        "elapsed:", math.floor(os.clock()-rejectedAt), ok and "cancel sent" or tostring(problem))
                end
            else
                tradeStarted = nil
                if ended then print("[ItemTrade] Trade ended:", ended) ended = nil end
            end
            if manualHopRequested then
                if not activePartner and os.clock() - lastAcceptedRequest >= rules.REQUEST_DURATION + 2 then
                    receiverMoving = true
                    local ok, problem = pcall(function()
                        print("[ItemTrade] Searching low population servers")
                        local body = httpJSON("https://games.roblox.com/v1/games/" .. INTERNAL.PlaceId
                            .. "/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true")
                        local candidates = {}
                        for _, server in ipairs(body.data or {}) do
                            local count, capacity = tonumber(server.playing), tonumber(server.maxPlayers)
                            if type(server.id) == "string" and server.id ~= "" and server.id ~= game.JobId
                                and count and capacity and count >= 0 and count < capacity then
                                table.insert(candidates, server)
                            end
                        end
                        table.sort(candidates, function(a, b) return tonumber(a.playing) < tonumber(b.playing) end)
                        for _, server in ipairs(candidates) do
                            if env.ItemTradeStop or activePartner then return end
                            teleport(server.id, "manual hop / " .. tostring(server.playing) .. " players")
                            if env.ItemTradeStop then return end
                            pause(1)
                        end
                        print("[ItemTrade] No server joined; press HOP to try again")
                    end)
                    receiverMoving = false
                    manualHopRequested = false
                    if manualHopButton then manualHopButton.Text = "HOP TO LOW POPULATION SERVER" end
                    if not ok then warn("[ItemTrade] Manual hop failed:", problem) end
                end
            else
                checkStuckServer()
            end
            task.wait(0.1)
        end
        return
    end

    while not env.ItemTradeStop do
        if changeIfEmpty() then return end
        if not completedTrade and not joinReady() then
            freeReceiverSlot()
            print("[ItemTrade] Waiting for ItemsForJoin; no completed trade recorded")
            pause(1)
            continue
        end
        local missing = missingTradeItems()
        if missing ~= "" then print("Waiting for trade quantities:", missing) pause(1) continue end
        if not campaign then
            campaign = createCampaign()
            if not next(campaign.remaining) then campaign = nil print("No eligible items/Units to trade") pause(1) continue end
            saveAccountState("batch_ready")
        end
        local keys = {}
        for _, key in ipairs(campaign.order) do
            if campaign.remaining[key] then table.insert(keys,key) end
        end
        plan = {}
        for i=1,math.min(#keys, rules.MAX_UNIQUE_ENTRIES) do
            local key = keys[i]
            plan[key] = campaign.remaining[key]
            print("Planned:", campaign.labels[key], key, plan[key])
        end
        validateBatch(plan)
        awaiting = nil
        for _, candidate in ipairs(Players:GetPlayers()) do
            if receiverNames[candidate.Name:lower()] then awaiting = candidate break end
        end
        if not awaiting then
            print("[ItemTrade] Waiting for receivers:", table.concat(CONFIG.Receivers, ", "))
            routeToReceiver()
            pause(INTERNAL.ServerRetrySeconds)
        else
            ended = nil
            local missingNow = missingTradeItems()
            if missingNow ~= "" or not joinReady() then
                print("[ItemTrade] Trade request blocked; missing:", missingNow)
                pause(1)
                continue
            end
            print("[ItemTrade] Requesting trade with:", awaiting.Name)
            completionEvidence = {attemptId = HS:GenerateGUID(false), receiver = awaiting.Name, offer = plan, plannedAt = os.time()}
            saveAccountState("trade_pending")
            request:Fire(awaiting)
            if waitFor(function() return activePartner ~= nil end, rules.REQUEST_DURATION + 2) then
                assert(waitFor(function() return state ~= nil or ended ~= nil end, 10) and state, "No initial trade state")
                assert(next(state.ownOffer) == nil, "Initial offer not empty")
                validateBatch(plan)
                for _, key in ipairs(keys) do
                    if plan[key] then
                        assert(activePartner == awaiting and state.phase == "Offer", "Trade changed while adding items")
                        change:Fire(key, plan[key])
                        print("[ItemTrade] Offer sent:", key, plan[key])
                        assert(waitFor(function()
                            return state and state.ownOffer[key] == plan[key]
                        end, 10), "Item offer not confirmed; stopped")
                        task.wait(0.15)
                    end
                end
                local finishBy = os.clock() + INTERNAL.TradeTimeout
                while activePartner and not env.ItemTradeStop do
                    if fatal then error(fatal) end
                    assert(os.clock() < finishBy, "Trade confirmation timeout")
                    if state then
                        assert(exactOffer(state.ownOffer), "Offer changed; cancelling")
                        assert(next(state.otherOffer) == nil, "Receiver offered items; cancelling")
                        if state.phase == "Offer" or state.phase == "Confirm" then validateBatch(plan) end
                        advanceOnce()
                    end
                    task.wait(0.1)
                end
                if env.ItemTradeStop then return end
                assert(not fatal, fatal)
                if ended ~= "Completed" then
                    warn("Trade cancelled; retry later:", ended)
                    pause(INTERNAL.RequestInterval)
                    continue
                end
                assert(not fatal, fatal)
                assert(accountState.status == "batch_ready" or accountState.status == "awaiting_action", "Completed batch evidence not saved")
                -- ไม่ใช้ยอด Gems/Trait ที่อาจได้เพิ่มมาขัดขวางการบันทึก Completed
                -- ยึด Completed และแผน ไม่ยึดของที่ได้เพิ่มหลังเทรด
                pause(1)
                print("[ItemTrade] Batch completed")
                if changeIfEmpty() then return end
            else
                saveAccountState("batch_ready")
                warn("[ItemTrade] No trade started: request may be declined, expired, or rejected by the server")
            end
            task.wait(math.max(INTERNAL.RequestInterval, rules.REQUEST_COOLDOWN + 0.5))
        end
    end
end

local ok, err = pcall(main)
if activePartner and cancel then pcall(function() cancel:Fire() end) end
if connection then connection:Disconnect() end
for _, listener in ipairs(rosterConnections) do listener:Disconnect() end
env.ItemTradeRunning = false
if not ok then
    warn("[ItemTrade]", err)
else
    print("[ItemTrade] Stopped / operation finished")
end
