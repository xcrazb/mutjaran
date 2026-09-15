--[[
    AUTO PET MUTATION — Full GUI (v11.7)
    ----------------------------------------------------------
    Fix v11.7:
    - Webhook URL & Mention input gak overflow
    - Text truncate biar gak kepotong aneh
    - Kolom kanan pakai ClipsDescendants
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local DEFAULT_GEAR_NAME = "DiamondCookie"
local SAFETY_MAX_GEAR = 100
local SLOT_BEFORE_INSERT = 0
local SLOT_AFTER_INSERT  = 1
local DELAY_EQUIP = 0.5
local DELAY_USE   = 0.5
local DELAY_STEP  = 1
local DELAY_SLOT  = 0.8
local POLL_INTERVAL = 5

local FALLBACK_MUTATIONS = {
    "Tiny", "Gold", "Diamond", "Rainbow", "Mythical",
    "Divine", "Celestial", "Galaxy", "Shadow", "Frost",
    "Fire", "Nature",
}

local function getRequestFunction()
    if http and http.request then return http.request end
    if http_request then return http_request end
    if request then return request end
    local env = getfenv and getfenv() or _G
    if env.syn and env.syn.request then return env.syn.request end
    if env.fluxus and env.fluxus.request then return env.fluxus.request end
    return nil
end

local getPlayerData, getSharedTime, PET_MUTATION_TIME, PetMutations
local getPetAgeFromData, MAX_AGE, ToolType

pcall(function() getPlayerData = require(ReplicatedStorage.TS.state["player-data"]).getPlayerData end)
pcall(function() getSharedTime = require(game:GetService("StarterPlayer").StarterPlayerScripts.TS.systems.core.sharedTime).getSharedTime end)
pcall(function() PET_MUTATION_TIME = require(ReplicatedStorage.TS.constants).PET_MUTATION_TIME end)
pcall(function() PetMutations = require(ReplicatedStorage.TS.lists.game["pet-mutations"]).PetMutations end)
pcall(function()
    local v4 = require(ReplicatedStorage.TS.utils["pet-age.utils"])
    getPetAgeFromData = v4.getPetAgeFromData
    MAX_AGE = v4.MAX_AGE
end)
pcall(function() ToolType = require(ReplicatedStorage.TS.lists.game["tool-meta"]).ToolType end)

local function modulesReady() return getPlayerData and getSharedTime and PET_MUTATION_TIME end
local function ageReady() return getPlayerData and getPetAgeFromData and MAX_AGE end

local function getMutationList()
    local list = {}
    if PetMutations then
        for key, data in pairs(PetMutations) do table.insert(list, data.name or key) end
        table.sort(list)
    end
    if #list == 0 then list = FALLBACK_MUTATIONS end
    return list
end

local inventoryStateModule = nil
pcall(function()
    inventoryStateModule = require(game.Players.LocalPlayer.PlayerScripts.TS.ui.features.toolbar["inventory.state"])
end)

local function getRemo(name)
    local ok, remote = pcall(function()
        return ReplicatedStorage
            :WaitForChild("rbxts_include", 10)
            :WaitForChild("node_modules", 10)
            :WaitForChild("@rbxts", 10)
            :WaitForChild("remo", 10)
            :WaitForChild("src", 10)
            :WaitForChild("container", 10)
            :WaitForChild(name, 10)
    end)
    return ok and remote or nil
end

local Remotes = {
    equipTool    = getRemo("tools.equipTool"),
    unequipTool  = getRemo("tools.unequipTool"),
    placePet     = getRemo("pets.placePetFromInventory"),
    usePetGear   = getRemo("pets.usePetGearOnPet"),
    switchSlot   = getRemo("pets.switchPetLoadout"),
    startMut     = getRemo("pets.startMutation"),
    collectMut   = getRemo("pets.collectMutation"),
}

local State = {
    Running = false,
    PetId = "",
    PetDisplayName = "",
    GearName = DEFAULT_GEAR_NAME,
    AutoDetect = true,
    TargetMutations = {},
    WebhookURL = "",
    WebhookEnabled = true,
    WebhookMention = "",
    WebhookOnlyTarget = false,
    PetList = {},
    Stats = { Mutations = 0, GearUsed = 0, Fails = 0, StartTime = 0, History = {} },
}

local function safeFire(remote, ...)
    if not remote then return false end
    local args = {...}
    local ok, err = pcall(function() remote:FireServer(table.unpack(args)) end)
    if not ok then warn("[AutoMut] Fire gagal:", err) end
    return ok
end

local function safeInvoke(remote, ...)
    if not remote then return false, nil end
    local args = {...}
    local ok, result = pcall(function() return remote:InvokeServer(table.unpack(args)) end)
    if not ok then warn("[AutoMut] Invoke gagal:", result) end
    return ok, result
end

local function log(msg)
    if LogLabel then
        local time = os.date("%H:%M:%S")
        local newText = LogLabel.Text .. "\n[" .. time .. "] " .. msg
        local lines = {}
        for line in newText:gmatch("[^\n]+") do table.insert(lines, line) end
        while #lines > 16 do table.remove(lines, 1) end
        LogLabel.Text = table.concat(lines, "\n")
    end
    print("[AutoMut] " .. msg)
end

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 0 then seconds = 0 end
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function getPetAge(petId)
    if not ageReady() then return nil end
    local ok, data = pcall(function() return getPlayerData(LocalPlayer) end)
    if not ok or not data or not data.inventory or not data.inventory.pets then return nil end
    local petData = data.inventory.pets[petId]
    if not petData then return nil end
    local ok2, age = pcall(function() return getPetAgeFromData(petData) end)
    if not ok2 then return nil end
    return age
end

local function parseMutationResult(result)
    if result == nil or result == false then return nil end
    if type(result) == "string" then return result end
    if type(result) == "table" then
        return result.mutation or result.mutationType or result.name or result.type
    end
    return tostring(result)
end

local function isTargetReached(mutationName)
    if not mutationName then return false end
    if next(State.TargetMutations) == nil then return false end
    return State.TargetMutations[mutationName] == true
end

local function scanPets()
    if not inventoryStateModule then return {} end
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return {} end
    local pets = {}
    for stackKey, item in pairs(stacked) do
        local tt = tostring(item.toolType):lower()
        if tt:find("pet") and item.items and item.items[1] then
            local pd = item.items[1].data
            table.insert(pets, {
                id = item.items[1].id,
                stackKey = stackKey,
                displayName = item.displayName or item.itemName,
                mutation = pd.mutation,
                mutationCount = pd.mutationCount,
                count = item.count,
            })
        end
    end
    table.sort(pets, function(a, b) return a.displayName < b.displayName end)
    return pets
end

local function sendWebhookPayload(payload)
    local req = getRequestFunction()
    if not req then return false end
    local ok, err = pcall(function()
        local r = req({
            Url = State.WebhookURL,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload)
        })
        if r and r.StatusCode and r.StatusCode >= 200 and r.StatusCode < 300 then
            log("📤 Webhook ✅ (" .. r.StatusCode .. ")")
        elseif r and r.StatusCode then
            log("❌ Webhook HTTP " .. r.StatusCode)
        end
    end)
    if not ok then warn("[AutoMut] Webhook error:", err) end
end

local function sendWebhook(mutationName, isTarget, extraInfo)
    if not State.WebhookEnabled or State.WebhookURL == "" then return end
    if State.WebhookOnlyTarget and not isTarget then return end

    local color = isTarget and 5763719 or 3447003
    local title = isTarget and "🎯 TARGET MUTATION TERCAPAI!" or "🧬 Mutasi Baru Didapat"
    local emoji = isTarget and "🎯" or "🎉"
    local total = State.Stats.Mutations
    local age = getPetAge(State.PetId) or "?"
    local elapsed = math.floor(tick() - State.Stats.StartTime)
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60

    local desc = string.format(
        "%s **%s** didapat!\n\n**Info Mutasi:**\n" ..
        "• Pet: `%s`\n• Mutation: `%s`\n• Target: `%s`\n• Total Mutasi: `%d`\n" ..
        "• Umur Pet: `%s / %s`\n• Gear Dipakai: `%d`\n• Fails: `%d`\n" ..
        "• Uptime: `%02d:%02d`\n",
        emoji, mutationName or "?",
        State.PetDisplayName or "?",
        tostring(mutationName or "?"),
        isTarget and "✅ YA" or "❌ BUKAN", total,
        tostring(age), tostring(MAX_AGE or 50),
        State.Stats.GearUsed, State.Stats.Fails, mins, secs
    )
    if extraInfo then desc = desc .. "\n**Extra:**\n" .. extraInfo end

    task.spawn(function()
        sendWebhookPayload({
            content = State.WebhookMention ~= "" and State.WebhookMention or "",
            username = "Auto Mutation Bot",
            embeds = {{
                title = title, description = desc, color = color,
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                footer = { text = "Auto Pet Mutation v11.7 • " .. LocalPlayer.Name },
                fields = {
                    { name = "🐾 Pet", value = "`" .. (State.PetDisplayName or "?") .. "`", inline = true },
                    { name = "🔧 Gear", value = "`" .. State.GearName .. "`", inline = true }
                }
            }}
        })
    end)
end

local function getMachineState()
    if not modulesReady() then return "Unknown", 0 end
    local ok, data = pcall(function() return getPlayerData(LocalPlayer) end)
    if not ok or not data then return "Unknown", 0 end
    local pm = data.petMutation
    if pm == nil then return "Idle", 0 end
    local ok2, st = pcall(getSharedTime)
    if not ok2 or not st then return "InProgress", 0 end
    local elapsed = st - pm.timeStarted
    local dr = pm.depletionRate or 1
    local total = PET_MUTATION_TIME / dr
    local remaining = math.max(0, total - elapsed)
    if elapsed >= total then return "Ready", 0 end
    return "InProgress", remaining
end

local function equipPet(petId) safeFire(Remotes.equipTool, petId, "pet"); task.wait(DELAY_EQUIP) end
local function equipGear(name) safeFire(Remotes.equipTool, name, "gear"); task.wait(DELAY_EQUIP) end
local function useGearOnPet(petId) return safeFire(Remotes.usePetGear, petId) end
local function switchSlot(s)
    local ok, r = safeInvoke(Remotes.switchSlot, s)
    task.wait(DELAY_SLOT)
    return ok, r
end
local function insertPet(id) return safeInvoke(Remotes.startMut, id) end
local function collectPet() return safeInvoke(Remotes.collectMut) end

local function waitForMutation()
    if State.AutoDetect and modulesReady() then
        log("⏳ Nunggu mutasi...")
        local lastLog = 0
        while State.Running do
            local state, rem = getMachineState()
            if state == "Ready" then log("✅ READY!"); return true end
            if state == "Idle" then log("⚠️ Mesin Idle"); return false end
            if state == "InProgress" then
                local now = tick()
                if now - lastLog >= 30 then
                    log("   sisa " .. formatTime(rem) .. " (" .. string.format("%.1f", rem/60) .. " menit)")
                    lastLog = now
                end
            end
            task.wait(POLL_INTERVAL)
        end
        return false
    else
        log("⏳ Nunggu manual...")
        local w = 0
        while w < 1800 do
            if not State.Running then return false end
            task.wait(POLL_INTERVAL)
            w += POLL_INTERVAL
            if w % 60 == 0 then log("   sisa " .. formatTime(1800 - w)) end
        end
        return true
    end
end

local function useGearUntilMaxAge(petId)
    if not ageReady() then
        log("⚠️ Fallback 25 gear")
        for i = 1, 25 do
            if not State.Running then return end
            equipGear(State.GearName); useGearOnPet(petId); State.Stats.GearUsed += 1
            task.wait(DELAY_USE)
        end
        return
    end
    log("🔧 Pakai gear sampai umur " .. MAX_AGE)
    local i = 0
    while State.Running do
        local age = getPetAge(petId)
        if age == nil then log("⚠️ Gagal baca umur"); break end
        if age >= MAX_AGE then log("✅ Umur " .. age .. "/" .. MAX_AGE); break end
        i += 1
        equipGear(State.GearName); useGearOnPet(petId); State.Stats.GearUsed += 1
        if i % 5 == 0 then log("   gear " .. i .. " | umur: " .. age .. "/" .. MAX_AGE) end
        task.wait(DELAY_USE)
        if i >= SAFETY_MAX_GEAR then break end
    end
    if i == 0 then log("🎯 Pet udah MAX_AGE")
    else log("✅ Selesai (" .. i .. "x)") end
end

local function updateHistory()
    if not HistoryContent then return end
    for _, c in ipairs(HistoryContent:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    if #State.Stats.History == 0 then
        local e = Instance.new("TextLabel")
        e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
        e.Text = "Belum ada mutasi"; e.TextColor3 = Color3.fromRGB(120,120,140)
        e.TextSize = 10; e.Font = Enum.Font.Gotham
        e.Parent = HistoryContent
        return
    end
    for idx = #State.Stats.History, 1, -1 do
        local entry = State.Stats.History[idx]
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 20)
        row.BackgroundColor3 = entry.isTarget and Color3.fromRGB(60, 90, 50) or Color3.fromRGB(40, 40, 55)
        row.BorderSizePixel = 0
        row.LayoutOrder = 1000 - idx
        row.Parent = HistoryContent
        local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 4); rc.Parent = row
        local num = Instance.new("TextLabel")
        num.Size = UDim2.new(0, 24, 1, 0); num.Position = UDim2.new(0, 4, 0, 0)
        num.BackgroundTransparency = 1; num.Text = "#" .. idx
        num.TextColor3 = Color3.fromRGB(150, 150, 170); num.TextSize = 9
        num.Font = Enum.Font.Code; num.Parent = row
        local mutLbl = Instance.new("TextLabel")
        mutLbl.Size = UDim2.new(0.55, 0, 1, 0); mutLbl.Position = UDim2.new(0, 28, 0, 0)
        mutLbl.BackgroundTransparency = 1; mutLbl.Text = tostring(entry.mutation or "?")
        mutLbl.TextColor3 = entry.isTarget and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(220, 220, 240)
        mutLbl.TextSize = 10; mutLbl.Font = Enum.Font.GothamBold
        mutLbl.TextXAlignment = Enum.TextXAlignment.Left; mutLbl.Parent = row
        local timeLbl = Instance.new("TextLabel")
        timeLbl.Size = UDim2.new(0.35, -4, 1, 0); timeLbl.Position = UDim2.new(0.6, 0, 0, 0)
        timeLbl.BackgroundTransparency = 1; timeLbl.Text = entry.time or "?"
        timeLbl.TextColor3 = Color3.fromRGB(150, 150, 170); timeLbl.TextSize = 9
        timeLbl.Font = Enum.Font.Code; timeLbl.TextXAlignment = Enum.TextXAlignment.Right
        timeLbl.Parent = row
        if entry.isTarget then
            local b = Instance.new("TextLabel")
            b.Size = UDim2.new(0, 12, 0, 12); b.Position = UDim2.new(1, -14, 0.5, -6)
            b.BackgroundTransparency = 1; b.Text = "🎯"; b.TextSize = 10; b.Parent = row
        end
    end
