repeat task.wait() until game:IsLoaded()
-- Standalone code redemption. Do not manually redeem or run another redeemer concurrently.
local CONFIG = {
    Codes = {"UPDATE5", "250KLIKES", "100KLIKES", "40KCCU", "30KCCU", "UPDATE4",
        "20KCCU", "10KCCU", "5KCCU", "1KCCU", "UPDATE3", "UPDATE2", "UPDATE1", "RELEASE"},
    DelaySeconds = 0.65, -- Minimum interval between sends; server debounce observed at 0.5s
    ResponseTimeout = 15, -- เกินเวลานี้จะพักรอผลเดิม ไม่ส่งซ้ำ
    CheckInterval = 60, -- วนเช็ครายการโค้ดทุกกี่วินาที
}
local env = getgenv and getgenv() or _G
if env.AnimeDiceCodesRunning then warn("Auto Codes already running") return end
env.AnimeDiceCodesRunning, env.AnimeDiceCodesStop = true, false
local listener
local history = {}
local function show(message)
    print("[Auto Codes]", message)
end
local function main()
    for _, value in ipairs({CONFIG.DelaySeconds, CONFIG.ResponseTimeout, CONFIG.CheckInterval}) do
        assert(type(value) == "number" and value > 0 and value < math.huge, "Invalid timing config")
    end
    assert(game.PlaceId == 113290951185459, "Wrong game: expected Anime Dice")
    local RS = game:GetService("ReplicatedStorage")
    local player = game:GetService("Players").LocalPlayer
    assert(player, "LocalPlayer not ready; run again after joining")
    local pg = player:FindFirstChild("PlayerGui")
    local old = pg and pg:FindFirstChild("AnimeDiceAutoCodes")
    if old then old:Destroy() end
    show(player.Name .. " | Waiting for data...")
    local deadline = os.clock() + 60
    while player:GetAttribute("__LOADED") ~= true do
        if env.AnimeDiceCodesStop then return end
        assert(os.clock() < deadline, "Player data loading timeout")
        task.wait(0.25)
    end
    local function module(path)
        local node = RS
        for name in path:gmatch("[^.]+") do
            node = node:WaitForChild(name, 15)
            assert(node, "Missing module: " .. path)
        end
        return require(node)
    end
    local data = module("Framework.Features.Data.DataController")
    local Network = module("Packages.Network")
    local root = RS:WaitForChild("Network", 15)
    assert(root, "Network unavailable")
    local redeem = Network.ClientComm.new(root, false, "MonetizationService"):GetSignal("RedeemCode")
    local notifications = Network.ClientComm.new(root, false, "NotificationService"):GetSignal("TextNotification")
    local current, reply
    listener = notifications:Connect(function(payload)
        if not current or type(payload) ~= "table" then return end
        -- These messages have no code ID; only one request is allowed at a time.
        if payload.message == "Invalid code." or payload.message == "You already redeemed this code." then
            reply = payload.message
        end
    end)
    local function redeemed(code)
        assert(player:GetAttribute("__LOADED") == true, "Player data became unavailable")
        local codes = data.RedeemedCodes()
        assert(type(codes) == "table", "RedeemedCodes unavailable")
        return codes[code] == true
    end
    local lastOutcomes = {}
    local lastSentAt = -math.huge
    env.AnimeDiceCodesResults = history
    while not env.AnimeDiceCodesStop do
    local seen = {} -- กันซ้ำภายในรอบนี้เท่านั้น
    for index, raw in ipairs(CONFIG.Codes) do
        if env.AnimeDiceCodesStop then return end
        assert(type(raw) == "string", "Code must be a string")
        local code = raw:match("^%s*(.-)%s*$"):upper()
        assert(#code > 0 and #code <= 50, "Invalid code length")
        if not seen[code] then
            seen[code] = true
            local outcome
            if redeemed(code) then
                outcome = "Already redeemed (skipped)"
            else
                while os.clock() - lastSentAt < math.max(0.65, CONFIG.DelaySeconds) do
                    if env.AnimeDiceCodesStop then return end
                    task.wait(0.05)
                end
                if env.AnimeDiceCodesStop then return end
                current, reply = code, nil
                show(string.format("%d/%d Redeeming %s...", index, #CONFIG.Codes, code))
                lastSentAt = os.clock()
                redeem:Fire(code)
                local untilTime = os.clock() + CONFIG.ResponseTimeout
                repeat
                    if redeemed(code) then outcome = "Redeemed (confirmed)" break end
                    if reply then outcome = reply break end
                    if env.AnimeDiceCodesStop then break end
                    task.wait(0.05)
                until os.clock() >= untilTime
                if not outcome and not env.AnimeDiceCodesStop then
                    show(code .. ": Waiting for previous response; no new requests sent")
                    while not env.AnimeDiceCodesStop do
                        if redeemed(code) then outcome = "Redeemed (confirmed late)" break end
                        if reply then outcome = reply break end
                        task.wait(0.5)
                    end
                end
                current = nil
                if env.AnimeDiceCodesStop then return end
            end
            if lastOutcomes[code] ~= outcome then
                lastOutcomes[code] = outcome
                table.insert(history, code .. ": " .. outcome)
                if #history > 200 then table.remove(history, 1) end
                show(code .. ": " .. outcome)
            end
        end
    end
    show(player.Name .. " | Next code check in " .. CONFIG.CheckInterval .. " seconds")
    local nextCheck = os.clock() + CONFIG.CheckInterval
    repeat task.wait(0.25) until env.AnimeDiceCodesStop or os.clock() >= nextCheck
    end
end
local ok, err = pcall(main)
if listener then listener:Disconnect() end
env.AnimeDiceCodesRunning = false
if not ok then show("ERROR: " .. tostring(err))
elseif env.AnimeDiceCodesStop then show("Stopped") end
