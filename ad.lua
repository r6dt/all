repeat task.wait() until game:IsLoaded()

-- Anime Dice: trade configured items to Receiver, then FarmSync Autochange only when Jackpot Spin is zero after it was seen and saved.
-- Run the same script on sender(s) and receiver. Autorun is required after teleport.
local CONFIG = {
    AutoRejoinEnabled = true, -- ตรวจ Disconnect แล้วลองเข้าเกมเดิมใหม่
    RejoinDelaySeconds = 5, -- รอหลังตรวจพบว่าหลุดก่อนเข้าใหม่
    RejoinRetrySeconds = 30, -- พักก่อนลองใหม่ เมื่อ Roblox แจ้งวาร์ปล้มเหลว
    Receiver = "zPr4m0t",
    Items = {"Jackpot Spin", "Gems", "Trait Reroll"},
    AutochangeEnabled = true, -- true = Autochange when Jackpot Spin is zero after first Jackpot was saved; other Items do not block it
    PlaceId = 113290951185459,
    ObserveSeconds = 10,
    ReceiverRetrySeconds = 8,
    RequestInterval = 8,
    TradeTimeout = 120,
    ConfirmRetrySeconds = 1,
    FromFolderId = "9e4b577700b769f1279f64ede403b020383128a744cce7cbd2e1ccfbaead317a",
    ToFolderId = "afbf6dd712c435e44981a0959a093fb30b3aa391eeb803647804d6e95dfc167f",
    WithoutReplacement = false,
    JackpotStateFolder = "JackpotTradeState", -- executor workspace folder สำหรับจำว่าไอดีนี้เคยมี Jackpot Spin แล้ว
    MinJackpotToHop = 1, -- Hop ไปหา Receiver เฉพาะเมื่อ Jackpot Spin >= 2 (Items อื่นไม่ทำให้ Hop)
    OnePlayerHopEnabled = true, -- true = หาเซิร์ฟเวอร์ที่มีผู้เล่นอยู่ 1 คนก่อนเราเข้า; false = ปิด
    OnePlayerHopIntervalSeconds = 15 * 60, -- 15 นาทีต่อการ Hop สำเร็จ/ที่เริ่มส่งคำขอ
    OnePlayerHopRetrySeconds = 30, -- พักก่อนลองใหม่เมื่อหาเซิร์ฟเวอร์ไม่ได้หรือ Teleport ล้มเหลว
    OnePlayerHopTargetPlayers = 1, -- จำนวนคนในเซิร์ฟเวอร์ก่อนเราเข้า (เข้าแล้วโดยทั่วไปเป็น 2 คน)
    OnePlayerHopMaxPages = 5, -- จำกัดจำนวนหน้าที่ค้นหาใน API ต่อหนึ่งรอบ
}

local env = getgenv and getgenv() or _G
if env.JackpotTradeOnlyRunning then
    warn("[JackpotTrade] Already running")
    return
end
env.JackpotTradeOnlyRunning = true
env.JackpotTradeOnlyStop = false

local tradeConnection, teleportConnection, cancelSignal, activePartner
local hopThreadAlive = true
local function log(...) print("[JackpotTrade]", ...) end
-- ปรับสวิตช์ระหว่างรันได้ด้วย getgenv().SetJackpotOnePlayerHop(false/true)
env.JackpotOnePlayerHopEnabled = CONFIG.OnePlayerHopEnabled
env.SetJackpotOnePlayerHop = function(enabled)
    assert(type(enabled) == "boolean", "SetJackpotOnePlayerHop requires true or false")
    env.JackpotOnePlayerHopEnabled = enabled
    log("15-minute one-player server hop:", enabled and "ON" or "OFF")
end
local function pause(seconds)
    local deadline = os.clock() + seconds
    while not env.JackpotTradeOnlyStop and os.clock() < deadline do task.wait(0.1) end
end

