--[[
    AUTO PET MUTATION — Full GUI (v11)
    ----------------------------------------------------------
    Update v11:
    - Discord Webhook (kirim notifikasi tiap mutasi)
    - History mutasi di GUI
    - Auto-detect umur pet
    - Auto-detect mesin
    - Target mutation multi-select
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- KONFIGURASI
-- ============================================================
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

-- ============================================================
-- LOAD MODULE
-- ============================================================
local getPlayerData, getSharedTime, PET_MUTATION_TIME, PetMutations
local getPetAgeFromData, MAX_AGE

pcall(function()
    getPlayerData = require(ReplicatedStorage.TS.state["player-data"]).getPlayerData
end)
pcall(function()
    getSharedTime = require(game:GetService("StarterPlayer").StarterPlayerScripts.TS.systems.core.sharedTime).getSharedTime
end)
pcall(function()
    PET_MUTATION_TIME = require(ReplicatedStorage.TS.constants).PET_MUTATION_TIME
end)
pcall(function()
    PetMutations = require(ReplicatedStorage.TS.lists.game["pet-mutations"]).PetMutations
end)
pcall(function()
    local v4 = require(ReplicatedStorage.TS.utils["pet-age.utils"])
    getPetAgeFromData = v4.getPetAgeFromData
    MAX_AGE = v4.MAX_AGE
end)

local function modulesReady()
    return getPlayerData and getSharedTime and PET_MUTATION_TIME
end
local function ageReady()
    return getPlayerData and getPetAgeFromData and MAX_AGE
end

local function getMutationList()
    local list = {}
    if PetMutations then
        for key, data in pairs(PetMutations) do
            table.insert(list, data.name or key)
        end
        table.sort(list)
    end
    if #list == 0 then list = FALLBACK_MUTATIONS end
    return list
end

-- ============================================================
-- REMOTE SETUP
-- ============================================================
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

-- ============================================================
-- STATE
-- ============================================================
local State = {
    Running = false,
    PetId = "",
    GearName = DEFAULT_GEAR_NAME,
    AutoDetect = true,
    TargetMutations = {},
    WebhookURL = "",
    WebhookEnabled = true,
    WebhookMention = "",       -- contoh: "<@123>" atau "@everyone"
    WebhookOnlyTarget = false, -- kalau true, cuma kirim saat target tercapai
    Stats = {
        Mutations = 0,
        GearUsed = 0,
        Fails = 0,
        StartTime = 0,
        History = {},
    }
}

-- ============================================================
-- WEBHOOK FUNGSI
-- ============================================================
local function sendWebhook(mutationName, isTarget, extraInfo)
    if not State.WebhookEnabled then return end
    if State.WebhookURL == "" then return end
    if State.WebhookOnlyTarget and not isTarget then return end
    
    local color = isTarget and 5763719 or 3447003  -- hijau / biru
    local title = isTarget and "🎯 TARGET MUTATION TERCAPAI!" or "🧬 Mutasi Baru Didapat"
    local emoji = isTarget and "🎯" or "🎉"
    
    -- Hitung statistik
    local total = State.Stats.Mutations
    local age = getPetAge(State.PetId) or "?"
    local elapsed = math.floor(tick() - State.Stats.StartTime)
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60
    
    -- Buat description
    local desc = string.format(
        "%s **%s** didapat!\n\n" ..
        "**Info Mutasi:**\n" ..
        "• Mutation: `%s`\n" ..
        "• Target: `%s`\n" ..
        "• Total Mutasi: `%d`\n" ..
        "• Umur Pet: `%s / %s`\n" ..
        "• Gear Dipakai: `%d`\n" ..
        "• Fails: `%d`\n" ..
        "• Uptime: `%02d:%02d`\n",
        emoji, mutationName or "?",
        tostring(mutationName or "?"),
        isTarget and "✅ YA" or "❌ BUKAN",
        total,
        tostring(age), tostring(MAX_AGE or 50),
        State.Stats.GearUsed,
        State.Stats.Fails,
        mins, secs
    )
    
    -- Info tambahan (kalau ada)
    if extraInfo then
        desc = desc .. "\n**Extra:**\n" .. extraInfo
    end
    
    -- Buat payload
    local content = ""
    if State.WebhookMention ~= "" then
        content = State.WebhookMention
    end
    
    local payload = {
        content = content,
        username = "Auto Mutation Bot",
        embeds = {
            {
                title = title,
                description = desc,
                color = color,
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                footer = {
                    text = "Auto Pet Mutation v11 • " .. LocalPlayer.Name
                },
                fields = {
                    {
                        name = "🐾 Pet UUID",
                        value = "`" .. (State.PetId:sub(1, 8) or "?") .. "...`",
                        inline = true
                    },
                    {
                        name = "🔧 Gear",
                        value = "`" .. State.GearName .. "`",
                        inline = true
                    }
                }
            }
        }
    }
    
    -- Kirim webhook (pakai pcall biar aman)
    task.spawn(function()
        local ok, err = pcall(function()
            local json = HttpService:JSONEncode(payload)
            local request = (syn and syn.request) or (http and http.request) or http_request or request
            if not request then
                warn("[AutoMut] Executor gak support HTTP request!")
                return
            end
            request({
                Url = State.WebhookURL,
                Method = "POST",
                Headers = {
                    ["Content-Type"] = "application/json"
                },
                Body = json
            })
        end)
        if not ok then
            warn("[AutoMut] Webhook gagal:", err)
        end
    end)
end

-- Kirim webhook start
local function sendWebhookStart()
    if not State.WebhookEnabled then return end
    if State.WebhookURL == "" then return end
    
    local payload = {
        username = "Auto Mutation Bot",
        embeds = {
            {
                title = "▶️ Auto Mutation START",
                description = string.format(
                    "Script auto mutation dimulai!\n\n" ..
                    "**Config:**\n" ..
                    "• Pet UUID: `%s...`\n" ..
                    "• Gear: `%s`\n" ..
                    "• Target: `%s`\n" ..
                    "• Auto-Detect: `%s`\n" ..
                    "• MAX_AGE: `%s`\n",
                    State.PetId:sub(1, 8),
                    State.GearName,
                    next(State.TargetMutations) and table.concat((function()
                        local t = {}
                        for n, _ in pairs(State.TargetMutations) do table.insert(t, n) end
                        return t
                    end)(), ", ") or "(loop terus)",
                    State.AutoDetect and "ON" or "OFF",
                    tostring(MAX_AGE or 50)
                ),
                color = 10181046,  -- ungu
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                footer = {
                    text = "Auto Pet Mutation v11 • " .. LocalPlayer.Name
                }
            }
        }
    }
    
    task.spawn(function()
        pcall(function()
            local request = (syn and syn.request) or (http and http.request) or http_request or request
            if request then
                request({
                    Url = State.WebhookURL,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
            end
        end)
    end)
end

-- Kirim webhook stop
local function sendWebhookStop(reason)
    if not State.WebhookEnabled then return end
    if State.WebhookURL == "" then return end
    
    local payload = {
        username = "Auto Mutation Bot",
        embeds = {
            {
                title = "⏹️ Auto Mutation STOP",
                description = string.format(
                    "Script dihentikan.\n\n" ..
                    "**Alasan:** %s\n" ..
                    "**Total Mutasi:** `%d`\n" ..
                    "**Total Gear:** `%d`\n" ..
                    "**Fails:** `%d`\n",
                    reason or "Manual stop",
                    State.Stats.Mutations,
                    State.Stats.GearUsed,
                    State.Stats.Fails
                ),
                color = 15158332,  -- merah
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                footer = {
                    text = "Auto Pet Mutation v11 • " .. LocalPlayer.Name
                }
            }
        }
    }
    
    task.spawn(function()
        pcall(function()
            local request = (syn and syn.request) or (http and http.request) or http_request or request
            if request then
                request({
                    Url = State.WebhookURL,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload)
                })
            end
        end)
    end)
end

-- ============================================================
-- HELPER
-- ============================================================
local function safeFire(remote, ...)
    if not remote then return false end
    local args = {...}
    local ok, err = pcall(function()
        remote:FireServer(table.unpack(args))
    end)
    if not ok then warn("[AutoMut] Fire gagal:", err) end
    return ok
end

local function safeInvoke(remote, ...)
    if not remote then return false, nil end
    local args = {...}
    local ok, result = pcall(function()
        return remote:InvokeServer(table.unpack(args))
    end)
    if not ok then warn("[AutoMut] Invoke gagal:", result) end
    return ok, result
end

local function log(msg)
    if LogLabel then
        local time = os.date("%H:%M:%S")
        local newText = LogLabel.Text .. "\n[" .. time .. "] " .. msg
        local lines = {}
        for line in newText:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        while #lines > 12 do table.remove(lines, 1) end
        LogLabel.Text = table.concat(lines, "\n")
    end
    print("[AutoMut] " .. msg)
end

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 0 then seconds = 0 end
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- ============================================================
-- BACA UMUR PET
-- ============================================================
local function getPetAge(petId)
    if not ageReady() then return nil end
    local ok, data = pcall(function()
        return getPlayerData(LocalPlayer)
    end)
    if not ok or not data or not data.inventory or not data.inventory.pets then
        return nil
    end
    local petData = data.inventory.pets[petId]
    if not petData then return nil end
    local ok2, age = pcall(function()
        return getPetAgeFromData(petData)
    end)
    if not ok2 then return nil end
    return age
end

-- ============================================================
-- CEK HASIL MUTASI
-- ============================================================
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

-- ============================================================
-- AUTO-DETECT MESIN
-- ============================================================
local function getMachineState()
    if not modulesReady() then return "Unknown", 0 end
    local ok, data = pcall(function()
        return getPlayerData(LocalPlayer)
    end)
    if not ok or not data then return "Unknown", 0 end
    local petMutation = data.petMutation
    if petMutation == nil then return "Idle", 0 end
    local ok2, sharedTime = pcall(getSharedTime)
    if not ok2 or not sharedTime then return "InProgress", 0 end
    local elapsed = sharedTime - petMutation.timeStarted
    local depletionRate = petMutation.depletionRate or 1
    local totalTime = PET_MUTATION_TIME / depletionRate
    local remaining = math.max(0, totalTime - elapsed)
    if elapsed >= totalTime then return "Ready", 0 end
    return "InProgress", remaining
end

-- ============================================================
-- AKSI
-- ============================================================
local function equipPet(petId)
    safeFire(Remotes.equipTool, petId, "pet")
    task.wait(DELAY_EQUIP)
end

local function equipGear(gearName)
    safeFire(Remotes.equipTool, gearName, "gear")
    task.wait(DELAY_EQUIP)
end

local function useGearOnPet(petId)
    return safeFire(Remotes.usePetGear, petId)
end

local function switchSlot(slot)
    local ok, result = safeInvoke(Remotes.switchSlot, slot)
    task.wait(DELAY_SLOT)
    return ok, result
end

local function insertPet(petId)  return safeInvoke(Remotes.startMut, petId) end
local function collectPet()      return safeInvoke(Remotes.collectMut) end

-- ============================================================
-- WAIT MUTATION
-- ============================================================
local function waitForMutation()
    if State.AutoDetect and modulesReady() then
        log("⏳ Nunggu mutasi (auto-detect)...")
        local lastLogTime = 0
        while State.Running do
            local state, remaining = getMachineState()
            if state == "Ready" then
                log("✅ Mesin READY!")
                return true
            elseif state == "InProgress" then
                local now = tick()
                if now - lastLogTime >= 30 then
                    log(string.format("   sisa %s (%.1f menit)", formatTime(remaining), remaining / 60))
                    lastLogTime = now
                end
            elseif state == "Idle" then
                log("⚠️ Mesin jadi Idle")
                return false
            end
            task.wait(POLL_INTERVAL)
        end
        return false
    else
        log("⏳ Nunggu manual...")
        local waited = 0
        while waited < 1800 do
            if not State.Running then return false end
            task.wait(POLL_INTERVAL)
            waited += POLL_INTERVAL
            if waited % 60 == 0 then
                log("   sisa " .. formatTime(1800 - waited))
            end
        end
        return true
    end
end

-- ============================================================
-- PAKAI GEAR SAMPAI MAX_AGE
-- ============================================================
local function useGearUntilMaxAge(petId)
    if not ageReady() then
        log("⚠️ Module umur gagal load, fallback 25 gear")
        for i = 1, 25 do
            if not State.Running then return end
            equipGear(State.GearName)
            useGearOnPet(petId)
            State.Stats.GearUsed += 1
            task.wait(DELAY_USE)
        end
        return
    end

    log("🔧 Pakai gear sampai umur " .. MAX_AGE .. "...")
    local i = 0
    while State.Running do
        local age = getPetAge(petId)
        if age == nil then
            log("⚠️ Gagal baca umur, stop gear")
            break
        end
        if age >= MAX_AGE then
            log("✅ Umur pet sudah " .. age .. "/" .. MAX_AGE .. " — STOP gear")
            break
        end
        i += 1
        equipGear(State.GearName)
        useGearOnPet(petId)
        State.Stats.GearUsed += 1
        if i % 5 == 0 then
            log("   gear " .. i .. " | umur: " .. age .. "/" .. MAX_AGE)
        end
        task.wait(DELAY_USE)
        if i >= SAFETY_MAX_GEAR then
            log("⚠️ Safety cap " .. SAFETY_MAX_GEAR)
            break
        end
    end
    if i == 0 then
        log("🎯 Pet udah MAX_AGE, langsung insert!")
    else
        log("✅ Selesai pakai gear (" .. i .. "x)")
    end
end

-- ============================================================
-- UPDATE HISTORY PANEL
-- ============================================================
local function updateHistory()
    if not HistoryContent then return end
    for _, child in ipairs(HistoryContent:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end

    if #State.Stats.History == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, 0, 0, 30)
        empty.BackgroundTransparency = 1
        empty.Text = "Belum ada mutasi"
        empty.TextColor3 = Color3.fromRGB(120, 120, 140)
        empty.TextSize = 11
        empty.Font = Enum.Font.Gotham
        empty.LayoutOrder = 1
        empty.Parent = HistoryContent
        return
    end

    for idx = #State.Stats.History, 1, -1 do
        local entry = State.Stats.History[idx]
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 22)
        row.BackgroundColor3 = entry.isTarget 
            and Color3.fromRGB(60, 90, 50)
            or Color3.fromRGB(40, 40, 55)
        row.BorderSizePixel = 0
        row.LayoutOrder = 1000 - idx
        row.Parent = HistoryContent

        local rc = Instance.new("UICorner")
        rc.CornerRadius = UDim.new(0, 4)
        rc.Parent = row

        local num = Instance.new("TextLabel")
        num.Size = UDim2.new(0, 28, 1, 0)
        num.Position = UDim2.new(0, 4, 0, 0)
        num.BackgroundTransparency = 1
        num.Text = "#" .. idx
        num.TextColor3 = Color3.fromRGB(150, 150, 170)
        num.TextSize = 10
        num.Font = Enum.Font.Code
        num.TextXAlignment = Enum.TextXAlignment.Left
        num.Parent = row

        local mutLbl = Instance.new("TextLabel")
        mutLbl.Size = UDim2.new(0.5, 0, 1, 0)
        mutLbl.Position = UDim2.new(0, 34, 0, 0)
        mutLbl.BackgroundTransparency = 1
        mutLbl.Text = tostring(entry.mutation or "?")
        mutLbl.TextColor3 = entry.isTarget 
            and Color3.fromRGB(150, 255, 150)
            or Color3.fromRGB(220, 220, 240)
        mutLbl.TextSize = 11
        mutLbl.Font = Enum.Font.GothamBold
        mutLbl.TextXAlignment = Enum.TextXAlignment.Left
        mutLbl.Parent = row

        local timeLbl = Instance.new("TextLabel")
        timeLbl.Size = UDim2.new(0.4, -8, 1, 0)
        timeLbl.Position = UDim2.new(0.6, 0, 0, 0)
        timeLbl.BackgroundTransparency = 1
        timeLbl.Text = entry.time or "?"
        timeLbl.TextColor3 = Color3.fromRGB(150, 150, 170)
        timeLbl.TextSize = 10
        timeLbl.Font = Enum.Font.Code
        timeLbl.TextXAlignment = Enum.TextXAlignment.Right
        timeLbl.Parent = row

        if entry.isTarget then
            local badge = Instance.new("TextLabel")
            badge.Size = UDim2.new(0, 14, 0, 14)
            badge.Position = UDim2.new(1, -18, 0.5, -7)
            badge.BackgroundTransparency = 1
            badge.Text = "🎯"
            badge.TextSize = 12
            badge.Parent = row
        end
    end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
local function runMutationCycle()
    if not State.Running then return end

    local petId = State.PetId
    if not petId or petId == "" then
        log("❌ Pet UUID kosong!")
        State.Stats.Fails += 1
        stopLoop()
        return
    end

    log("🐾 Target: " .. petId:sub(1, 8) .. "...")

    log("📤 Equip pet + keluarin dari tas...")
    equipPet(petId)
    safeInvoke(Remotes.placePet, petId)
    task.wait(DELAY_STEP)
    if not State.Running then return end

    useGearUntilMaxAge(petId)
    task.wait(DELAY_STEP)
    if not State.Running then return end

    log("🔁 Re-equip pet...")
    equipPet(petId)
    task.wait(DELAY_EQUIP + 0.5)
    if not State.Running then return end

    log("🔄 Switch slot ke " .. SLOT_BEFORE_INSERT .. "...")
    switchSlot(SLOT_BEFORE_INSERT)
    if not State.Running then return end

    log("🧬 Insert ke mesin...")
    local ok, result = insertPet(petId)
    if not ok then
        log("❌ Insert gagal: " .. tostring(result))
        State.Stats.Fails += 1
        return
    end
    log("✅ Pet masuk mesin")

    log("🔄 Switch slot ke " .. SLOT_AFTER_INSERT .. "...")
    switchSlot(SLOT_AFTER_INSERT)
    if not State.Running then return end

    local success = waitForMutation()
    if not success then return end

    task.wait(DELAY_STEP)
    log("📦 Collect...")
    local cok, cresult = collectPet()

    if not cok then
        log("❌ Collect gagal: " .. tostring(cresult))
        State.Stats.Fails += 1
        return
    end

    local mutationName = parseMutationResult(cresult)
    local isTarget = isTargetReached(mutationName)

    State.Stats.Mutations += 1
    table.insert(State.Stats.History, {
        time = os.date("%H:%M:%S"),
        mutation = mutationName,
        raw = cresult,
        isTarget = isTarget,
    })

    updateHistory()

    log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    log("🎉 MUTASI DIDAPAT: " .. tostring(mutationName))
    log("   Total mutasi: " .. State.Stats.Mutations)
    log("   Raw value: " .. tostring(cresult) .. " (" .. typeof(cresult) .. ")")
    log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    -- 🔔 KIRIM WEBHOOK
    sendWebhook(mutationName, isTarget)

    if isTarget then
        log("🎯 TARGET TERCAPAI: " .. mutationName .. "!")
        log("🛑 Auto-stop...")
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "🎯 Target Mutation Tercapai!",
                Text = "Dapat: " .. mutationName .. " (total " .. State.Stats.Mutations .. " mutasi)",
                Duration = 10,
            })
        end)
        stopLoop("Target tercapai: " .. tostring(mutationName))
        return
    else
        if next(State.TargetMutations) ~= nil then
            local targetList = {}
            for name, _ in pairs(State.TargetMutations) do
                table.insert(targetList, name)
            end
            log("   Target belum: " .. table.concat(targetList, ", "))
        end
    end