end

local function runMutationCycle()
    if not State.Running then return end
    local petId = State.PetId
    if not petId or petId == "" then
        log("❌ Pet belum dipilih!"); State.Stats.Fails += 1
        stopLoop("Pet belum dipilih"); return
    end
    log("🐾 " .. (State.PetDisplayName or petId:sub(1, 8)))
    equipPet(petId)
    safeInvoke(Remotes.placePet, petId)
    task.wait(DELAY_STEP)
    if not State.Running then return end
    useGearUntilMaxAge(petId)
    task.wait(DELAY_STEP)
    if not State.Running then return end
    equipPet(petId)
    task.wait(DELAY_EQUIP + 0.5)
    if not State.Running then return end
    switchSlot(SLOT_BEFORE_INSERT)
    if not State.Running then return end
    log("🧬 Insert...")
    local ok, r = insertPet(petId)
    if not ok then
        log("❌ Insert gagal: " .. tostring(r)); State.Stats.Fails += 1; return
    end
    log("✅ Masuk mesin")
    switchSlot(SLOT_AFTER_INSERT)
    if not State.Running then return end
    if not waitForMutation() then return end
    task.wait(DELAY_STEP)
    log("📦 Collect...")
    local cok, cr = collectPet()
    if not cok then
        log("❌ Collect gagal: " .. tostring(cr)); State.Stats.Fails += 1; return
    end
    local m = parseMutationResult(cr)
    local isTarget = isTargetReached(m)
    State.Stats.Mutations += 1
    table.insert(State.Stats.History, { time = os.date("%H:%M:%S"), mutation = m, isTarget = isTarget })
    updateHistory()
    log("🎉 DIDAPAT: " .. tostring(m) .. " (total: " .. State.Stats.Mutations .. ")")
    sendWebhook(m, isTarget)
    if isTarget then
        log("🎯 TARGET: " .. m .. "! Stop.")
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "🎯 Target Tercapai!", Text = "Dapat: " .. m, Duration = 10,
            })
        end)
        stopLoop("Target: " .. tostring(m))
        return
    end