-- ตรวจเฉพาะหน้าต่าง ErrorPrompt ของ Roblox ไม่ใช้ error จากการเทรดเป็นตัวกระตุ้น
-- CoreGui เป็นโครงสร้างภายใน อาจเปลี่ยนตาม Roblox/executor
local rejoinToken = {}
env.JackpotDisconnectMonitor = rejoinToken
env.JackpotAutoRejoinStop = false
local intentionalExit = false
local rejoining = false
local function startDisconnectMonitor()
    if not CONFIG.AutoRejoinEnabled then return end
    assert(type(CONFIG.RejoinDelaySeconds) == "number" and CONFIG.RejoinDelaySeconds >= 0
        and CONFIG.RejoinDelaySeconds < math.huge, "Invalid RejoinDelaySeconds")
    assert(type(CONFIG.RejoinRetrySeconds) == "number" and CONFIG.RejoinRetrySeconds >= 5
        and CONFIG.RejoinRetrySeconds < math.huge, "Invalid RejoinRetrySeconds")
    local Players = game:GetService("Players")
    local TS = game:GetService("TeleportService")
    local function alive()
        return env.JackpotDisconnectMonitor == rejoinToken and not env.JackpotAutoRejoinStop
            and not intentionalExit and (rejoining or not env.JackpotTradeOnlyStop)
    end
    local function waitActive(seconds)
        local untilTime = os.clock() + seconds
        while alive() and os.clock() < untilTime do task.wait(0.25) end
        return alive()
    end
    task.spawn(function()
        local warned = false
        while alive() do
            local ok, disconnected = pcall(function()
                local gui = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
                local overlay = gui and gui:FindFirstChild("promptOverlay")
                if not overlay then return false end
                for _, prompt in ipairs(overlay:GetDescendants()) do
                    if prompt.Name == "ErrorPrompt" and prompt:IsA("GuiObject") then
                        local visible, parent = true, prompt
                        while parent and parent ~= gui do
                            if parent:IsA("GuiObject") and not parent.Visible then visible = false break end
                            parent = parent.Parent
                        end
                        if gui:IsA("ScreenGui") and not gui.Enabled then visible = false end
                        if visible then
                            local texts = {}
                            for _, child in ipairs(prompt:GetDescendants()) do
                                if child:IsA("TextLabel") then table.insert(texts, child.Text) end
                            end
                            local message = table.concat(texts, " "):lower()
                            if message:find("disconnected", 1, true) or message:find("kicked", 1, true)
                                or message:find("lost connection", 1, true)
                                or message:find("ถูกตัดการเชื่อมต่อ", 1, true)
                                or message:find("ขาดการเชื่อมต่อ", 1, true)
                                or message:find("ถูกเตะ", 1, true) then return true end
                        end
                    end
                end
                return false
            end)
            if not ok and not warned then
                warned = true
                warn("[AutoRejoin] Cannot inspect Roblox disconnect prompt:", disconnected)
            end
            if ok and disconnected then break end
            if not waitActive(1) then return end
        end
        if not alive() then return end
        rejoining = true
        env.JackpotTradeOnlyStop = true -- หยุดระบบเทรด/ตามตัวรับเดิมก่อนใช้รีจอย
        if teleportConnection then teleportConnection:Disconnect(); teleportConnection = nil end
        log("Disconnect detected; rejoining in", CONFIG.RejoinDelaySeconds, "seconds")
        if not waitActive(CONFIG.RejoinDelaySeconds) then return end
        while alive() do
            local player = Players.LocalPlayer
            if not player then warn("[AutoRejoin] LocalPlayer unavailable") return end
            local failed, failure = false, ""
            local connection = TS.TeleportInitFailed:Connect(function(target, result, message)
                if target == player then failed, failure = true, tostring(result) .. ": " .. tostring(message) end
            end)
            log("AutoRejoin: joining Place ID", CONFIG.PlaceId)
            local sent, problem = pcall(function() TS:Teleport(CONFIG.PlaceId, player) end)
            if not sent then failed, failure = true, tostring(problem) end
            -- รอผล ห้ามยิงซ้ำเพราะครบเวลาอย่างเดียว (คำขอเดิมอาจยังทำงานอยู่)
            local nextNotice = os.clock() + 30
            while alive() and not failed do
                if os.clock() >= nextNotice then
                    log("AutoRejoin pending; waiting for teleport result")
                    nextNotice = os.clock() + 30
                end
                task.wait(0.25)
            end
            connection:Disconnect()
            if not alive() then return end
            warn("[AutoRejoin] Failed:", failure)
            if not waitActive(CONFIG.RejoinRetrySeconds) then return end
        end
    end)
end