end

function startLoop()
    if State.Running then return end
    State.Running = true
    State.Stats.StartTime = tick()

    task.spawn(function()
        while State.Running do
            local ok, err = pcall(runMutationCycle)
            if not ok then
                State.Stats.Fails += 1
                log("❌ Error: " .. tostring(err))
            end
            task.wait(DELAY_STEP)
        end
        State.Running = false
        updateUI()
    end)
end

function stopLoop(reason)
    State.Running = false
    log("⏹️ Stop")
    sendWebhookStop(reason)
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
MainFrame.Size = UDim2.new(0, 380, 0, 900)
MainFrame.Position = UDim2.new(0, 20, 0.5, -450)
MainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 10)
UICorner.Parent = MainFrame

local UIStroke = Instance.new("UIStroke")
UIStroke.Color = Color3.fromRGB(120, 80, 200)
UIStroke.Thickness = 1
UIStroke.Parent = MainFrame

-- Title
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 38)
Title.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
Title.BorderSizePixel = 0
Title.Text = "🧬 Auto Pet Mutation v11"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 16
Title.Font = Enum.Font.GothamBold
Title.Parent = MainFrame

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 10)
TitleCorner.Parent = Title

local TitleFix = Instance.new("Frame")
TitleFix.Size = UDim2.new(1, 0, 0, 10)
TitleFix.Position = UDim2.new(0, 0, 1, -10)
TitleFix.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
TitleFix.BorderSizePixel = 0
TitleFix.Parent = Title