end

function startLoop()
    if State.Running then return end
    State.Running = true
    State.Stats.StartTime = tick()
    task.spawn(function()
        while State.Running do
            local ok, err = pcall(runMutationCycle)
            if not ok then State.Stats.Fails += 1; log("❌ " .. tostring(err)) end
            task.wait(DELAY_STEP)
        end
        State.Running = false
        updateUI()
    end)
end

function stopLoop(reason)
    State.Running = false
    log("⏹️ Stop")
end

-- ============================================================
-- GUI
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoMutationGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 800, 0, 500)
MainFrame.Position = UDim2.new(0.5, -400, 0.5, -250)
MainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local MC = Instance.new("UICorner"); MC.CornerRadius = UDim.new(0, 10); MC.Parent = MainFrame
local MS = Instance.new("UIStroke"); MS.Color = Color3.fromRGB(120, 80, 200); MS.Thickness = 1; MS.Parent = MainFrame

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 34)
Title.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
Title.BorderSizePixel = 0
Title.Text = "🧬 Auto Pet Mutation v11.7"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 15
Title.Font = Enum.Font.GothamBold
Title.Parent = MainFrame
local TC = Instance.new("UICorner"); TC.CornerRadius = UDim.new(0, 10); TC.Parent = Title
local TF = Instance.new("Frame")
TF.Size = UDim2.new(1, 0, 0, 8); TF.Position = UDim2.new(0, 0, 1, -8)
TF.BackgroundColor3 = Color3.fromRGB(55, 40, 85); TF.BorderSizePixel = 0
TF.Parent = Title

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 28, 0, 28)
CloseBtn.Position = UDim2.new(1, -34, 0, 3)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 13
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = Title
local CC = Instance.new("UICorner"); CC.CornerRadius = UDim.new(0, 6); CC.Parent = CloseBtn

-- 2 Columns
local LeftCol = Instance.new("Frame")
LeftCol.Size = UDim2.new(0, 390, 1, -46)
LeftCol.Position = UDim2.new(0, 10, 0, 40)
LeftCol.BackgroundTransparency = 1
LeftCol.ClipsDescendants = true
LeftCol.Parent = MainFrame