local function main()
    assert(game.PlaceId == CONFIG.PlaceId, "Wrong game/place")
    startDisconnectMonitor()
    assert(type(CONFIG.Receiver) == "string" and CONFIG.Receiver ~= "", "Set Receiver")
    assert(CONFIG.FromFolderId ~= "" and CONFIG.ToFolderId ~= "", "Set both FarmSync Folder IDs")

    local Players = game:GetService("Players")
    local RS = game:GetService("ReplicatedStorage")
    local TS = game:GetService("TeleportService")
    local HS = game:GetService("HttpService")
    local player = Players.LocalPlayer
    local receiverMode = player.Name:lower() == CONFIG.Receiver:lower()
    local teleportInProgress = false -- กันการวาร์ปหา Receiver ชนกับ Hop รอบ 15 นาที
    local tradeBusy = false -- รวมช่วงส่งคำขอ/จัด offer ก่อน activePartner จะเริ่ม
    assert(type(CONFIG.OnePlayerHopIntervalSeconds) == "number" and CONFIG.OnePlayerHopIntervalSeconds >= 60,
        "OnePlayerHopIntervalSeconds must be >= 60")
    assert(type(CONFIG.OnePlayerHopRetrySeconds) == "number" and CONFIG.OnePlayerHopRetrySeconds >= 5,
        "OnePlayerHopRetrySeconds must be >= 5")
    assert(type(CONFIG.OnePlayerHopMaxPages) == "number" and CONFIG.OnePlayerHopMaxPages >= 1
        and CONFIG.OnePlayerHopMaxPages % 1 == 0, "Invalid OnePlayerHopMaxPages")
    assert(type(CONFIG.OnePlayerHopTargetPlayers) == "number" and CONFIG.OnePlayerHopTargetPlayers >= 0
        and CONFIG.OnePlayerHopTargetPlayers % 1 == 0, "Invalid OnePlayerHopTargetPlayers")

    local loadedBy = os.clock() + 60
    while player:GetAttribute("__LOADED") ~= true do
        assert(os.clock() < loadedBy, "Player data loading timeout")
        if env.JackpotTradeOnlyStop then return end
        task.wait(0.25)
    end

    local function loadModule(path)
        local node = RS
        for name in path:gmatch("[^.]+") do
            node = node:WaitForChild(name, 20)
            assert(node, "Missing module: " .. path)
        end
        return require(node)
    end

    local data = loadModule("Framework.Features.Data.DataController")
    local rules = loadModule("Framework.Features.Trading.TradeConfig")
    local Network = loadModule("Packages.Network")

    local wanted = {}
    for _, name in ipairs(CONFIG.Items) do
        assert(type(name) == "string" and name ~= "", "Invalid item name")
        assert(not wanted[name], "Duplicate item in CONFIG.Items: " .. name)
        assert(not table.find(rules.UNTRADEABLE_ENTRIES, name), name .. " cannot be traded")
        wanted[name] = true
    end
    assert(next(wanted), "CONFIG.Items is empty")
    assert(type(CONFIG.MinJackpotToHop) == "number" and CONFIG.MinJackpotToHop >= 1
        and CONFIG.MinJackpotToHop % 1 == 0, "MinJackpotToHop must be a positive integer")

    local function inventory()
        assert(player:GetAttribute("__LOADED") == true, "Player data unavailable")
        local value = data.Inventory()
        assert(type(value) == "table", "Inventory unavailable; not treating it as empty")
        return value
    end

    local function itemAmountByName(itemName)
        local total = 0
        for _, entry in pairs(inventory()) do
            assert(type(entry) == "table", "Invalid inventory entry")
            if entry.name == itemName then
                assert(type(entry.amount) == "number" and entry.amount >= 0, "Invalid item amount")
                total = total + entry.amount
            end
        end
        return total
    end

    local function jackpotAmount()
        return itemAmountByName("Jackpot Spin")
    end

    -- กันไอดีที่เริ่มต้น Jackpot Spin = 0 ไม่ให้ Autochange ทันที
    -- ต้องเคยตรวจพบ Jackpot Spin >= 1 ก่อน และบันทึก marker ลง executor workspace
    local jackpotUnlocked = false
    local jackpotStateFile
    local onePlayerHopStateFile, lastOnePlayerHopAt
    if not receiverMode then
        assert(type(isfile) == "function" and type(writefile) == "function",
            "Executor file API (isfile/writefile) is required for Jackpot workspace state")

        local stateFolder = CONFIG.JackpotStateFolder
        assert(type(stateFolder) == "string" and stateFolder ~= "", "Invalid JackpotStateFolder")
        if type(isfolder) == "function" and type(makefolder) == "function" then
            if not isfolder(stateFolder) then makefolder(stateFolder) end
            jackpotStateFile = stateFolder .. "/jackpot_seen_" .. tostring(player.UserId) .. ".txt"
        else
            -- executor บางตัวไม่มี folder API: เก็บ marker ไว้ที่ workspace root แทน
            jackpotStateFile = "jackpot_seen_" .. tostring(player.UserId) .. ".txt"
        end
        jackpotUnlocked = isfile(jackpotStateFile)
        if jackpotUnlocked then
            log("Jackpot gate already unlocked from workspace for UserId", player.UserId)
        end

        -- เวลา Hop แยกตาม UserId และเก็บข้ามการ Teleport/autorun
        assert(type(readfile) == "function", "Executor readfile API is required for 15-minute hop state")
        onePlayerHopStateFile = stateFolder .. "/one_player_hop_" .. tostring(player.UserId) .. ".txt"
        if jackpotStateFile:sub(1, #stateFolder + 1) ~= stateFolder .. "/" then
            onePlayerHopStateFile = "one_player_hop_" .. tostring(player.UserId) .. ".txt"
        end
        local now = os.time()
        if isfile(onePlayerHopStateFile) then
            local ok, saved = pcall(function() return tonumber(readfile(onePlayerHopStateFile)) end)
            if ok and saved and saved > 0 and saved <= now + CONFIG.OnePlayerHopIntervalSeconds then
                lastOnePlayerHopAt = saved
            end
        end
        if not lastOnePlayerHopAt then
            lastOnePlayerHopAt = now -- เริ่มนับ 15 นาทีหลังเปิดสคริปต์ครั้งแรก
            writefile(onePlayerHopStateFile, tostring(lastOnePlayerHopAt))
        end
    end

    local function updateJackpotGate()
        if receiverMode or jackpotUnlocked then return jackpotUnlocked end
        local amount = jackpotAmount()
        if amount < 1 then return false end

        -- เขียน marker ก่อนอนุญาตให้เทรด/Autochange เพื่อให้รอดแม้ script rerun หรือ teleport
        local ok, err = pcall(function()
            writefile(jackpotStateFile, tostring(os.time()) .. "|" .. tostring(amount))
        end)
        if not ok then
            warn("[JackpotTrade] Could not save Jackpot workspace state:", err)
            return false
        end
        jackpotUnlocked = true
        log("Jackpot gate unlocked; detected Jackpot Spin =", amount, "and saved workspace state")
        return true
    end

    local function receiverHere()
        for _, candidate in ipairs(Players:GetPlayers()) do
            if candidate.Name:lower() == CONFIG.Receiver:lower() then return candidate end
        end
    end

    local changed = false
    local lastJackpotWaitLog = -math.huge
    local function autochangeIfJackpotEmpty()
        if receiverMode or not CONFIG.AutochangeEnabled or activePartner or tradeBusy or teleportInProgress or changed
            or env.JackpotTradeOnlyStop then return false end

        -- ต้องเคยตรวจพบ Jackpot Spin >= 1 และเซฟ workspace marker ก่อน
        -- Gems และ Trait Reroll ไม่เกี่ยวกับการตัดสินใจ Autochange
        updateJackpotGate()
        if not jackpotUnlocked then
            if jackpotAmount() == 0 and os.clock() - lastJackpotWaitLog >= 15 then
                lastJackpotWaitLog = os.clock()
                log("Jackpot Spin = 0; waiting for first Jackpot Spin before Autochange")
            end
            return false
        end
        if jackpotAmount() > 0 then return false end

        log("Jackpot gate unlocked; confirming Jackpot Spin = 0 for 5 seconds (other Items ignored)")
        local began = os.clock()
        repeat
            if jackpotAmount() > 0 or activePartner or env.JackpotTradeOnlyStop then return false end
            task.wait(0.25)
        until os.clock() - began >= 5

        local clientBy = os.clock() + 60
        while not (env.client and type(env.client.ChangeToFolder) == "function") do
            assert(os.clock() < clientBy, "FarmSync client unavailable after 60 seconds")
            if jackpotAmount() > 0 or activePartner or env.JackpotTradeOnlyStop then return false end
            task.wait(0.25)
        end
        if jackpotAmount() > 0 or activePartner or env.JackpotTradeOnlyStop then return false end
        changed = true
        intentionalExit = true -- ไม่รีจอยแข่งกับ FarmSync ที่กำลังเปลี่ยนไอดี
        log("Calling FarmSync Autochange: Jackpot Spin is zero")
        local ok, result = pcall(function()
            return env.client:ChangeToFolder(CONFIG.FromFolderId, CONFIG.ToFolderId,
                CONFIG.WithoutReplacement, nil)
        end)
        log("Autochange result:", ok, result)
        assert(ok and result ~= false, "FarmSync Autochange failed; request not repeated")
        return true
    end

    local function httpJSON(url, body)
        local requestFn = env.request or env.http_request or request or http_request
        assert(type(requestFn) == "function", "Executor HTTP request unavailable")
        local response = requestFn({
            Url = url, Method = body and "POST" or "GET",
            Headers = {["Content-Type"] = "application/json"},
            Body = body and HS:JSONEncode(body) or nil,
        })
        assert(type(response) == "table", "Invalid HTTP response")
        local status = tonumber(response.StatusCode or response.Status) or 0
        assert(status == 0 or (status >= 200 and status < 300), "HTTP " .. status)
        local result = response.Body or response.body
        if type(result) == "string" then result = HS:JSONDecode(result) end
        assert(type(result) == "table", "Invalid HTTP JSON")
        return result
    end

    local receiverUserId
    local lastHopWaitLog = -math.huge
    local function followReceiver()
        if receiverHere() or env.JackpotTradeOnlyStop or teleportInProgress or tradeBusy or changed then return end

        -- เกณฑ์ Hop เช็ค Jackpot Spin เท่านั้น; Gems/Trait Reroll ไม่ทำให้ Hop
        local jackpot = jackpotAmount()
        if jackpot < CONFIG.MinJackpotToHop then
            if os.clock() - lastHopWaitLog >= 15 then
                lastHopWaitLog = os.clock()
                log("Waiting to hop: Jackpot Spin =", jackpot,
                    "; need at least", CONFIG.MinJackpotToHop)
            end
            return
        end

        -- บันทึกว่าเคยมี Jackpot ก่อนวาร์ป; ถ้าเซฟไม่ได้ ห้าม Hop เพราะจะทำสถานะสูญหาย
        if not updateJackpotGate() then return end
        receiverUserId = receiverUserId or Players:GetUserIdFromNameAsync(CONFIG.Receiver)
        local body = httpJSON("https://presence.roblox.com/v1/presence/users", {userIds = {receiverUserId}})
        local presence = body.userPresences and body.userPresences[1]
        if not presence or presence.userPresenceType ~= 2 or not presence.gameId or presence.gameId == "" then
            log("Receiver has no joinable server; retrying")
            return
        end
        if tonumber(presence.placeId) ~= CONFIG.PlaceId then
            log("Receiver is in another place; retrying")
            return
        end
        if presence.gameId == game.JobId then return end
        -- Recheck the live amount after presence lookup; do not hop on a stale Jackpot reading.
        if jackpotAmount() < CONFIG.MinJackpotToHop then
            log("Jackpot Spin dropped below hop threshold; staying in current server")
            return
        end
        if teleportInProgress or tradeBusy or activePartner or changed then return end
        teleportInProgress = true

        local failed, failureText = false, ""
        teleportConnection = TS.TeleportInitFailed:Connect(function(target, result, message)
            if target == player then
                failed = true
                failureText = tostring(result) .. ": " .. tostring(message)
            end
        end)
        log("Joining receiver:", CONFIG.Receiver)
        local ok, err = pcall(function()
            TS:TeleportToPlaceInstance(CONFIG.PlaceId, presence.gameId, player)
        end)
        if not ok then failed, failureText = true, tostring(err) end
        local nextNotice = os.clock() + 30
        while not failed and not env.JackpotTradeOnlyStop do
            if os.clock() >= nextNotice then
                log("Teleport still pending; waiting without sending another request")
                nextNotice = os.clock() + 30
            end
            task.wait(0.25)
        end
        if teleportConnection then teleportConnection:Disconnect(); teleportConnection = nil end
        if failed then
            teleportInProgress = false
            log("Teleport failed:", failureText)
        end
    end

    -- เดินหาเซิร์ฟเวอร์คนน้อยทุก 15 นาที โดยไม่ขัดจังหวะเทรดหรือวาร์ปหา Receiver
    local function findOnePlayerServer()
        local cursor
        for _ = 1, CONFIG.OnePlayerHopMaxPages do
            local url = "https://games.roblox.com/v1/games/" .. tostring(CONFIG.PlaceId)
                .. "/servers/Public?sortOrder=Asc&limit=100"
            if cursor and cursor ~= "" then url = url .. "&cursor=" .. HS:UrlEncode(cursor) end
            local page = httpJSON(url)
            assert(type(page.data) == "table", "Server-list API returned invalid data")
            local candidates = {}
            for _, server in ipairs(page.data) do
                if type(server) == "table" and type(server.id) == "string" and server.id ~= ""
                    and server.id ~= game.JobId
                    and tonumber(server.playing) == CONFIG.OnePlayerHopTargetPlayers
                    and tonumber(server.maxPlayers) and tonumber(server.maxPlayers) > tonumber(server.playing) then
                    table.insert(candidates, server.id)
                end
            end
            if #candidates > 0 then return candidates[math.random(1, #candidates)] end
            cursor = page.nextPageCursor
            if type(cursor) ~= "string" or cursor == "" then break end
        end
        return nil
    end

    local function onePlayerHopAllowed()
        if receiverMode or not env.JackpotOnePlayerHopEnabled or not hopThreadAlive
            or env.JackpotTradeOnlyStop or intentionalExit or changed
            or teleportInProgress or activePartner or tradeBusy then return false end
        local amount = jackpotAmount()
        if amount >= CONFIG.MinJackpotToHop then return false end -- ให้ Receiver มาก่อน
        if amount == 0 and jackpotUnlocked and CONFIG.AutochangeEnabled then return false end
        return true
    end

    local function saveOnePlayerHopTime(timestamp)
        writefile(onePlayerHopStateFile, tostring(timestamp))
        lastOnePlayerHopAt = timestamp
    end

    local function startOnePlayerHop()
        if receiverMode then return end
        task.spawn(function()
            while hopThreadAlive and not env.JackpotTradeOnlyStop do
                if os.time() - lastOnePlayerHopAt >= CONFIG.OnePlayerHopIntervalSeconds
                    and onePlayerHopAllowed() then
                    local ok, serverId = pcall(findOnePlayerServer)
                    if not ok then
                        warn("[OnePlayerHop] Could not fetch server list:", serverId)
                        task.wait(CONFIG.OnePlayerHopRetrySeconds)
                    elseif not serverId then
                        log("[OnePlayerHop] No server with", CONFIG.OnePlayerHopTargetPlayers,
                            "players found; retrying")
                        task.wait(CONFIG.OnePlayerHopRetrySeconds)
                    elseif not onePlayerHopAllowed() then
                        task.wait(1) -- Jackpot/Trade อาจเปลี่ยนระหว่างค้นหา
                    else
                        -- Stamp ก่อนส่งคำขอ เพื่อไม่ให้ autorun นับ 15 นาทีใหม่ทุกวาร์ป
                        teleportInProgress = true
                        local stampOk, stampErr = pcall(saveOnePlayerHopTime, os.time())
                        if not stampOk then
                            teleportInProgress = false
                            warn("[OnePlayerHop] Could not save hop timestamp:", stampErr)
                            task.wait(CONFIG.OnePlayerHopRetrySeconds)
                        else
                            local failed, failureText = false, ""
                            teleportConnection = TS.TeleportInitFailed:Connect(function(target, result, message)
                                if target == player then
                                    failed = true
                                    failureText = tostring(result) .. ": " .. tostring(message)
                                end
                            end)
                            log("[OnePlayerHop] Joining server with", CONFIG.OnePlayerHopTargetPlayers,
                                "players before joining:", serverId)
                            local sent, problem = pcall(function()
                                TS:TeleportToPlaceInstance(CONFIG.PlaceId, serverId, player)
                            end)
                            if not sent then failed, failureText = true, tostring(problem) end
                            local nextNotice = os.clock() + 30
                            while hopThreadAlive and not env.JackpotTradeOnlyStop and not failed do
                                if os.clock() >= nextNotice then
                                    log("[OnePlayerHop] Teleport pending; no duplicate request sent")
                                    nextNotice = os.clock() + 30
                                end
                                task.wait(0.25)
                            end
                            if teleportConnection then teleportConnection:Disconnect(); teleportConnection = nil end
                            if failed then
                                teleportInProgress = false
                                -- Teleport ล้มเหลว ให้ลองใหม่ตาม RetrySeconds ไม่ต้องรออีก 15 นาที
                                local retryAt = os.time() - CONFIG.OnePlayerHopIntervalSeconds
                                    + CONFIG.OnePlayerHopRetrySeconds
                                local saved, saveErr = pcall(saveOnePlayerHopTime, retryAt)
                                if not saved then warn("[OnePlayerHop] Could not save retry time:", saveErr) end
                                warn("[OnePlayerHop] Teleport failed:", failureText)
                                task.wait(CONFIG.OnePlayerHopRetrySeconds)
                            end
                        end
                    end
                else
                    task.wait(1)
                end
            end
        end)
    end

    startOnePlayerHop()

    if not receiverMode then
        log("Observing configured items for", CONFIG.ObserveSeconds, "seconds")
        pause(CONFIG.ObserveSeconds)
        if env.JackpotTradeOnlyStop then return end
        if autochangeIfJackpotEmpty() then return end
        while not receiverHere() and not env.JackpotTradeOnlyStop do
            if autochangeIfJackpotEmpty() then return end
            local ok, err = pcall(followReceiver)
            if not ok then log("Follow error:", err) end
            pause(CONFIG.ReceiverRetrySeconds)
        end
        if env.JackpotTradeOnlyStop then return end
    end

    local comm = Network.ClientComm.new(RS.Network, false, "TradeService")
    local tradingEnabled = comm:GetProperty("TradingEnabled")
    local propertyBy = os.clock() + 15
    while tradingEnabled:Get() == nil and os.clock() < propertyBy do task.wait(0.1) end
    assert(tradingEnabled:Get() == true, "Trading unavailable")
    assert(player.AccountAge >= rules.MIN_ACCOUNT_AGE, "Account too new to trade")
    assert(data.Rolls() >= rules.MIN_ROLLS, "Not enough rolls to trade")

    local requestSignal = comm:GetSignal("RequestTrade")
    local respondSignal = comm:GetSignal("RespondToRequest")
    local offerSignal = comm:GetSignal("ChangeOffer")
    local advanceSignal = comm:GetSignal("AdvanceTrade")
    cancelSignal = comm:GetSignal("CancelTrade")
    local state, ended, fatal, awaiting, plan
    local lastAdvance = -math.huge
    local confirmSent = -math.huge
    local readySent = false

    tradeConnection = comm:GetSignal("TradeEvent"):Connect(function(event, payload)
        if event == "RequestReceived" and receiverMode then
            if not env.JackpotTradeOnlyStop and not activePartner and payload
                and typeof(payload.player) == "Instance" and payload.player:IsA("Player") then
                respondSignal:Fire(true)
            end
        elseif event == "Started" then
            activePartner, state, ended = payload.partner, nil, nil
            readySent, confirmSent = false, -math.huge
            if not receiverMode and activePartner ~= awaiting then fatal = "Unexpected trade partner" end
        elseif event == "Updated" and activePartner then
            if payload.partner ~= activePartner then fatal = "Trade partner changed" else state = payload end
        elseif event == "Ended" and activePartner then
            ended, activePartner, state = payload.reason, nil, nil
        end
    end)

    local function waitFor(predicate, seconds)
        local deadline = os.clock() + seconds
        repeat
            if fatal then error(fatal) end
            if env.JackpotTradeOnlyStop then return false end
            if predicate() then return true end
            task.wait(0.1)
        until os.clock() >= deadline
        return false
    end

    local function exactOffer(offer)
        for key, amount in pairs(plan) do if offer[key] ~= amount then return false end end
        for key, amount in pairs(offer) do if plan[key] ~= amount then return false end end
        return true
    end

    local function advance()
        if not state or not activePartner then return end
        local now = os.clock()
        if now - lastAdvance < 0.35 then return end
        if state.phase == "Offer" and not state.ownReady and not readySent then
            lastAdvance = now
            readySent = true -- Ready toggles server-side, so never send it blindly twice.
            advanceSignal:Fire()
        elseif state.phase == "Confirm" and not state.ownAccepted
            and now - confirmSent >= CONFIG.ConfirmRetrySeconds then
            lastAdvance, confirmSent = now, now
            advanceSignal:Fire()
        end
    end

    if receiverMode then
        if data.TradeRequestsEnabled() ~= true then
            comm:GetSignal("SetTradeRequestsEnabled"):Fire(true)
            assert(waitFor(function() return data.TradeRequestsEnabled() == true end, 10),
                "Could not enable trade requests")
        end
        log("Receiver mode: accepting", table.concat(CONFIG.Items, ", "))
        local started
        while not env.JackpotTradeOnlyStop do
            if fatal then error(fatal) end
            if activePartner then
                started = started or os.clock()
                assert(os.clock() - started < CONFIG.TradeTimeout, "Receiver trade timeout")
                if state then
                    assert(next(state.ownOffer) == nil, "Receiver offered an item")
                    local count = 0
                    for _, entry in pairs(state.otherOffer) do
                        assert(wanted[entry.name] and entry.amount > 0, "Unexpected incoming item")
                        count = count + 1
                    end
                    if count > 0 and state.otherReady then advance() end
                end
            else
                started = nil
            end
            task.wait(0.1)
        end
        return
    end

    while not env.JackpotTradeOnlyStop do
        -- เช็คและเซฟ marker ให้เร็วที่สุดก่อนสร้างแผนเทรด Jackpot Spin ออก
        updateJackpotGate()
        -- ต้องตรวจทุกครั้ง แม้ Gems/Trait Reroll ยังอยู่ (#keys จะไม่เป็นศูนย์)
        -- หลังเทรด Jackpot หมดแล้ว จึง Autochange โดยไม่รอ Items อื่นหมด
        if autochangeIfJackpotEmpty() then return end
        local bag = inventory()
        local keys = {}
        for key, entry in pairs(bag) do
            if wanted[entry.name] and entry.amount > 0 then table.insert(keys, key) end
        end
        table.sort(keys)
        if #keys == 0 then
            task.wait(1)
            continue
        end

        -- ถ้าเจอ Jackpot แล้วแต่บันทึก marker ไม่สำเร็จ ห้ามเทรดออกก่อนเซฟ
        if jackpotAmount() > 0 and not updateJackpotGate() then
            log("Waiting for successful workspace save before trading Jackpot Spin")
            task.wait(1)
            continue
        end

        awaiting = receiverHere()
        if not awaiting then
            local ok, err = pcall(followReceiver)
            if not ok then log("Follow error:", err) end
            pause(CONFIG.ReceiverRetrySeconds)
            continue
        end

        plan = {}
        local before = {}
        for index = 1, math.min(#keys, rules.MAX_UNIQUE_ENTRIES) do
            local key = keys[index]
            plan[key], before[key] = bag[key].amount, bag[key].amount
        end
        ended, fatal = nil, nil
        -- หาก Hop รอบ 15 นาทีเริ่มก่อนแผนเทรดเสร็จ อย่ายิงคำขอเทรดซ้อนกับ Teleport
        if teleportInProgress then task.wait(1); continue end
        tradeBusy = true
        log("Requesting trade with", awaiting.Name)
        requestSignal:Fire(awaiting)
        if not waitFor(function() return activePartner ~= nil end, rules.REQUEST_DURATION + 2) then
            tradeBusy = false
            log("Trade request expired or was declined")
            pause(math.max(CONFIG.RequestInterval, rules.REQUEST_COOLDOWN + 0.5))
            continue
        end
        assert(waitFor(function() return state ~= nil or ended ~= nil end, 10) and state, "No initial trade state")
        assert(next(state.ownOffer) == nil, "Initial offer not empty")
        for _, key in ipairs(keys) do
            if plan[key] then
                assert(activePartner == awaiting and state.phase == "Offer", "Trade changed while adding items")
                offerSignal:Fire(key, plan[key])
                assert(waitFor(function() return state and state.ownOffer[key] == plan[key] end, 10),
                    "Offered item was not confirmed")
                task.wait(0.15)
            end
        end
        local finishBy = os.clock() + CONFIG.TradeTimeout
        while activePartner and not env.JackpotTradeOnlyStop do
            assert(os.clock() < finishBy, "Trade confirmation timeout")
            if state then
                assert(exactOffer(state.ownOffer), "Offer changed unexpectedly")
                assert(next(state.otherOffer) == nil, "Receiver offered an item")
                advance()
            end
            task.wait(0.1)
        end
        if env.JackpotTradeOnlyStop then return end
        assert(ended == "Completed", "Trade did not complete: " .. tostring(ended))
        assert(waitFor(function()
            local current = inventory()
            for key, amount in pairs(before) do
                if current[key] and current[key].amount > amount - plan[key] then return false end
            end
            return true
        end, 15), "Inventory transfer not confirmed")
        tradeBusy = false
        log("Trade completed")
        pause(math.max(CONFIG.RequestInterval, rules.REQUEST_COOLDOWN + 0.5))
    end
end

local ok, err = pcall(main)
hopThreadAlive = false
if activePartner and cancelSignal then pcall(function() cancelSignal:Fire() end) end
if tradeConnection then tradeConnection:Disconnect() end
if teleportConnection then teleportConnection:Disconnect() end
env.JackpotTradeOnlyRunning = false
if not ok then warn("[JackpotTrade]", err) else log("Stopped") end