-- Close
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 30, 0, 30)
CloseBtn.Position = UDim2.new(1, -36, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 14
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = Title

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = CloseBtn

-- Content
local Content = Instance.new("Frame")
Content.Size = UDim2.new(1, -20, 1, -50)
Content.Position = UDim2.new(0, 10, 0, 45)
Content.BackgroundTransparency = 1
Content.Parent = MainFrame

-- Helpers
local function makeLabel(text, y, xOff, w)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(w or 1, 0, 0, 16)
    lbl.Position = UDim2.new(xOff or 0, 0, 0, y)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = Color3.fromRGB(200, 200, 220)
    lbl.TextSize = 10
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = Content
    return lbl
end

local function makeInput(placeholder, defaultText, y, xOff, w, h)
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(w or 1, 0, 0, h or 26)
    box.Position = UDim2.new(xOff or 0, 0, 0, y)
    box.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    box.BorderSizePixel = 0
    box.Text = defaultText or ""
    box.PlaceholderText = placeholder or ""
    box.TextColor3 = Color3.fromRGB(255, 255, 255)
    box.TextSize = 11
    box.Font = Enum.Font.Code
    box.ClearTextOnFocus = false
    box.Parent = Content
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = box
    return box
end

-- Status
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, 0, 0, 22)
StatusLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
StatusLabel.BorderSizePixel = 0
StatusLabel.Text = "Status: IDLE"
StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
StatusLabel.TextSize = 12
StatusLabel.Font = Enum.Font.Gotham
StatusLabel.Parent = Content
local StatusCorner = Instance.new("UICorner")
StatusCorner.CornerRadius = UDim.new(0, 6)
StatusCorner.Parent = StatusLabel