local RightCol = Instance.new("Frame")
RightCol.Size = UDim2.new(0, 380, 1, -46)
RightCol.Position = UDim2.new(0, 410, 0, 40)
RightCol.BackgroundTransparency = 1
RightCol.ClipsDescendants = true
RightCol.Parent = MainFrame

local function makeLabel(parent, text, y, xOff, w)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(w or 1, 0, 0, 14)
    l.Position = UDim2.new(xOff or 0, 0, 0, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(200, 200, 220)
    l.TextSize = 10
    l.Font = Enum.Font.GothamMedium
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = parent
    return l
end

local function makeInput(parent, placeholder, def, y, xOff, w, h, textSize)
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(w or 1, 0, 0, h or 24)
    box.Position = UDim2.new(xOff or 0, 0, 0, y)
    box.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    box.BorderSizePixel = 0
    box.Text = def or ""
    box.PlaceholderText = placeholder or ""
    box.TextColor3 = Color3.fromRGB(255, 255, 255)
    box.TextSize = textSize or 10
    box.Font = Enum.Font.Code
    box.ClearTextOnFocus = false
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.TextTruncate = Enum.TextTruncate.AtEnd  -- ✅ Fix overflow
    box.TextWrapped = false
    box.Parent = parent
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = box
    return box
end

-- ============================================================
-- LEFT COLUMN
-- ============================================================
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, 0, 0, 22)
StatusLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
StatusLabel.BorderSizePixel = 0
StatusLabel.Text = "Status: IDLE"
StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
StatusLabel.TextSize = 12
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.Parent = LeftCol
local SC = Instance.new("UICorner"); SC.CornerRadius = UDim.new(0, 6); SC.Parent = StatusLabel

local StatsLabel = Instance.new("TextLabel")
StatsLabel.Size = UDim2.new(0.49, -1, 0, 36)
StatsLabel.Position = UDim2.new(0, 0, 0, 26)
StatsLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
StatsLabel.BorderSizePixel = 0
StatsLabel.Text = "Mut: 0\nGear: 0"
StatsLabel.TextColor3 = Color3.fromRGB(180, 150, 220)
StatsLabel.TextSize = 10
StatsLabel.Font = Enum.Font.Code
StatsLabel.Parent = LeftCol
local StC = Instance.new("UICorner"); StC.CornerRadius = UDim.new(0, 6); StC.Parent = StatsLabel

local MachineFrame = Instance.new("Frame")
MachineFrame.Size = UDim2.new(0.51, 0, 0, 36)
MachineFrame.Position = UDim2.new(0.49, 1, 0, 26)
MachineFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
MachineFrame.BorderSizePixel = 0
MachineFrame.Parent = LeftCol
local MFC = Instance.new("UICorner"); MFC.CornerRadius = UDim.new(0, 6); MFC.Parent = MachineFrame
local MFS = Instance.new("UIStroke"); MFS.Color = Color3.fromRGB(100, 70, 150); MFS.Thickness = 1; MFS.Parent = MachineFrame

local MachineStateLabel = Instance.new("TextLabel")
MachineStateLabel.Size = UDim2.new(1, -6, 0, 16)
MachineStateLabel.Position = UDim2.new(0, 4, 0, 2)
MachineStateLabel.BackgroundTransparency = 1
MachineStateLabel.Text = "⏱️ IDLE"
MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
MachineStateLabel.TextSize = 10
MachineStateLabel.Font = Enum.Font.GothamBold
MachineStateLabel.TextXAlignment = Enum.TextXAlignment.Left
MachineStateLabel.Parent = MachineFrame

local MachineTimerLabel = Instance.new("TextLabel")
MachineTimerLabel.Size = UDim2.new(1, -6, 0, 16)
MachineTimerLabel.Position = UDim2.new(0, 4, 0, 18)
MachineTimerLabel.BackgroundTransparency = 1
MachineTimerLabel.Text = "00:00"
MachineTimerLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
MachineTimerLabel.TextSize = 10
MachineTimerLabel.Font = Enum.Font.Code
MachineTimerLabel.TextXAlignment = Enum.TextXAlignment.Left
MachineTimerLabel.Parent = MachineFrame

makeLabel(LeftCol, "🐾 Pet Target:", 70)

local ScanBtn = Instance.new("TextButton")
ScanBtn.Size = UDim2.new(0.3, -2, 0, 26)
ScanBtn.Position = UDim2.new(0, 0, 0, 88)
ScanBtn.BackgroundColor3 = Color3.fromRGB(80, 60, 180)
ScanBtn.BorderSizePixel = 0
ScanBtn.Text = "🔍 Scan"
ScanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ScanBtn.TextSize = 10
ScanBtn.Font = Enum.Font.GothamBold
ScanBtn.Parent = LeftCol
local ScC = Instance.new("UICorner"); ScC.CornerRadius = UDim.new(0, 6); ScC.Parent = ScanBtn

local RefreshBtn = Instance.new("TextButton")
RefreshBtn.Size = UDim2.new(0.15, -2, 0, 26)
RefreshBtn.Position = UDim2.new(0.3, 2, 0, 88)
RefreshBtn.BackgroundColor3 = Color3.fromRGB(50, 70, 100)
RefreshBtn.BorderSizePixel = 0
RefreshBtn.Text = "🔄"
RefreshBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
RefreshBtn.TextSize = 12
RefreshBtn.Font = Enum.Font.GothamBold
RefreshBtn.Parent = LeftCol
local RC = Instance.new("UICorner"); RC.CornerRadius = UDim.new(0, 6); RC.Parent = RefreshBtn

local PetSelectBtn = Instance.new("TextButton")
PetSelectBtn.Size = UDim2.new(0.55, -2, 0, 26)
PetSelectBtn.Position = UDim2.new(0.45, 2, 0, 88)
PetSelectBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
PetSelectBtn.BorderSizePixel = 0
PetSelectBtn.Text = "▼ Pilih..."
PetSelectBtn.TextColor3 = Color3.fromRGB(220, 220, 240)
PetSelectBtn.TextSize = 10
PetSelectBtn.Font = Enum.Font.GothamMedium
PetSelectBtn.TextTruncate = Enum.TextTruncate.AtEnd
PetSelectBtn.Parent = LeftCol
local PSC = Instance.new("UICorner"); PSC.CornerRadius = UDim.new(0, 6); PSC.Parent = PetSelectBtn
local PSSt = Instance.new("UIStroke"); PSSt.Color = Color3.fromRGB(150, 100, 220); PSSt.Thickness = 1.5; PSSt.Parent = PetSelectBtn