-- Stats
local StatsLabel = Instance.new("TextLabel")
StatsLabel.Size = UDim2.new(1, 0, 0, 36)
StatsLabel.Position = UDim2.new(0, 0, 0, 26)
StatsLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
StatsLabel.BorderSizePixel = 0
StatsLabel.Text = "Mutations: 0 | Gear: 0 | Fails: 0"
StatsLabel.TextColor3 = Color3.fromRGB(180, 150, 220)
StatsLabel.TextSize = 10
StatsLabel.Font = Enum.Font.Code
StatsLabel.Parent = Content
local StatsCorner = Instance.new("UICorner")
StatsCorner.CornerRadius = UDim.new(0, 6)
StatsCorner.Parent = StatsLabel

-- Machine timer
local MachineFrame = Instance.new("Frame")
MachineFrame.Size = UDim2.new(1, 0, 0, 52)
MachineFrame.Position = UDim2.new(0, 0, 0, 68)
MachineFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
MachineFrame.BorderSizePixel = 0
MachineFrame.Parent = Content
local MachineCorner = Instance.new("UICorner")
MachineCorner.CornerRadius = UDim.new(0, 8)
MachineCorner.Parent = MachineFrame
local MachineStroke = Instance.new("UIStroke")
MachineStroke.Color = Color3.fromRGB(100, 70, 150)
MachineStroke.Thickness = 1.5
MachineStroke.Parent = MachineFrame

local MachineStateLabel = Instance.new("TextLabel")
MachineStateLabel.Size = UDim2.new(0.5, -5, 0, 20)
MachineStateLabel.Position = UDim2.new(0, 8, 0, 4)
MachineStateLabel.BackgroundTransparency = 1
MachineStateLabel.Text = "⏱️ Mesin: IDLE"
MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
MachineStateLabel.TextSize = 11
MachineStateLabel.Font = Enum.Font.GothamBold
MachineStateLabel.TextXAlignment = Enum.TextXAlignment.Left
MachineStateLabel.Parent = MachineFrame

local MachineTimerLabel = Instance.new("TextLabel")
MachineTimerLabel.Size = UDim2.new(0.5, -5, 0, 20)
MachineTimerLabel.Position = UDim2.new(0.5, 0, 0, 4)
MachineTimerLabel.BackgroundTransparency = 1
MachineTimerLabel.Text = "00:00"
MachineTimerLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
MachineTimerLabel.TextSize = 11
MachineTimerLabel.Font = Enum.Font.Code
MachineTimerLabel.TextXAlignment = Enum.TextXAlignment.Right
MachineTimerLabel.Parent = MachineFrame

local ProgressBg = Instance.new("Frame")
ProgressBg.Size = UDim2.new(1, -16, 0, 14)
ProgressBg.Position = UDim2.new(0, 8, 0, 28)
ProgressBg.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
ProgressBg.BorderSizePixel = 0
ProgressBg.Parent = MachineFrame
local ProgressCorner = Instance.new("UICorner")
ProgressCorner.CornerRadius = UDim.new(0, 7)
ProgressCorner.Parent = ProgressBg

local ProgressFill = Instance.new("Frame")
ProgressFill.Size = UDim2.new(0, 0, 1, 0)
ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
ProgressFill.BorderSizePixel = 0
ProgressFill.Parent = ProgressBg
local FillCorner = Instance.new("UICorner")
FillCorner.CornerRadius = UDim.new(0, 7)
FillCorner.Parent = ProgressFill

-- Input Pet UUID
makeLabel("🐾 Pet UUID:", 126)
local PetIdBox = makeInput("3f73ba8c-f9cd-4011-aee9-...", "", 144, 0, 1, 28)
local PetIdStroke = Instance.new("UIStroke")
PetIdStroke.Color = Color3.fromRGB(150, 100, 220)
PetIdStroke.Thickness = 1.5
PetIdStroke.Parent = PetIdBox

-- Gear Name
makeLabel("🔧 Gear Name:", 178)
local GearNameBox = makeInput("DiamondCookie", DEFAULT_GEAR_NAME, 196, 0, 1, 26)

-- Umur Pet
makeLabel("📊 Umur Pet:", 228)
local AgeBox = Instance.new("TextLabel")
AgeBox.Size = UDim2.new(1, 0, 0, 26)
AgeBox.Position = UDim2.new(0, 0, 0, 246)
AgeBox.BackgroundColor3 = Color3.fromRGB(35, 45, 35)
AgeBox.BorderSizePixel = 0
AgeBox.Text = "— / " .. tostring(MAX_AGE or 50)
AgeBox.TextColor3 = Color3.fromRGB(150, 230, 150)
AgeBox.TextSize = 12
AgeBox.Font = Enum.Font.GothamBold
AgeBox.Parent = Content
local AgeCorner = Instance.new("UICorner")
AgeCorner.CornerRadius = UDim.new(0, 6)
AgeCorner.Parent = AgeBox

-- Target mutation
makeLabel("🎯 Target Mutation (pilih beberapa):", 280)
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size = UDim2.new(1, 0, 0, 70)
ScrollFrame.Position = UDim2.new(0, 0, 0, 298)
ScrollFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
ScrollFrame.BorderSizePixel = 0
ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollFrame.ScrollBarThickness = 5
ScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
ScrollFrame.Parent = Content
local ScrollCorner = Instance.new("UICorner")
ScrollCorner.CornerRadius = UDim.new(0, 6)
ScrollCorner.Parent = ScrollFrame
local ScrollStroke = Instance.new("UIStroke")
ScrollStroke.Color = Color3.fromRGB(80, 60, 120)
ScrollStroke.Thickness = 1
ScrollStroke.Parent = ScrollFrame

local ScrollLayout = Instance.new("UIListLayout")
ScrollLayout.Padding = UDim.new(0, 3)
ScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
ScrollLayout.Parent = ScrollFrame

local ScrollPadding = Instance.new("UIPadding")
ScrollPadding.PaddingTop = UDim.new(0, 5)
ScrollPadding.PaddingLeft = UDim.new(0, 5)
ScrollPadding.PaddingRight = UDim.new(0, 5)
ScrollPadding.PaddingBottom = UDim.new(0, 5)
ScrollPadding.Parent = ScrollFrame