local SelectedPetLabel = Instance.new("TextLabel")
SelectedPetLabel.Size = UDim2.new(1, 0, 0, 20)
SelectedPetLabel.Position = UDim2.new(0, 0, 0, 118)
SelectedPetLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
SelectedPetLabel.BorderSizePixel = 0
SelectedPetLabel.Text = "Belum ada pet dipilih"
SelectedPetLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
SelectedPetLabel.TextSize = 10
SelectedPetLabel.Font = Enum.Font.Code
SelectedPetLabel.TextTruncate = Enum.TextTruncate.AtEnd
SelectedPetLabel.Parent = LeftCol
local SPLC = Instance.new("UICorner"); SPLC.CornerRadius = UDim.new(0, 4); SPLC.Parent = SelectedPetLabel

local PetDropdown = Instance.new("ScrollingFrame")
PetDropdown.Size = UDim2.new(1, 0, 0, 0)
PetDropdown.Position = UDim2.new(0, 0, 0, 142)
PetDropdown.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
PetDropdown.BorderSizePixel = 0
PetDropdown.CanvasSize = UDim2.new(0, 0, 0, 0)
PetDropdown.ScrollBarThickness = 4
PetDropdown.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
PetDropdown.Visible = false
PetDropdown.ZIndex = 10
PetDropdown.Parent = LeftCol
local PDC = Instance.new("UICorner"); PDC.CornerRadius = UDim.new(0, 6); PDC.Parent = PetDropdown
local PDSt = Instance.new("UIStroke"); PDSt.Color = Color3.fromRGB(120, 80, 200); PDSt.Thickness = 1.5; PDSt.Parent = PetDropdown

local PetDdLayout = Instance.new("UIListLayout")
PetDdLayout.Padding = UDim.new(0, 2); PetDdLayout.SortOrder = Enum.SortOrder.LayoutOrder
PetDdLayout.Parent = PetDropdown

makeLabel(LeftCol, "🔧 Gear Name:", 152)
local GearNameBox = makeInput(LeftCol, "DiamondCookie", DEFAULT_GEAR_NAME, 168, 0, 0.6, 24, 10)

makeLabel(LeftCol, "📊 Umur:", 152, 0.62)
local AgeBox = Instance.new("TextLabel")
AgeBox.Size = UDim2.new(0.38, 0, 0, 24)
AgeBox.Position = UDim2.new(0.62, 0, 0, 168)
AgeBox.BackgroundColor3 = Color3.fromRGB(35, 45, 35)
AgeBox.BorderSizePixel = 0
AgeBox.Text = "— / " .. tostring(MAX_AGE or 50)
AgeBox.TextColor3 = Color3.fromRGB(150, 230, 150)
AgeBox.TextSize = 11
AgeBox.Font = Enum.Font.GothamBold
AgeBox.Parent = LeftCol
local AGC = Instance.new("UICorner"); AGC.CornerRadius = UDim.new(0, 4); AGC.Parent = AgeBox

makeLabel(LeftCol, "🎯 Target Mutation:", 200)
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size = UDim2.new(1, 0, 0, 80)
ScrollFrame.Position = UDim2.new(0, 0, 0, 216)
ScrollFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
ScrollFrame.BorderSizePixel = 0
ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollFrame.ScrollBarThickness = 4
ScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
ScrollFrame.Parent = LeftCol
local SFC = Instance.new("UICorner"); SFC.CornerRadius = UDim.new(0, 6); SFC.Parent = ScrollFrame
local SFSt = Instance.new("UIStroke"); SFSt.Color = Color3.fromRGB(80, 60, 120); SFSt.Thickness = 1; SFSt.Parent = ScrollFrame

local ScrollLayout = Instance.new("UIListLayout")
ScrollLayout.Padding = UDim.new(0, 3); ScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
ScrollLayout.Parent = ScrollFrame

local ScrollPadding = Instance.new("UIPadding")
ScrollPadding.PaddingTop = UDim.new(0, 4); ScrollPadding.PaddingLeft = UDim.new(0, 4)
ScrollPadding.PaddingRight = UDim.new(0, 4); ScrollPadding.PaddingBottom = UDim.new(0, 4)
ScrollPadding.Parent = ScrollFrame

local mutationList = getMutationList()
for i, mutName in ipairs(mutationList) do
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 20)
    row.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    row.BorderSizePixel = 0
    row.LayoutOrder = i
    row.Parent = ScrollFrame
    local rC = Instance.new("UICorner"); rC.CornerRadius = UDim.new(0, 4); rC.Parent = row

    local checkbox = Instance.new("TextButton")
    checkbox.Name = "Checkbox"
    checkbox.Size = UDim2.new(0, 16, 0, 16)
    checkbox.Position = UDim2.new(0, 3, 0.5, -8)
    checkbox.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    checkbox.BorderSizePixel = 0
    checkbox.Text = ""
    checkbox.Parent = row
    local cC = Instance.new("UICorner"); cC.CornerRadius = UDim.new(0, 3); cC.Parent = checkbox

    local checkmark = Instance.new("TextLabel")
    checkmark.Size = UDim2.fromScale(1, 1)
    checkmark.BackgroundTransparency = 1
    checkmark.Text = ""
    checkmark.TextColor3 = Color3.fromRGB(255, 255, 255)
    checkmark.TextSize = 12
    checkmark.Font = Enum.Font.GothamBold
    checkmark.Parent = checkbox

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -30, 1, 0)
    lbl.Position = UDim2.new(0, 24, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = mutName
    lbl.TextColor3 = Color3.fromRGB(220, 220, 240)
    lbl.TextSize = 10
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local function toggle()
        if State.TargetMutations[mutName] then
            State.TargetMutations[mutName] = nil
            checkbox.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
            checkmark.Text = ""
        else
            State.TargetMutations[mutName] = true
            checkbox.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
            checkmark.Text = "✓"
        end
    end
    checkbox.MouseButton1Click:Connect(toggle)
    row.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then toggle() end
    end)
end

ScrollLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, ScrollLayout.AbsoluteContentSize.Y + 8)
end)

local ClearTargetBtn = Instance.new("TextButton")
ClearTargetBtn.Size = UDim2.new(1, 0, 0, 18)
ClearTargetBtn.Position = UDim2.new(0, 0, 0, 300)
ClearTargetBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 50)
ClearTargetBtn.BorderSizePixel = 0
ClearTargetBtn.Text = "🗑️ Clear Target"
ClearTargetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ClearTargetBtn.TextSize = 9
ClearTargetBtn.Font = Enum.Font.GothamMedium
ClearTargetBtn.Parent = LeftCol
local ClC = Instance.new("UICorner"); ClC.CornerRadius = UDim.new(0, 4); ClC.Parent = ClearTargetBtn