local mutationList = getMutationList()

for i, mutName in ipairs(mutationList) do
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 22)
    row.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    row.BorderSizePixel = 0
    row.LayoutOrder = i
    row.Parent = ScrollFrame
    local rowCorner = Instance.new("UICorner")
    rowCorner.CornerRadius = UDim.new(0, 4)
    rowCorner.Parent = row

    local checkbox = Instance.new("TextButton")
    checkbox.Name = "Checkbox"
    checkbox.Size = UDim2.new(0, 18, 0, 18)
    checkbox.Position = UDim2.new(0, 3, 0.5, -9)
    checkbox.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    checkbox.BorderSizePixel = 0
    checkbox.Text = ""
    checkbox.Parent = row
    local cbCorner = Instance.new("UICorner")
    cbCorner.CornerRadius = UDim.new(0, 4)
    cbCorner.Parent = checkbox

    local checkmark = Instance.new("TextLabel")
    checkmark.Size = UDim2.fromScale(1, 1)
    checkmark.BackgroundTransparency = 1
    checkmark.Text = ""
    checkmark.TextColor3 = Color3.fromRGB(255, 255, 255)
    checkmark.TextSize = 14
    checkmark.Font = Enum.Font.GothamBold
    checkmark.Parent = checkbox

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -35, 1, 0)
    lbl.Position = UDim2.new(0, 26, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = mutName
    lbl.TextColor3 = Color3.fromRGB(220, 220, 240)
    lbl.TextSize = 11
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
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            toggle()
        end
    end)
end

ScrollLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, ScrollLayout.AbsoluteContentSize.Y + 10)
end)
task.defer(function()
    ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, ScrollLayout.AbsoluteContentSize.Y + 10)
end)

-- Clear target
local ClearTargetBtn = Instance.new("TextButton")
ClearTargetBtn.Size = UDim2.new(1, 0, 0, 20)
ClearTargetBtn.Position = UDim2.new(0, 0, 0, 374)
ClearTargetBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 50)
ClearTargetBtn.BorderSizePixel = 0
ClearTargetBtn.Text = "🗑️ Clear Target (loop terus)"
ClearTargetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ClearTargetBtn.TextSize = 10
ClearTargetBtn.Font = Enum.Font.GothamMedium
ClearTargetBtn.Parent = Content
local ClearCorner = Instance.new("UICorner")
ClearCorner.CornerRadius = UDim.new(0, 4)
ClearCorner.Parent = ClearTargetBtn

-- ============================================================
-- WEBHOOK INPUT (BARU v11)
-- ============================================================
makeLabel("🔗 Discord Webhook URL (kosong = off):", 400)
local WebhookBox = makeInput("https://discord.com/api/webhooks/...", "", 418, 0, 1, 26)
local WebhookStroke = Instance.new("UIStroke")
WebhookStroke.Color = Color3.fromRGB(80, 130, 200)
WebhookStroke.Thickness = 1.5
WebhookStroke.Parent = WebhookBox

-- Webhook mention
makeLabel("📢 Mention (opsional, ex: <@123> atau @everyone):", 448)
local MentionBox = makeInput("<@123>", "", 466, 0, 1, 22)

-- Webhook toggles
local WebhookToggleBtn = Instance.new("TextButton")
WebhookToggleBtn.Size = UDim2.new(0.49, -2, 0, 24)
WebhookToggleBtn.Position = UDim2.new(0, 0, 0, 492)
WebhookToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 130, 90)
WebhookToggleBtn.BorderSizePixel = 0
WebhookToggleBtn.Text = "🔔 Webhook: ON"
WebhookToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookToggleBtn.TextSize = 11
WebhookToggleBtn.Font = Enum.Font.GothamBold
WebhookToggleBtn.Parent = Content
local WHCorner = Instance.new("UICorner")
WHCorner.CornerRadius = UDim.new(0, 4)
WHCorner.Parent = WebhookToggleBtn

local WebhookOnlyTargetBtn = Instance.new("TextButton")
WebhookOnlyTargetBtn.Size = UDim2.new(0.49, -2, 0, 24)
WebhookOnlyTargetBtn.Position = UDim2.new(0.51, 0, 0, 492)
WebhookOnlyTargetBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
WebhookOnlyTargetBtn.BorderSizePixel = 0
WebhookOnlyTargetBtn.Text = "🎯 Only Target: OFF"
WebhookOnlyTargetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookOnlyTargetBtn.TextSize = 11
WebhookOnlyTargetBtn.Font = Enum.Font.GothamBold
WebhookOnlyTargetBtn.Parent = Content
local WOTCorner = Instance.new("UICorner")
WOTCorner.CornerRadius = UDim.new(0, 4)
WOTCorner.Parent = WebhookOnlyTargetBtn

-- Test webhook button
local TestWebhookBtn = Instance.new("TextButton")
TestWebhookBtn.Size = UDim2.new(1, 0, 0, 22)
TestWebhookBtn.Position = UDim2.new(0, 0, 0, 520)
TestWebhookBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
TestWebhookBtn.BorderSizePixel = 0
TestWebhookBtn.Text = "📤 Test Webhook"
TestWebhookBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
TestWebhookBtn.TextSize = 10
TestWebhookBtn.Font = Enum.Font.GothamMedium
TestWebhookBtn.Parent = Content
local TestCorner = Instance.new("UICorner")
TestCorner.CornerRadius = UDim.new(0, 4)
TestCorner.Parent = TestWebhookBtn