local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(1, 0, 0, 38)
ToggleBtn.Position = UDim2.new(0, 0, 1, -38)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(120, 70, 200)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Text = "▶  START AUTO MUTATION"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 13
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = LeftCol
local TgC = Instance.new("UICorner"); TgC.CornerRadius = UDim.new(0, 8); TgC.Parent = ToggleBtn

-- ============================================================
-- RIGHT COLUMN
-- ============================================================
local AutoDetectBtn = Instance.new("TextButton")
AutoDetectBtn.Size = UDim2.new(0.32, -2, 0, 24)
AutoDetectBtn.Position = UDim2.new(0, 0, 0, 0)
AutoDetectBtn.BackgroundColor3 = Color3.fromRGB(60, 130, 90)
AutoDetectBtn.BorderSizePixel = 0
AutoDetectBtn.Text = "🤖 Auto: ON"
AutoDetectBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AutoDetectBtn.TextSize = 10
AutoDetectBtn.Font = Enum.Font.GothamBold
AutoDetectBtn.Parent = RightCol
local ADC = Instance.new("UICorner"); ADC.CornerRadius = UDim.new(0, 4); ADC.Parent = AutoDetectBtn

local WebhookToggleBtn = Instance.new("TextButton")
WebhookToggleBtn.Size = UDim2.new(0.32, -2, 0, 24)
WebhookToggleBtn.Position = UDim2.new(0.34, 0, 0, 0)
WebhookToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 130, 90)
WebhookToggleBtn.BorderSizePixel = 0
WebhookToggleBtn.Text = "🔔 Web: ON"
WebhookToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookToggleBtn.TextSize = 10
WebhookToggleBtn.Font = Enum.Font.GothamBold
WebhookToggleBtn.Parent = RightCol
local WTC = Instance.new("UICorner"); WTC.CornerRadius = UDim.new(0, 4); WTC.Parent = WebhookToggleBtn

local WebhookOnlyTargetBtn = Instance.new("TextButton")
WebhookOnlyTargetBtn.Size = UDim2.new(0.32, -2, 0, 24)
WebhookOnlyTargetBtn.Position = UDim2.new(0.68, 0, 0, 0)
WebhookOnlyTargetBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
WebhookOnlyTargetBtn.BorderSizePixel = 0
WebhookOnlyTargetBtn.Text = "🎯 Only: OFF"
WebhookOnlyTargetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookOnlyTargetBtn.TextSize = 10
WebhookOnlyTargetBtn.Font = Enum.Font.GothamBold
WebhookOnlyTargetBtn.Parent = RightCol
local WOC = Instance.new("UICorner"); WOC.CornerRadius = UDim.new(0, 4); WOC.Parent = WebhookOnlyTargetBtn

-- Webhook URL (full width, tapi text size kecil + truncate)
makeLabel(RightCol, "🔗 Webhook URL:", 30)
local WebhookBox = makeInput(RightCol, "https://discord.com/api/webhooks/...", "", 46, 0, 1, 22, 9)

makeLabel(RightCol, "📢 Mention:", 74)
local MentionBox = makeInput(RightCol, "<@123>", "", 90, 0, 0.6, 24, 10)

local TestWebhookBtn = Instance.new("TextButton")
TestWebhookBtn.Size = UDim2.new(0.38, -2, 0, 24)
TestWebhookBtn.Position = UDim2.new(0.62, 2, 0, 90)
TestWebhookBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
TestWebhookBtn.BorderSizePixel = 0
TestWebhookBtn.Text = "📤 Test Webhook"
TestWebhookBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
TestWebhookBtn.TextSize = 10
TestWebhookBtn.Font = Enum.Font.GothamBold
TestWebhookBtn.Parent = RightCol
local TWC = Instance.new("UICorner"); TWC.CornerRadius = UDim.new(0, 4); TWC.Parent = TestWebhookBtn

local HistoryHeader = Instance.new("TextLabel")
HistoryHeader.Size = UDim2.new(1, 0, 0, 14)
HistoryHeader.Position = UDim2.new(0, 0, 0, 120)
HistoryHeader.BackgroundTransparency = 1
HistoryHeader.Text = "📜 History:"
HistoryHeader.TextColor3 = Color3.fromRGB(220, 180, 255)
HistoryHeader.TextSize = 10
HistoryHeader.Font = Enum.Font.GothamBold
HistoryHeader.TextXAlignment = Enum.TextXAlignment.Left
HistoryHeader.Parent = RightCol

local HistoryBg = Instance.new("Frame")
HistoryBg.Size = UDim2.new(1, 0, 0, 130)
HistoryBg.Position = UDim2.new(0, 0, 0, 136)
HistoryBg.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
HistoryBg.BorderSizePixel = 0
HistoryBg.Parent = RightCol
local HC = Instance.new("UICorner"); HC.CornerRadius = UDim.new(0, 6); HC.Parent = HistoryBg
local HSt = Instance.new("UIStroke"); HSt.Color = Color3.fromRGB(120, 80, 200); HSt.Thickness = 1; HSt.Parent = HistoryBg

local HistoryScroll = Instance.new("ScrollingFrame")
HistoryScroll.Size = UDim2.new(1, -8, 1, -8)
HistoryScroll.Position = UDim2.new(0, 4, 0, 4)
HistoryScroll.BackgroundTransparency = 1
HistoryScroll.BorderSizePixel = 0
HistoryScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
HistoryScroll.ScrollBarThickness = 4
HistoryScroll.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
HistoryScroll.Parent = HistoryBg

local HistoryContent = Instance.new("Frame")
HistoryContent.Size = UDim2.new(1, 0, 0, 0)
HistoryContent.BackgroundTransparency = 1
HistoryContent.Parent = HistoryScroll

local HistoryLayout = Instance.new("UIListLayout")
HistoryLayout.Padding = UDim.new(0, 3); HistoryLayout.SortOrder = Enum.SortOrder.LayoutOrder
HistoryLayout.Parent = HistoryContent

HistoryLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    HistoryScroll.CanvasSize = UDim2.new(0, 0, 0, HistoryLayout.AbsoluteContentSize.Y + 6)
end)

local ClearHistoryBtn = Instance.new("TextButton")
ClearHistoryBtn.Size = UDim2.new(0.5, -2, 0, 20)
ClearHistoryBtn.Position = UDim2.new(0, 0, 0, 270)
ClearHistoryBtn.BackgroundColor3 = Color3.fromRGB(60, 40, 40)
ClearHistoryBtn.BorderSizePixel = 0
ClearHistoryBtn.Text = "🗑️ Clear"
ClearHistoryBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
ClearHistoryBtn.TextSize = 10
ClearHistoryBtn.Font = Enum.Font.GothamMedium
ClearHistoryBtn.Parent = RightCol
local CHC = Instance.new("UICorner"); CHC.CornerRadius = UDim.new(0, 4); CHC.Parent = ClearHistoryBtn

local ExportBtn = Instance.new("TextButton")
ExportBtn.Size = UDim2.new(0.5, -2, 0, 20)
ExportBtn.Position = UDim2.new(0.5, 2, 0, 270)
ExportBtn.BackgroundColor3 = Color3.fromRGB(40, 60, 80)
ExportBtn.BorderSizePixel = 0
ExportBtn.Text = "📋 Copy"
ExportBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
ExportBtn.TextSize = 10
ExportBtn.Font = Enum.Font.GothamMedium
ExportBtn.Parent = RightCol
local EXC = Instance.new("UICorner"); EXC.CornerRadius = UDim.new(0, 4); EXC.Parent = ExportBtn

local LogHeader = Instance.new("TextLabel")
LogHeader.Size = UDim2.new(1, 0, 0, 14)
LogHeader.Position = UDim2.new(0, 0, 0, 296)
LogHeader.BackgroundTransparency = 1
LogHeader.Text = "📋 Log:"
LogHeader.TextColor3 = Color3.fromRGB(220, 180, 255)
LogHeader.TextSize = 10
LogHeader.Font = Enum.Font.GothamBold
LogHeader.TextXAlignment = Enum.TextXAlignment.Left
LogHeader.Parent = RightCol

local LogBg = Instance.new("Frame")
LogBg.Size = UDim2.new(1, 0, 1, -318)
LogBg.Position = UDim2.new(0, 0, 0, 314)
LogBg.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
LogBg.BorderSizePixel = 0
LogBg.Parent = RightCol
local LC = Instance.new("UICorner"); LC.CornerRadius = UDim.new(0, 6); LC.Parent = LogBg

local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -10, 1, -10)
LogLabel.Position = UDim2.new(0, 5, 0, 5)
LogLabel.BackgroundTransparency = 1
LogLabel.Text = "[Log akan muncul di sini]"
LogLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
LogLabel.TextSize = 10
LogLabel.Font = Enum.Font.Code
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.Parent = LogBg

-- ============================================================
-- LIVE TIMER
-- ============================================================
local function updateMachineTimer()
    while ScreenGui.Parent do
        if modulesReady() then
            local state, rem = getMachineState()
            if state == "Idle" then
                MachineStateLabel.Text = "⏱️ IDLE"
                MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
                MachineTimerLabel.Text = "00:00"
                MachineTimerLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
            elseif state == "InProgress" then
                MachineStateLabel.Text = "⚙️ MUTATING"
                MachineStateLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
                MachineTimerLabel.Text = formatTime(rem)
                MachineTimerLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
            elseif state == "Ready" then
                MachineStateLabel.Text = "✅ READY!"
                MachineStateLabel.TextColor3 = Color3.fromRGB(120, 230, 120)
                MachineTimerLabel.Text = "00:00"
                MachineTimerLabel.TextColor3 = Color3.fromRGB(120, 230, 120)
            end
        end
        if ageReady() and State.PetId and State.PetId ~= "" then
            local age = getPetAge(State.PetId)
            if age then
                AgeBox.Text = age .. " / " .. MAX_AGE
                if age >= MAX_AGE then
                    AgeBox.TextColor3 = Color3.fromRGB(120, 230, 120)
                    AgeBox.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
                else
                    AgeBox.TextColor3 = Color3.fromRGB(255, 220, 100)
                    AgeBox.BackgroundColor3 = Color3.fromRGB(60, 50, 30)
                end
            end
        end
        task.wait(0.5)
    end
end
task.spawn(updateMachineTimer)

function updateUI()
    if State.Running then
        StatusLabel.Text = "Status: RUNNING"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 150, 255)
        ToggleBtn.Text = "⏹  STOP"
        TweenService:Create(ToggleBtn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(200, 60, 60)}):Play()
    else
        StatusLabel.Text = "Status: IDLE"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
        ToggleBtn.Text = "▶  START AUTO MUTATION"
        TweenService:Create(ToggleBtn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(120, 70, 200)}):Play()
    end
    AutoDetectBtn.Text = "🤖 Auto: " .. (State.AutoDetect and "ON" or "OFF")
    AutoDetectBtn.BackgroundColor3 = State.AutoDetect and Color3.fromRGB(60, 130, 90) or Color3.fromRGB(120, 70, 70)
    WebhookToggleBtn.Text = "🔔 Web: " .. (State.WebhookEnabled and "ON" or "OFF")
    WebhookToggleBtn.BackgroundColor3 = State.WebhookEnabled and Color3.fromRGB(60, 130, 90) or Color3.fromRGB(120, 70, 70)
    WebhookOnlyTargetBtn.Text = "🎯 Only: " .. (State.WebhookOnlyTarget and "ON" or "OFF")
    WebhookOnlyTargetBtn.BackgroundColor3 = State.WebhookOnlyTarget and Color3.fromRGB(120, 80, 180) or Color3.fromRGB(60, 60, 80)
end

local function updateStats()
    while ScreenGui.Parent do
        StatsLabel.Text = string.format("Mut: %d\nGear: %d", State.Stats.Mutations, State.Stats.GearUsed)
        task.wait(1)
    end
end
task.spawn(updateStats)