-- Auto-Detect
local AutoDetectBtn = Instance.new("TextButton")
AutoDetectBtn.Size = UDim2.new(1, 0, 0, 24)
AutoDetectBtn.Position = UDim2.new(0, 0, 0, 546)
AutoDetectBtn.BackgroundColor3 = Color3.fromRGB(60, 130, 90)
AutoDetectBtn.BorderSizePixel = 0
AutoDetectBtn.Text = "🤖 Auto-Detect Mesin: ON"
AutoDetectBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AutoDetectBtn.TextSize = 11
AutoDetectBtn.Font = Enum.Font.GothamBold
AutoDetectBtn.Parent = Content
local AutoDetectCorner = Instance.new("UICorner")
AutoDetectCorner.CornerRadius = UDim.new(0, 6)
AutoDetectCorner.Parent = AutoDetectBtn

-- START
local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(1, 0, 0, 40)
ToggleBtn.Position = UDim2.new(0, 0, 0, 576)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(120, 70, 200)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Text = "▶  START AUTO MUTATION"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 13
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = Content
local ToggleCorner = Instance.new("UICorner")
ToggleCorner.CornerRadius = UDim.new(0, 8)
ToggleCorner.Parent = ToggleBtn

-- History
local HistoryHeader = Instance.new("TextLabel")
HistoryHeader.Size = UDim2.new(1, 0, 0, 16)
HistoryHeader.Position = UDim2.new(0, 0, 0, 622)
HistoryHeader.BackgroundTransparency = 1
HistoryHeader.Text = "📜 History Mutasi:"
HistoryHeader.TextColor3 = Color3.fromRGB(220, 180, 255)
HistoryHeader.TextSize = 11
HistoryHeader.Font = Enum.Font.GothamBold
HistoryHeader.TextXAlignment = Enum.TextXAlignment.Left
HistoryHeader.Parent = Content

local HistoryBg = Instance.new("Frame")
HistoryBg.Size = UDim2.new(1, 0, 0, 120)
HistoryBg.Position = UDim2.new(0, 0, 0, 640)
HistoryBg.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
HistoryBg.BorderSizePixel = 0
HistoryBg.Parent = Content
local HistoryCorner = Instance.new("UICorner")
HistoryCorner.CornerRadius = UDim.new(0, 6)
HistoryCorner.Parent = HistoryBg
local HistoryStroke = Instance.new("UIStroke")
HistoryStroke.Color = Color3.fromRGB(120, 80, 200)
HistoryStroke.Thickness = 1
HistoryStroke.Parent = HistoryBg

local HistoryScroll = Instance.new("ScrollingFrame")
HistoryScroll.Size = UDim2.new(1, -10, 1, -10)
HistoryScroll.Position = UDim2.new(0, 5, 0, 5)
HistoryScroll.BackgroundTransparency = 1
HistoryScroll.BorderSizePixel = 0
HistoryScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
HistoryScroll.ScrollBarThickness = 4
HistoryScroll.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
HistoryScroll.Parent = HistoryBg

local HistoryContent = Instance.new("Frame")
HistoryContent.Name = "Content"
HistoryContent.Size = UDim2.new(1, 0, 0, 0)
HistoryContent.BackgroundTransparency = 1
HistoryContent.Parent = HistoryScroll

local HistoryLayout = Instance.new("UIListLayout")
HistoryLayout.Padding = UDim.new(0, 3)
HistoryLayout.SortOrder = Enum.SortOrder.LayoutOrder
HistoryLayout.Parent = HistoryContent

HistoryLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    HistoryScroll.CanvasSize = UDim2.new(0, 0, 0, HistoryLayout.AbsoluteContentSize.Y + 6)
end)

-- History buttons
local ClearHistoryBtn = Instance.new("TextButton")
ClearHistoryBtn.Size = UDim2.new(0.5, -2, 0, 20)
ClearHistoryBtn.Position = UDim2.new(0, 0, 0, 766)
ClearHistoryBtn.BackgroundColor3 = Color3.fromRGB(60, 40, 40)
ClearHistoryBtn.BorderSizePixel = 0
ClearHistoryBtn.Text = "🗑️ Clear History"
ClearHistoryBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
ClearHistoryBtn.TextSize = 10
ClearHistoryBtn.Font = Enum.Font.GothamMedium
ClearHistoryBtn.Parent = Content
local CHCorner = Instance.new("UICorner")
CHCorner.CornerRadius = UDim.new(0, 4)
CHCorner.Parent = ClearHistoryBtn

local ExportBtn = Instance.new("TextButton")
ExportBtn.Size = UDim2.new(0.5, -2, 0, 20)
ExportBtn.Position = UDim2.new(0.5, 2, 0, 766)
ExportBtn.BackgroundColor3 = Color3.fromRGB(40, 60, 80)
ExportBtn.BorderSizePixel = 0
ExportBtn.Text = "📋 Copy History"
ExportBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
ExportBtn.TextSize = 10
ExportBtn.Font = Enum.Font.GothamMedium
ExportBtn.Parent = Content
local EXCorner = Instance.new("UICorner")
EXCorner.CornerRadius = UDim.new(0, 4)
EXCorner.Parent = ExportBtn

-- Log
local LogBg = Instance.new("Frame")
LogBg.Size = UDim2.new(1, 0, 0, 90)
LogBg.Position = UDim2.new(0, 0, 0, 792)
LogBg.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
LogBg.BorderSizePixel = 0
LogBg.Parent = Content
local LogCorner = Instance.new("UICorner")
LogCorner.CornerRadius = UDim.new(0, 6)
LogCorner.Parent = LogBg

local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -10, 1, -10)
LogLabel.Position = UDim2.new(0, 5, 0, 5)
LogLabel.BackgroundTransparency = 1
LogLabel.Text = "[Log akan muncul di sini]"
LogLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
LogLabel.TextSize = 9
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
            local state, remaining = getMachineState()
            if state == "Idle" then
                MachineStateLabel.Text = "⏱️ Mesin: IDLE"
                MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
                MachineTimerLabel.Text = "00:00"
                MachineTimerLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
                ProgressFill.Size = UDim2.new(0, 0, 1, 0)
            elseif state == "InProgress" then
                MachineStateLabel.Text = "⚙️ Mesin: MUTATING"
                MachineStateLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
                MachineTimerLabel.Text = formatTime(remaining)
                MachineTimerLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
                local total = PET_MUTATION_TIME
                local pct = math.clamp((total - remaining) / total, 0, 1)
                ProgressFill.Size = UDim2.new(pct, 0, 1, 0)
                ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
            elseif state == "Ready" then
                MachineStateLabel.Text = "✅ Mesin: READY!"
                MachineStateLabel.TextColor3 = Color3.fromRGB(120, 230, 120)
                MachineTimerLabel.Text = "00:00"
                MachineTimerLabel.TextColor3 = Color3.fromRGB(120, 230, 120)
                ProgressFill.Size = UDim2.new(1, 0, 1, 0)
                ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 230, 120)
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

-- ============================================================
-- UI UPDATE
-- ============================================================
function updateUI()
    if State.Running then
        StatusLabel.Text = "Status: RUNNING"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 150, 255)
        ToggleBtn.Text = "⏹  STOP"
        TweenService:Create(ToggleBtn, TweenInfo.new(0.2), {
            BackgroundColor3 = Color3.fromRGB(200, 60, 60)
        }):Play()
    else
        StatusLabel.Text = "Status: IDLE"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
        ToggleBtn.Text = "▶  START AUTO MUTATION"
        TweenService:Create(ToggleBtn, TweenInfo.new(0.2), {
            BackgroundColor3 = Color3.fromRGB(120, 70, 200)
        }):Play()
    end
    AutoDetectBtn.Text = "🤖 Auto-Detect: " .. (State.AutoDetect and "ON" or "OFF")
    AutoDetectBtn.BackgroundColor3 = State.AutoDetect
        and Color3.fromRGB(60, 130, 90)
        or Color3.fromRGB(120, 70, 70)

    WebhookToggleBtn.Text = "🔔 Webhook: " .. (State.WebhookEnabled and "ON" or "OFF")
    WebhookToggleBtn.BackgroundColor3 = State.WebhookEnabled
        and Color3.fromRGB(60, 130, 90)
        or Color3.fromRGB(120, 70, 70)

    WebhookOnlyTargetBtn.Text = "🎯 Only Target: " .. (State.WebhookOnlyTarget and "ON" or "OFF")
    WebhookOnlyTargetBtn.BackgroundColor3 = State.WebhookOnlyTarget
        and Color3.fromRGB(120, 80, 180)
        or Color3.fromRGB(60, 60, 80)
end

local function updateStats()
    while ScreenGui.Parent do
        StatsLabel.Text = string.format(
            "Mutations: %d | Gear: %d | Fails: %d",
            State.Stats.Mutations, State.Stats.GearUsed, State.Stats.Fails
        )
        task.wait(1)
    end
end

task.spawn(updateStats)

-- ============================================================
-- EVENT HANDLERS
-- ============================================================
AutoDetectBtn.MouseButton1Click:Connect(function()
    State.AutoDetect = not State.AutoDetect
    updateUI()
end)

WebhookToggleBtn.MouseButton1Click:Connect(function()
    State.WebhookEnabled = not State.WebhookEnabled
    State.WebhookURL = WebhookBox.Text:gsub("%s", "")
    State.WebhookMention = MentionBox.Text
    updateUI()
end)

WebhookOnlyTargetBtn.MouseButton1Click:Connect(function()
    State.WebhookOnlyTarget = not State.WebhookOnlyTarget
    updateUI()
end)

TestWebhookBtn.MouseButton1Click:Connect(function()
    State.WebhookURL = WebhookBox.Text:gsub("%s", "")
    State.WebhookMention = MentionBox.Text
    if State.WebhookURL == "" then
        log("❌ Isi Webhook URL dulu!")
        return
    end
    log("📤 Test webhook dikirim...")
    sendWebhook("TEST_MUTATION", true, "Ini adalah test webhook dari GUI.")
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
    log("🗑️ Target dikosongkan (loop terus)")
end)

ClearHistoryBtn.MouseButton1Click:Connect(function()
    State.Stats.History = {}
    updateHistory()
    log("🗑️ History dihapus")
end)

ExportBtn.MouseButton1Click:Connect(function()
    if #State.Stats.History == 0 then
        log("📋 History kosong")
        return
    end
    local lines = {}
    for i, e in ipairs(State.Stats.History) do
        table.insert(lines, string.format("#%d [%s] %s%s", 
            i, e.time, tostring(e.mutation), e.isTarget and " 🎯" or ""))
    end
    local text = table.concat(lines, "\n")
    pcall(function()
        if setclipboard then
            setclipboard(text)
        elseif toclipboard then
            toclipboard(text)
        end
    end)
    log("📋 History dicopy (" .. #State.Stats.History .. " item)")
end)

ToggleBtn.MouseButton1Click:Connect(function()
    if State.Running then
        stopLoop("Manual stop")
    else
        local petId = PetIdBox.Text:gsub("%s", "")
        if petId == "" then
            log("❌ Isi Pet UUID dulu!")
            PetIdBox.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
            task.delay(1, function()
                PetIdBox.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
            end)
            return
        end

        State.PetId = petId
        State.GearName = GearNameBox.Text ~= "" and GearNameBox.Text or DEFAULT_GEAR_NAME
        State.WebhookURL = WebhookBox.Text:gsub("%s", "")
        State.WebhookMention = MentionBox.Text
        State.Stats.Mutations = 0
        State.Stats.GearUsed = 0
        State.Stats.Fails = 0
        State.Stats.History = {}
        updateHistory()

        log("🚀 START pet: " .. petId:sub(1, 8) .. "...")
        sendWebhookStart()
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
    if input.KeyCode == Enum.KeyCode.RightControl then
        ToggleBtn:Activate()
    end
end)

log("✅ GUI loaded (v11). Webhook ready.")