-- ============================================================
-- DROPDOWN
-- ============================================================
local function refreshPetDropdown(pets)
    for _, c in ipairs(PetDropdown:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end
    if #pets == 0 then
        local e = Instance.new("TextLabel")
        e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
        e.Text = "Tidak ada pet"; e.TextColor3 = Color3.fromRGB(150, 150, 170)
        e.TextSize = 10; e.Font = Enum.Font.Gotham
        e.Parent = PetDropdown
        PetDropdown.CanvasSize = UDim2.new(0, 0, 0, 30)
        return
    end
    for i, pet in ipairs(pets) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 24)
        btn.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
        btn.BorderSizePixel = 0
        btn.Text = ""
        btn.LayoutOrder = i
        btn.Parent = PetDropdown
        local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 4); bc.Parent = btn

        local n = Instance.new("TextLabel")
        n.Size = UDim2.new(0.6, 0, 1, 0); n.Position = UDim2.new(0, 6, 0, 0)
        n.BackgroundTransparency = 1
        n.Text = pet.displayName
        n.TextColor3 = pet.mutation and Color3.fromRGB(255, 220, 100) or Color3.fromRGB(220, 220, 240)
        n.TextSize = 10; n.Font = Enum.Font.GothamBold
        n.TextXAlignment = Enum.TextXAlignment.Left
        n.TextTruncate = Enum.TextTruncate.AtEnd
        n.Parent = btn

        local m = Instance.new("TextLabel")
        m.Size = UDim2.new(0.4, -6, 1, 0); m.Position = UDim2.new(0.6, 0, 0, 0)
        m.BackgroundTransparency = 1
        m.Text = (pet.mutation or "N") .. (pet.mutationCount and (" x" .. pet.mutationCount) or "")
        m.TextColor3 = Color3.fromRGB(180, 150, 220)
        m.TextSize = 9; m.Font = Enum.Font.Code
        m.TextXAlignment = Enum.TextXAlignment.Right
        m.TextTruncate = Enum.TextTruncate.AtEnd
        m.Parent = btn

        btn.MouseButton1Click:Connect(function()
            State.PetId = pet.id
            State.PetDisplayName = pet.displayName
            PetSelectBtn.Text = "▼ " .. pet.displayName
            SelectedPetLabel.Text = string.format("%s | %s (%d)",
                pet.displayName, pet.mutation or "Normal", pet.mutationCount or 0)
            SelectedPetLabel.TextColor3 = Color3.fromRGB(150, 230, 150)
            PetDropdown.Visible = false
            PetDropdown.Size = UDim2.new(1, 0, 0, 0)
            log("🐾 " .. pet.displayName)
        end)
    end
    PetDropdown.CanvasSize = UDim2.new(0, 0, 0, #pets * 26 + 8)
end

local function doScan()
    log("🔍 Scan...")
    local pets = scanPets()
    State.PetList = pets
    log("   " .. #pets .. " pet")
    refreshPetDropdown(pets)
    return pets
end

ScanBtn.MouseButton1Click:Connect(function()
    local pets = doScan()
    if #pets > 0 then
        PetDropdown.Visible = true
        PetDropdown.Size = UDim2.new(1, 0, 0, math.min(#pets * 26 + 8, 140))
    end
end)

RefreshBtn.MouseButton1Click:Connect(function()
    local pets = doScan()
    if #pets > 0 then
        PetDropdown.Visible = true
        PetDropdown.Size = UDim2.new(1, 0, 0, math.min(#pets * 26 + 8, 140))
    end
end)

PetSelectBtn.MouseButton1Click:Connect(function()
    if #State.PetList == 0 then log("⚠️ Scan dulu!"); return end
    PetDropdown.Visible = not PetDropdown.Visible
    if PetDropdown.Visible then
        PetDropdown.Size = UDim2.new(1, 0, 0, math.min(#State.PetList * 26 + 8, 140))
    else
        PetDropdown.Size = UDim2.new(1, 0, 0, 0)
    end
end)

AutoDetectBtn.MouseButton1Click:Connect(function() State.AutoDetect = not State.AutoDetect; updateUI() end)
WebhookToggleBtn.MouseButton1Click:Connect(function()
    State.WebhookEnabled = not State.WebhookEnabled
    State.WebhookURL = WebhookBox.Text:gsub("%s", "")
    State.WebhookMention = MentionBox.Text
    updateUI()
end)
WebhookOnlyTargetBtn.MouseButton1Click:Connect(function() State.WebhookOnlyTarget = not State.WebhookOnlyTarget; updateUI() end)

TestWebhookBtn.MouseButton1Click:Connect(function()
    State.WebhookURL = WebhookBox.Text:gsub("%s", "")
    State.WebhookMention = MentionBox.Text
    if State.WebhookURL == "" then log("❌ Isi Webhook URL!"); return end
    if not getRequestFunction() then log("❌ Executor gak support HTTP!"); return end
    log("📤 Test webhook...")
    sendWebhook("TEST_MUTATION", true, "Test webhook dari GUI.")
end)

ClearTargetBtn.MouseButton1Click:Connect(function()
    State.TargetMutations = {}
    for _, row in ipairs(ScrollFrame:GetChildren()) do
        if row:IsA("Frame") then
            local cb = row:FindFirstChild("Checkbox")
            if cb then
                cb.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
                local cm = cb:FindFirstChildOfClass("TextLabel")
                if cm then cm.Text = "" end
            end
        end
    end
    log("🗑️ Target clear")
end)

ClearHistoryBtn.MouseButton1Click:Connect(function()
    State.Stats.History = {}
    updateHistory()
    log("🗑️ History clear")
end)

ExportBtn.MouseButton1Click:Connect(function()
    if #State.Stats.History == 0 then log("📋 Kosong"); return end
    local lines = {}
    for i, e in ipairs(State.Stats.History) do
        table.insert(lines, string.format("#%d [%s] %s%s", i, e.time, tostring(e.mutation), e.isTarget and " 🎯" or ""))
    end
    local text = table.concat(lines, "\n")
    pcall(function()
        if setclipboard then setclipboard(text)
        elseif toclipboard then toclipboard(text) end
    end)
    log("📋 Copied (" .. #State.Stats.History .. ")")
end)

ToggleBtn.MouseButton1Click:Connect(function()
    if State.Running then
        stopLoop("Manual stop")
    else
        local petId = State.PetId
        if not petId or petId == "" then
            log("❌ Pilih pet dulu!")
            PetSelectBtn.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
            task.delay(1, function() PetSelectBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 55) end)
            return
        end
        State.GearName = GearNameBox.Text ~= "" and GearNameBox.Text or DEFAULT_GEAR_NAME
        State.WebhookURL = WebhookBox.Text:gsub("%s", "")
        State.WebhookMention = MentionBox.Text
        State.Stats.Mutations = 0
        State.Stats.GearUsed = 0
        State.Stats.Fails = 0
        State.Stats.History = {}
        updateHistory()
        log("🚀 START: " .. (State.PetDisplayName or petId:sub(1, 8)))
        startLoop()
    end
    updateUI()
end)

CloseBtn.MouseButton1Click:Connect(function()
    stopLoop("GUI closed")
    ScreenGui:Destroy()
end)

updateUI()
updateHistory()

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then ToggleBtn:Activate() end
end)

log("✅ GUI loaded (v11.7).")
if inventoryStateModule then log("   ✅ inventory.state OK") else log("   ❌ inventory.state GAGAL") end
if getRequestFunction() then log("   ✅ HTTP OK") end
