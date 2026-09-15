--[[
    AUTO PET MUTATION — UUID-Based Sequential (v12.7)
    ----------------------------------------------------------
    v12.7:
    - FIX: updateHistory/updateProgressPanel/updateUI/updateStats
      pakai global function (bukan `local function`) biar bisa
      dipanggil dari doInsertPhase yang didefinisi di atasnya
    - Pickup pet sebelum insert
    - Sequential insert (1 mesin)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local DEFAULT_GEAR_NAME = "DiamondCookie"
local SAFETY_MAX_GEAR = 150
local SLOT_BEFORE_INSERT = 0
local SLOT_AFTER_INSERT  = 1
local DELAY_EQUIP = 0.5
local DELAY_USE   = 0.5
local DELAY_STEP  = 1
local DELAY_SLOT  = 0.8
local DELAY_COLLECT = 2
local DELAY_AFTER_COLLECT = 2
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
local getPetAgeFromData, MAX_AGE

pcall(function() getPlayerData = require(ReplicatedStorage.TS.state["player-data"]).getPlayerData end)
pcall(function() getSharedTime = require(game:GetService("StarterPlayer").StarterPlayerScripts.TS.systems.core.sharedTime).getSharedTime end)
pcall(function() PET_MUTATION_TIME = require(ReplicatedStorage.TS.constants).PET_MUTATION_TIME end)
pcall(function() PetMutations = require(ReplicatedStorage.TS.lists.game["pet-mutations"]).PetMutations end)
pcall(function()
    local v4 = require(ReplicatedStorage.TS.utils["pet-age.utils"])
    getPetAgeFromData = v4.getPetAgeFromData
    MAX_AGE = v4.MAX_AGE
end)

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

local Remotes = {}
local function ensureRemote(key, name)
    if not Remotes[key] then Remotes[key] = getRemo(name) end
    return Remotes[key]
end

Remotes.equipTool    = getRemo("tools.equipTool")
Remotes.unequipTool  = getRemo("tools.unequipTool")
Remotes.placePet     = getRemo("pets.placePetFromInventory")
Remotes.usePetGear   = getRemo("pets.usePetGearOnPet")
Remotes.switchSlot   = getRemo("pets.switchPetLoadout")
Remotes.startMut     = getRemo("pets.startMutation")
Remotes.collectMut   = getRemo("pets.collectMutation")
Remotes.pickUpPet    = getRemo("pets.pickUpPet")

local State = {
    Running = false,
    PetQueue = {},
    PetQueueOrder = {},
    CurrentPetId = nil,
    CurrentPetIdx = 0,
    CurrentBatch = 0,
    CurrentPhase = "idle",
    GearName = DEFAULT_GEAR_NAME,
    AutoDetect = true,
    TargetMutations = {},
    WebhookURL = "",
    WebhookEnabled = true,
    WebhookMention = "",
    WebhookOnlyTarget = false,
    PetList = {},
    Stats = {
        Mutations = 0, GearUsed = 0, Fails = 0,
        StartTime = 0, History = {},
    },
}

local function safeFire(remote, ...)
    if not remote then return false end
    local args = {...}
    local ok, err = pcall(function() remote:FireServer(table.unpack(args)) end)
    if not ok then warn("[AutoMut] Fire gagal:", err) end
    return ok
end

local function safeInvoke(remote, ...)
    if not remote then return false, "remote nil" end
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

local function shortUUID(uuid)
    if not uuid then return "?" end
    return uuid:sub(1, 8) .. "..."
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

local function getPetFromQueue(uuid) return State.PetQueue[uuid] end

local function allPetsTargetHit()
    for _, uuid in ipairs(State.PetQueueOrder) do
        local pet = State.PetQueue[uuid]
        if pet and not pet.targetHit then return false end
    end
    return true
end

local function scanPets()
    if not inventoryStateModule then return {} end
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return {} end
    local pets = {}
    local seen = {}
    for stackKey, item in pairs(stacked) do
        local tt = tostring(item.toolType):lower()
        if tt:find("pet") and item.items and item.items[1] then
            local petId = item.items[1].id
            if petId and not seen[petId] then
                seen[petId] = true
                local pd = item.items[1].data
                table.insert(pets, {
                    id = petId, stackKey = stackKey,
                    displayName = item.displayName or item.itemName,
                    mutation = pd.mutation, mutationCount = pd.mutationCount,
                })
            end
        end
    end
    table.sort(pets, function(a, b)
        if a.displayName ~= b.displayName then return a.displayName < b.displayName end
        return (a.mutationCount or 0) > (b.mutationCount or 0)
    end)
    return pets
end

-- ============================================================
-- FORWARD DECLARATIONS (biar bisa dipanggil dari fungsi di atas)
-- ============================================================
local updateHistory, updateProgressPanel, updateUI, updateStats

-- ============================================================
-- WEBHOOK
-- ============================================================
local function sendWebhookPayload(payload)
    local req = getRequestFunction()
    if not req then return false end
    local ok, err = pcall(function()
        local r = req({
            Url = State.WebhookURL, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload)
        })
        if r and r.StatusCode and r.StatusCode >= 200 and r.StatusCode < 300 then
            log("📤 Webhook ✅ (" .. r.StatusCode .. ")")
        end
    end)
    if not ok then warn("[AutoMut] Webhook error:", err) end
end

local function sendWebhook(petId, mutationName, isTarget, allDone)
    if not State.WebhookEnabled or State.WebhookURL == "" then return end
    if State.WebhookOnlyTarget and not isTarget and not allDone then return end

    local pet = getPetFromQueue(petId)
    local petName = pet and pet.displayName or "?"
    local color = isTarget and 5763719 or 3447003
    local title
    if allDone then title = "🏆 SEMUA PET TARGET TERCAPAI!"; color = 15844367
    elseif isTarget then title = "🎯 TARGET MUTATION TERCAPAI!"
    else title = "🧬 Mutasi Baru Didapat" end
    local emoji = isTarget and "🎯" or "🎉"

    local petInfo = ""
    local totalTarget = 0
    for _, uuid in ipairs(State.PetQueueOrder) do
        local p = State.PetQueue[uuid]
        if p then
            if p.targetHit then totalTarget += 1 end
            petInfo = petInfo .. string.format("%s %s (%s) — %d mutasi%s\n",
                p.targetHit and "✅" or "⏳", p.displayName, shortUUID(uuid),
                p.mutations or 0, p.targetHit and (" 🎯 [" .. (p.lastMutation or "?") .. "]") or "")
        end
    end

    local desc = string.format(
        "%s **%s** didapat dari **%s**!\n\n**Pet Info:**\n" ..
        "• Pet: `%s`\n• UUID: `%s`\n• Mutation: `%s`\n• Target: `%s`\n" ..
        "• Batch: `#%d`\n• Total Mutasi: `%d`\n• Gear: `%d`\n• Fails: `%d`\n\n" ..
        "**Progress: %d/%d target**\n%s",
        emoji, mutationName or "?", petName, petName, shortUUID(petId),
        tostring(mutationName or "?"), isTarget and "✅ YA" or "❌ BUKAN",
        State.CurrentBatch, State.Stats.Mutations, State.Stats.GearUsed, State.Stats.Fails,
        totalTarget, #State.PetQueueOrder, petInfo
    )

    task.spawn(function()
        sendWebhookPayload({
            content = State.WebhookMention ~= "" and State.WebhookMention or "",
            username = "Auto Mutation Bot",
            embeds = {{
                title = title, description = desc, color = color,
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                footer = { text = "Auto Pet Mutation v12.7 • " .. LocalPlayer.Name },
                fields = {
                    { name = "🐾 Queue", value = "`" .. #State.PetQueueOrder .. " pet`", inline = true },
                    { name = "🎯 Target", value = "`" .. totalTarget .. "/" .. #State.PetQueueOrder .. "`", inline = true },
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

local function equipPet(petId)
    ensureRemote("equipTool", "tools.equipTool")
    safeFire(Remotes.equipTool, petId, "pet")
    task.wait(DELAY_EQUIP)
end

local function equipGear(name)
    ensureRemote("equipTool", "tools.equipTool")
    safeFire(Remotes.equipTool, name, "gear")
    task.wait(DELAY_EQUIP)
end

local function useGearOnPet(petId)
    ensureRemote("usePetGear", "pets.usePetGearOnPet")
    return safeFire(Remotes.usePetGear, petId)
end

local function switchSlot(s)
    ensureRemote("switchSlot", "pets.switchPetLoadout")
    local ok, r = safeInvoke(Remotes.switchSlot, s)
    task.wait(DELAY_SLOT)
    return ok, r
end

local function insertPet(id)
    ensureRemote("startMut", "pets.startMutation")
    return safeInvoke(Remotes.startMut, id)
end

local function pickUpPet(id)
    ensureRemote("pickUpPet", "pets.pickUpPet")
    return safeInvoke(Remotes.pickUpPet, id)
end

local function collectPet()
    ensureRemote("collectMut", "pets.collectMutation")
    if not Remotes.collectMut then return false, "collectMut nil" end
    
    for attempt = 1, 5 do
        log("   📦 Collect attempt #" .. attempt .. "...")
        local ok, result = pcall(function()
            return Remotes.collectMut:InvokeServer()
        end)
        
        if ok and result ~= false and result ~= nil then
            log("   ✅ Collect OK: " .. tostring(result))
            return true, result
        end
        
        if not ok then
            log("   ⚠️ Error: " .. tostring(result))
        else
            log("   ⚠️ Server return false, retry...")
        end
        
        if attempt < 5 then task.wait(5) end
    end
    
    return false, "collect failed 5x"
end

-- ============================================================
-- FASE 1: NAIKIN UMUR + PICKUP
-- ============================================================
local function doAgePhase()
    log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    log("📊 FASE 1: Naikin umur (" .. #State.PetQueueOrder .. " pet)")
    log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    for i, uuid in ipairs(State.PetQueueOrder) do
        if not State.Running then return false end
        local pet = State.PetQueue[uuid]
        if pet then
            if pet.targetHit then
                log(string.format("⏭️ [%d/%d] SKIP %s (%s)", i, #State.PetQueueOrder, pet.displayName, shortUUID(uuid)))
            else
                log(string.format("🐾 [%d/%d] %s (%s)", i, #State.PetQueueOrder, pet.displayName, shortUUID(uuid)))
                
                log("   🎒 Equip pet...")
                equipPet(uuid)
                safeInvoke(Remotes.placePet, uuid)
                task.wait(DELAY_STEP)
                
                if State.Running then
                    local gearCount = 0
                    while State.Running do
                        local age = getPetAge(uuid)
                        if age == nil then break end
                        if age >= MAX_AGE then log("   ✅ Umur " .. age .. "/" .. MAX_AGE); break end
                        gearCount += 1
                        equipGear(State.GearName)
                        useGearOnPet(uuid)
                        State.Stats.GearUsed += 1
                        if gearCount % 5 == 0 then log("   🔧 gear " .. gearCount .. " | umur: " .. age .. "/" .. MAX_AGE) end
                        task.wait(DELAY_USE)
                        if gearCount >= SAFETY_MAX_GEAR then break end
                    end
                    log("   ✅ " .. pet.displayName .. " selesai (" .. gearCount .. " gear)")
                    
                    log("   📦 Pickup pet...")
                    pickUpPet(uuid)
                    task.wait(1.5)
                end
            end
        end
    end
    log("✅ FASE 1 SELESAI")
    return true
end

-- ============================================================
-- FASE 2: PICKUP → EQUIP → INSERT → COLLECT
-- ============================================================
local function doInsertPhase()
    log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    log("🧬 FASE 2: Insert bergantian (" .. #State.PetQueueOrder .. " pet)")
    log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    for i, uuid in ipairs(State.PetQueueOrder) do
        if not State.Running then return false end
        local pet = State.PetQueue[uuid]
        if pet then
            log(string.format("🔍 Iterasi [%d/%d] UUID: %s", i, #State.PetQueueOrder, shortUUID(uuid)))
            
            if pet.targetHit then
                log(string.format("⏭️ SKIP %s (target: %s)", pet.displayName, pet.lastMutation or "?"))
            else
                log("   ⏳ Cek mesin kosong...")
                local idleCheck = 0
                local isIdle = false
                while idleCheck < 60 do
                    if not State.Running then return false end
                    local ms = getMachineState()
                    if ms == "Idle" then isIdle = true; break
                    elseif ms == "Ready" then
                        log("   ⚠️ Ada pet Ready, collect dulu...")
                        task.wait(2); collectPet(); task.wait(3)
                    elseif ms == "InProgress" then
                        log("   ⚠️ Mesin masih InProgress...")
                        task.wait(5)
                    end
                    idleCheck += 5
                end
                
                if not isIdle then
                    log("   ❌ Mesin gak kosong 60s, skip")
                    State.Stats.Fails += 1
                else
                    log("   ✅ Mesin IDLE")
                    log(string.format("🐾 PROSES %s (%s)", pet.displayName, shortUUID(uuid)))
                    State.CurrentPetId = uuid
                    State.CurrentPetIdx = i
                    if updateProgressPanel then updateProgressPanel() end
                    
                    log("   📦 Pickup pet...")
                    pickUpPet(uuid)
                    task.wait(2)
                    
                    log("   🎒 Equip pet...")
                    equipPet(uuid)
                    task.wait(2)
                    
                    if not State.Running then return false end
                    
                    switchSlot(SLOT_BEFORE_INSERT)
                    task.wait(1)
                    
                    local insertOk = false
                    local insertResult = nil
                    
                    for attempt = 1, 3 do
                        if not State.Running then return false end
                        log("   🧬 Insert attempt #" .. attempt .. "...")
                        insertOk, insertResult = insertPet(uuid)
                        
                        if insertOk and insertResult ~= false and insertResult ~= nil then
                            log("   ✅ Masuk mesin! (result: " .. typeof(insertResult) .. ")")
                            break
                        else
                            log("   ⚠️ Insert gagal (result: " .. tostring(insertResult) .. ")")
                            if attempt < 3 then
                                log("   🔁 Pickup + re-equip + retry...")
                                task.wait(2)
                                pickUpPet(uuid)
                                task.wait(2)
                                equipPet(uuid)
                                task.wait(2)
                                switchSlot(SLOT_BEFORE_INSERT)
                                task.wait(1)
                            end
                        end
                    end
                    
                    if not insertOk or insertResult == false or insertResult == nil then
                        log("   ❌ Insert gagal 3x, skip pet ini")
                        State.Stats.Fails += 1
                    else
                        switchSlot(SLOT_AFTER_INSERT)
                        
                        if State.Running then
                            log("   ⏳ Nunggu mutasi...")
                            local lastLog = 0
                            local ready = false
                            local waitStart = tick()
                            
                            while State.Running do
                                local ms, rem = getMachineState()
                                if ms == "Ready" then
                                    log("   ✅ READY setelah " .. math.floor(tick() - waitStart) .. "s")
                                    ready = true
                                    break
                                elseif ms == "Idle" then
                                    log("   ⚠️ Mesin Idle")
                                    break
                                elseif ms == "InProgress" then
                                    local now = tick()
                                    if now - lastLog >= 60 then
                                        log("   ⏳ sisa " .. formatTime(rem))
                                        lastLog = now
                                    end
                                end
                                task.wait(POLL_INTERVAL)
                            end
                            
                            if ready then
                                log("   ⏸️ Delay " .. DELAY_COLLECT .. "s...")
                                task.wait(DELAY_COLLECT)
                                if not State.Running then return false end
                                
                                log("   📦 Collect...")
                                local cok, cr = collectPet()
                                
                                if not cok then
                                    log("   ❌ Collect gagal: " .. tostring(cr))
                                    State.Stats.Fails += 1
                                else
                                    local m = parseMutationResult(cr)
                                    local isTarget = isTargetReached(m)
                                    
                                    State.Stats.Mutations += 1
                                    pet.mutations = (pet.mutations or 0) + 1
                                    pet.lastMutation = m
                                    if isTarget then
                                        pet.targetHit = true
                                        pet.locked = true
                                    end
                                    
                                    table.insert(State.Stats.History, {
                                        time = os.date("%H:%M:%S"),
                                        pet = pet.displayName, uuid = uuid,
                                        mutation = m, isTarget = isTarget,
                                    })
                                    if updateHistory then updateHistory() end
                                    if updateProgressPanel then updateProgressPanel() end
                                    
                                    log("   🎉 DAPAT: " .. tostring(m) .. " (total: " .. State.Stats.Mutations .. ")")
                                    if isTarget then
                                        log("   🎯 TARGET: " .. pet.displayName .. " → " .. m)
                                        log("   🔒 LOCKED: " .. shortUUID(uuid))
                                    end
                                    
                                    sendWebhook(uuid, m, isTarget)
                                    
                                    if allPetsTargetHit() then
                                        log("🏆🏆🏆 SEMUA PET TARGET TERCAPAI! 🏆🏆🏆")
                                        sendWebhook(uuid, m, isTarget, true)
                                        pcall(function()
                                            game:GetService("StarterGui"):SetCore("SendNotification", {
                                                Title = "🏆 SEMUA PET TARGET TERCAPAI!",
                                                Text = #State.PetQueueOrder .. " pet udah dapat mutasi target!",
                                                Duration = 15,
                                            })
                                        end)
                                        return "ALL_DONE"
                                    end
                                    
                                    log("   ⏳ Nunggu mesin clear...")
                                    local clearWait = 0
                                    while clearWait < 30 do
                                        if not State.Running then return false end
                                        if getMachineState() == "Idle" then
                                            log("   ✅ Mesin clear")
                                            break
                                        end
                                        task.wait(3)
                                        clearWait += 3
                                    end
                                    
                                    task.wait(DELAY_AFTER_COLLECT)
                                end
                            else
                                State.Stats.Fails += 1
                            end
                        end
                    end
                end
            end
        end
    end
    log("✅ FASE 2 SELESAI")
    return "DONE"
end

-- ============================================================
-- MAIN
-- ============================================================
local function runBatchCycle()
    if not State.Running then return end
    if allPetsTargetHit() then
        log("🏆 Semua pet udah target! Stop.")
        stopLoop("Semua target tercapai")
        return
    end
    
    State.CurrentBatch += 1
    log("")
    log("╔══════════════════════════════════════╗")
    log("║  BATCH #" .. State.CurrentBatch .. " (" .. #State.PetQueueOrder .. " pet)")
    log("╚══════════════════════════════════════╝")
    
    State.CurrentPhase = "age"
    if updateUI then updateUI() end
    if not doAgePhase() then return end
    if not State.Running then return end
    
    State.CurrentPhase = "insert"
    if updateUI then updateUI() end
    local result = doInsertPhase()
    
    if result == "ALL_DONE" then stopLoop("Semua target tercapai"); return end
    
    log("✅ BATCH #" .. State.CurrentBatch .. " SELESAI")
    log("")
    task.wait(DELAY_STEP)
end

function startLoop()
    if State.Running then return end
    State.Running = true
    State.CurrentBatch = 0
    State.Stats.StartTime = tick()
    for _, uuid in ipairs(State.PetQueueOrder) do
        local p = State.PetQueue[uuid]
        if p then
            p.mutations = 0; p.targetHit = false; p.locked = false; p.lastMutation = nil
        end
    end
    log("🔒 Queue LOCKED: " .. #State.PetQueueOrder .. " pet")
    task.spawn(function()
        while State.Running do
            local ok, err = pcall(runBatchCycle)
            if not ok then
                State.Stats.Fails += 1
                log("❌ Error: " .. tostring(err))
                task.wait(5)
            end
            if not State.Running then break end
            task.wait(DELAY_STEP)
        end
        State.Running = false
        log("🔓 Queue UNLOCKED")
        if updateUI then updateUI() end
    end)
end

function stopLoop(reason)
    State.Running = false
    log("⏹️ Stop" .. (reason and (" (" .. reason .. ")") or ""))
end

-- ============================================================
-- HISTORY (global function)
-- ============================================================
function updateHistory()
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
        row.Size = UDim2.new(1, 0, 0, 18)
        row.BackgroundColor3 = entry.isTarget and Color3.fromRGB(60, 90, 50) or Color3.fromRGB(40, 40, 55)
        row.BorderSizePixel = 0
        row.LayoutOrder = 1000 - idx
        row.Parent = HistoryContent
        local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 3); rc.Parent = row
        local t = Instance.new("TextLabel")
        t.Size = UDim2.new(0.15, 0, 1, 0); t.Position = UDim2.new(0, 4, 0, 0)
        t.BackgroundTransparency = 1; t.Text = entry.time or "?"
        t.TextColor3 = Color3.fromRGB(150, 150, 170); t.TextSize = 9
        t.Font = Enum.Font.Code; t.TextXAlignment = Enum.TextXAlignment.Left
        t.Parent = row
        local p = Instance.new("TextLabel")
        p.Size = UDim2.new(0.4, 0, 1, 0); p.Position = UDim2.new(0.15, 0, 0, 0)
        p.BackgroundTransparency = 1
        p.Text = tostring(entry.pet or "?") .. " (" .. shortUUID(entry.uuid) .. ")"
        p.TextColor3 = Color3.fromRGB(180, 180, 220); p.TextSize = 9
        p.Font = Enum.Font.Gotham; p.TextXAlignment = Enum.TextXAlignment.Left
        p.TextTruncate = Enum.TextTruncate.AtEnd
        p.Parent = row
        local m = Instance.new("TextLabel")
        m.Size = UDim2.new(0.45, -4, 1, 0); m.Position = UDim2.new(0.55, 0, 0, 0)
        m.BackgroundTransparency = 1; m.Text = tostring(entry.mutation or "?") .. (entry.isTarget and " 🎯" or "")
        m.TextColor3 = entry.isTarget and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(220, 220, 240)
        m.TextSize = 9; m.Font = Enum.Font.GothamBold
        m.TextXAlignment = Enum.TextXAlignment.Right
        m.TextTruncate = Enum.TextTruncate.AtEnd
        m.Parent = row
    end
end

-- ============================================================
-- PROGRESS PANEL (global function)
-- ============================================================
function updateProgressPanel()
    if not ProgressContent then return end
    for _, c in ipairs(ProgressContent:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    if #State.PetQueueOrder == 0 then
        local e = Instance.new("TextLabel")
        e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
        e.Text = "Belum ada pet di queue"; e.TextColor3 = Color3.fromRGB(120,120,140)
        e.TextSize = 10; e.Font = Enum.Font.Gotham
        e.Parent = ProgressContent
        return
    end
    for i, uuid in ipairs(State.PetQueueOrder) do
        local pet = State.PetQueue[uuid]
        if pet then
            local isCurrent = (uuid == State.CurrentPetId and State.Running and not pet.targetHit)
            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, 0, 0, 26)
            if pet.targetHit then row.BackgroundColor3 = Color3.fromRGB(45, 75, 45)
            elseif isCurrent then row.BackgroundColor3 = Color3.fromRGB(80, 60, 120)
            else row.BackgroundColor3 = Color3.fromRGB(40, 40, 55) end
            row.BorderSizePixel = 0
            row.LayoutOrder = i
            row.Parent = ProgressContent
            local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 4); rc.Parent = row
            
            local idx = Instance.new("TextLabel")
            idx.Size = UDim2.new(0, 22, 1, 0); idx.Position = UDim2.new(0, 2, 0, 0)
            idx.BackgroundTransparency = 1
            if pet.targetHit then idx.Text = "✅"
            elseif isCurrent then idx.Text = "▶"
            else idx.Text = "⏳" end
            idx.TextColor3 = pet.targetHit and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(200, 200, 220)
            idx.TextSize = 11; idx.Font = Enum.Font.GothamBold
            idx.Parent = row
            
            local nameContainer = Instance.new("Frame")
            nameContainer.Size = UDim2.new(0.55, 0, 1, 0); nameContainer.Position = UDim2.new(0, 26, 0, 0)
            nameContainer.BackgroundTransparency = 1
            nameContainer.Parent = row
            
            local name = Instance.new("TextLabel")
            name.Size = UDim2.new(1, 0, 0.5, 0); name.Position = UDim2.new(0, 0, 0, 2)
            name.BackgroundTransparency = 1
            name.Text = pet.displayName
            name.TextColor3 = pet.targetHit and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(220, 220, 240)
            name.TextSize = 10; name.Font = Enum.Font.GothamBold
            name.TextXAlignment = Enum.TextXAlignment.Left
            name.TextTruncate = Enum.TextTruncate.AtEnd
            name.Parent = nameContainer
            
            local uuidLbl = Instance.new("TextLabel")
            uuidLbl.Size = UDim2.new(1, 0, 0.5, 0); uuidLbl.Position = UDim2.new(0, 0, 0.5, 0)
            uuidLbl.BackgroundTransparency = 1
            uuidLbl.Text = shortUUID(uuid)
            uuidLbl.TextColor3 = Color3.fromRGB(120, 120, 150)
            uuidLbl.TextSize = 8; uuidLbl.Font = Enum.Font.Code
            uuidLbl.TextXAlignment = Enum.TextXAlignment.Left
            uuidLbl.Parent = nameContainer
            
            local info = Instance.new("TextLabel")
            info.Size = UDim2.new(0.4, -4, 1, 0); info.Position = UDim2.new(0.58, 0, 0, 0)
            info.BackgroundTransparency = 1
            if pet.targetHit then
                info.Text = "🔒 " .. (pet.lastMutation or "?")
                info.TextColor3 = Color3.fromRGB(150, 255, 150)
            else
                info.Text = string.format("%d mut | %s", pet.mutations or 0, pet.lastMutation or "—")
                info.TextColor3 = Color3.fromRGB(180, 150, 220)
            end
            info.TextSize = 9; info.Font = Enum.Font.Code
            info.TextXAlignment = Enum.TextXAlignment.Right
            info.TextTruncate = Enum.TextTruncate.AtEnd
            info.Parent = row
        end
    end
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
MainFrame.Size = UDim2.new(0, 820, 0, 560)
MainFrame.Position = UDim2.new(0.5, -410, 0.5, -280)
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
Title.Text = "🧬 Auto Pet Mutation v12.7 — Sequential Fix"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 14
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

local LeftCol = Instance.new("Frame")
LeftCol.Size = UDim2.new(0, 400, 1, -46)
LeftCol.Position = UDim2.new(0, 10, 0, 40)
LeftCol.BackgroundTransparency = 1
LeftCol.ClipsDescendants = true
LeftCol.Parent = MainFrame

local RightCol = Instance.new("Frame")
RightCol.Size = UDim2.new(0, 390, 1, -46)
RightCol.Position = UDim2.new(0, 420, 0, 40)
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
    box.TextTruncate = Enum.TextTruncate.AtEnd
    box.Parent = parent
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = box
    return box
end

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
StatsLabel.Text = "Batch: 0\nMut: 0 | Gear: 0"
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

makeLabel(LeftCol, "🐾 Pilih Pet (UUID unik):", 70)

local ScanBtn = Instance.new("TextButton")
ScanBtn.Size = UDim2.new(0.35, -2, 0, 24)
ScanBtn.Position = UDim2.new(0, 0, 0, 86)
ScanBtn.BackgroundColor3 = Color3.fromRGB(80, 60, 180)
ScanBtn.BorderSizePixel = 0
ScanBtn.Text = "🔍 Scan"
ScanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ScanBtn.TextSize = 10
ScanBtn.Font = Enum.Font.GothamBold
ScanBtn.Parent = LeftCol
local ScC = Instance.new("UICorner"); ScC.CornerRadius = UDim.new(0, 6); ScC.Parent = ScanBtn

local RefreshBtn = Instance.new("TextButton")
RefreshBtn.Size = UDim2.new(0.15, -2, 0, 24)
RefreshBtn.Position = UDim2.new(0.35, 2, 0, 86)
RefreshBtn.BackgroundColor3 = Color3.fromRGB(50, 70, 100)
RefreshBtn.BorderSizePixel = 0
RefreshBtn.Text = "🔄"
RefreshBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
RefreshBtn.TextSize = 12
RefreshBtn.Font = Enum.Font.GothamBold
RefreshBtn.Parent = LeftCol
local RC = Instance.new("UICorner"); RC.CornerRadius = UDim.new(0, 6); RC.Parent = RefreshBtn

local SelectAllBtn = Instance.new("TextButton")
SelectAllBtn.Size = UDim2.new(0.22, -2, 0, 24)
SelectAllBtn.Position = UDim2.new(0.5, 0, 0, 86)
SelectAllBtn.BackgroundColor3 = Color3.fromRGB(60, 100, 60)
SelectAllBtn.BorderSizePixel = 0
SelectAllBtn.Text = "✅ All"
SelectAllBtn.TextColor3 = Color3.fromRGB(200, 255, 200)
SelectAllBtn.TextSize = 10
SelectAllBtn.Font = Enum.Font.GothamBold
SelectAllBtn.Parent = LeftCol
local SAC = Instance.new("UICorner"); SAC.CornerRadius = UDim.new(0, 6); SAC.Parent = SelectAllBtn

local ClearAllBtn = Instance.new("TextButton")
ClearAllBtn.Size = UDim2.new(0.26, 0, 0, 24)
ClearAllBtn.Position = UDim2.new(0.74, 0, 0, 86)
ClearAllBtn.BackgroundColor3 = Color3.fromRGB(100, 50, 50)
ClearAllBtn.BorderSizePixel = 0
ClearAllBtn.Text = "🗑️ Clear"
ClearAllBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
ClearAllBtn.TextSize = 10
ClearAllBtn.Font = Enum.Font.GothamBold
ClearAllBtn.Parent = LeftCol
local CAC = Instance.new("UICorner"); CAC.CornerRadius = UDim.new(0, 6); CAC.Parent = ClearAllBtn

local PetListFrame = Instance.new("ScrollingFrame")
PetListFrame.Size = UDim2.new(1, 0, 0, 160)
PetListFrame.Position = UDim2.new(0, 0, 0, 114)
PetListFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
PetListFrame.BorderSizePixel = 0
PetListFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
PetListFrame.ScrollBarThickness = 5
PetListFrame.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
PetListFrame.Parent = LeftCol
local PLC = Instance.new("UICorner"); PLC.CornerRadius = UDim.new(0, 6); PLC.Parent = PetListFrame
local PLS = Instance.new("UIStroke"); PLS.Color = Color3.fromRGB(80, 60, 120); PLS.Thickness = 1; PLS.Parent = PetListFrame

local PetListLayout = Instance.new("UIListLayout")
PetListLayout.Padding = UDim.new(0, 2); PetListLayout.SortOrder = Enum.SortOrder.LayoutOrder
PetListLayout.Parent = PetListFrame

local PetListPadding = Instance.new("UIPadding")
PetListPadding.PaddingTop = UDim.new(0, 4); PetListPadding.PaddingLeft = UDim.new(0, 4)
PetListPadding.PaddingRight = UDim.new(0, 4); PetListPadding.PaddingBottom = UDim.new(0, 4)
PetListPadding.Parent = PetListFrame

makeLabel(LeftCol, "🎯 Selected Queue:", 282)
local SelectedInfo = Instance.new("TextLabel")
SelectedInfo.Size = UDim2.new(1, 0, 0, 40)
SelectedInfo.Position = UDim2.new(0, 0, 0, 298)
SelectedInfo.BackgroundColor3 = Color3.fromRGB(30, 40, 30)
SelectedInfo.BorderSizePixel = 0
SelectedInfo.Text = "Belum ada pet dipilih"
SelectedInfo.TextColor3 = Color3.fromRGB(150, 230, 150)
SelectedInfo.TextSize = 10
SelectedInfo.Font = Enum.Font.Code
SelectedInfo.TextXAlignment = Enum.TextXAlignment.Left
SelectedInfo.TextYAlignment = Enum.TextYAlignment.Top
SelectedInfo.TextWrapped = true
SelectedInfo.Parent = LeftCol
local SIC = Instance.new("UICorner"); SIC.CornerRadius = UDim.new(0, 4); SIC.Parent = SelectedInfo

makeLabel(LeftCol, "🔧 Gear Name:", 346)
local GearNameBox = makeInput(LeftCol, "DiamondCookie", DEFAULT_GEAR_NAME, 362, 0, 0.6, 24, 10)

makeLabel(LeftCol, "📊 MAX_AGE:", 346, 0.62)
local AgeBox = Instance.new("TextLabel")
AgeBox.Size = UDim2.new(0.38, 0, 0, 24)
AgeBox.Position = UDim2.new(0.62, 0, 0, 362)
AgeBox.BackgroundColor3 = Color3.fromRGB(35, 45, 35)
AgeBox.BorderSizePixel = 0
AgeBox.Text = tostring(MAX_AGE or 50)
AgeBox.TextColor3 = Color3.fromRGB(150, 230, 150)
AgeBox.TextSize = 11
AgeBox.Font = Enum.Font.GothamBold
AgeBox.Parent = LeftCol
local AGC = Instance.new("UICorner"); AGC.CornerRadius = UDim.new(0, 4); AGC.Parent = AgeBox

local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(1, 0, 0, 38)
ToggleBtn.Position = UDim2.new(0, 0, 1, -38)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(120, 70, 200)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Text = "▶  START BATCH MUTATION"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 13
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = LeftCol
local TgC = Instance.new("UICorner"); TgC.CornerRadius = UDim.new(0, 8); TgC.Parent = ToggleBtn

local AutoDetectBtn = Instance.new("TextButton")
AutoDetectBtn.Size = UDim2.new(0.32, -2, 0, 22)
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
WebhookToggleBtn.Size = UDim2.new(0.32, -2, 0, 22)
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
WebhookOnlyTargetBtn.Size = UDim2.new(0.32, -2, 0, 22)
WebhookOnlyTargetBtn.Position = UDim2.new(0.68, 0, 0, 0)
WebhookOnlyTargetBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
WebhookOnlyTargetBtn.BorderSizePixel = 0
WebhookOnlyTargetBtn.Text = "🎯 Only: OFF"
WebhookOnlyTargetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookOnlyTargetBtn.TextSize = 10
WebhookOnlyTargetBtn.Font = Enum.Font.GothamBold
WebhookOnlyTargetBtn.Parent = RightCol
local WOC = Instance.new("UICorner"); WOC.CornerRadius = UDim.new(0, 4); WOC.Parent = WebhookOnlyTargetBtn

makeLabel(RightCol, "🔗 Webhook URL:", 26)
local WebhookBox = makeInput(RightCol, "https://discord.com/api/webhooks/...", "", 42, 0, 1, 22, 9)

makeLabel(RightCol, "📢 Mention:", 70)
local MentionBox = makeInput(RightCol, "<@123>", "", 86, 0, 0.6, 22, 10)

local TestWebhookBtn = Instance.new("TextButton")
TestWebhookBtn.Size = UDim2.new(0.38, -2, 0, 22)
TestWebhookBtn.Position = UDim2.new(0.62, 2, 0, 86)
TestWebhookBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
TestWebhookBtn.BorderSizePixel = 0
TestWebhookBtn.Text = "📤 Test"
TestWebhookBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
TestWebhookBtn.TextSize = 10
TestWebhookBtn.Font = Enum.Font.GothamBold
TestWebhookBtn.Parent = RightCol
local TWC = Instance.new("UICorner"); TWC.CornerRadius = UDim.new(0, 4); TWC.Parent = TestWebhookBtn

makeLabel(RightCol, "🎯 Target Mutation:", 114)
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size = UDim2.new(1, 0, 0, 60)
ScrollFrame.Position = UDim2.new(0, 0, 0, 130)
ScrollFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
ScrollFrame.BorderSizePixel = 0
ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
ScrollFrame.ScrollBarThickness = 4
ScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
ScrollFrame.Parent = RightCol
local SFC = Instance.new("UICorner"); SFC.CornerRadius = UDim.new(0, 6); SFC.Parent = ScrollFrame
local SFSt = Instance.new("UIStroke"); SFSt.Color = Color3.fromRGB(80, 60, 120); SFSt.Thickness = 1; SFSt.Parent = ScrollFrame

local ScrollLayout = Instance.new("UIListLayout")
ScrollLayout.Padding = UDim.new(0, 2); ScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
ScrollLayout.Parent = ScrollFrame

local ScrollPadding = Instance.new("UIPadding")
ScrollPadding.PaddingTop = UDim.new(0, 3); ScrollPadding.PaddingLeft = UDim.new(0, 4)
ScrollPadding.PaddingRight = UDim.new(0, 4); ScrollPadding.PaddingBottom = UDim.new(0, 3)
ScrollPadding.Parent = ScrollFrame

local mutationList = getMutationList()
for i, mutName in ipairs(mutationList) do
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 18)
    row.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    row.BorderSizePixel = 0
    row.LayoutOrder = i
    row.Parent = ScrollFrame
    local rC = Instance.new("UICorner"); rC.CornerRadius = UDim.new(0, 3); rC.Parent = row

    local checkbox = Instance.new("TextButton")
    checkbox.Name = "Checkbox"
    checkbox.Size = UDim2.new(0, 14, 0, 14)
    checkbox.Position = UDim2.new(0, 2, 0.5, -7)
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
    checkmark.TextSize = 11
    checkmark.Font = Enum.Font.GothamBold
    checkmark.Parent = checkbox

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 1, 0)
    lbl.Position = UDim2.new(0, 20, 0, 0)
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
    ScrollFrame.CanvasSize = UDim2.new(0, 0, 0, ScrollLayout.AbsoluteContentSize.Y + 6)
end)

makeLabel(RightCol, "📊 Batch Progress:", 198)
local ProgressFrame = Instance.new("Frame")
ProgressFrame.Size = UDim2.new(1, 0, 0, 130)
ProgressFrame.Position = UDim2.new(0, 0, 0, 214)
ProgressFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
ProgressFrame.BorderSizePixel = 0
ProgressFrame.Parent = RightCol
local PrC = Instance.new("UICorner"); PrC.CornerRadius = UDim.new(0, 6); PrC.Parent = ProgressFrame
local PrS = Instance.new("UIStroke"); PrS.Color = Color3.fromRGB(100, 70, 150); PrS.Thickness = 1; PrS.Parent = ProgressFrame

local ProgressScroll = Instance.new("ScrollingFrame")
ProgressScroll.Size = UDim2.new(1, -8, 1, -8)
ProgressScroll.Position = UDim2.new(0, 4, 0, 4)
ProgressScroll.BackgroundTransparency = 1
ProgressScroll.BorderSizePixel = 0
ProgressScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
ProgressScroll.ScrollBarThickness = 4
ProgressScroll.ScrollBarImageColor3 = Color3.fromRGB(120, 80, 200)
ProgressScroll.Parent = ProgressFrame

local ProgressContent = Instance.new("Frame")
ProgressContent.Size = UDim2.new(1, 0, 0, 0)
ProgressContent.BackgroundTransparency = 1
ProgressContent.Parent = ProgressScroll

local ProgressLayout = Instance.new("UIListLayout")
ProgressLayout.Padding = UDim.new(0, 2); ProgressLayout.SortOrder = Enum.SortOrder.LayoutOrder
ProgressLayout.Parent = ProgressContent

ProgressLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    ProgressScroll.CanvasSize = UDim2.new(0, 0, 0, ProgressLayout.AbsoluteContentSize.Y + 6)
end)

makeLabel(RightCol, "📜 History:", 350)
local HistoryBg = Instance.new("Frame")
HistoryBg.Size = UDim2.new(1, 0, 1, -398)
HistoryBg.Position = UDim2.new(0, 0, 0, 366)
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
HistoryLayout.Padding = UDim.new(0, 2); HistoryLayout.SortOrder = Enum.SortOrder.LayoutOrder
HistoryLayout.Parent = HistoryContent

HistoryLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    HistoryScroll.CanvasSize = UDim2.new(0, 0, 0, HistoryLayout.AbsoluteContentSize.Y + 6)
end)

local LogBg = Instance.new("Frame")
LogBg.Size = UDim2.new(1, 0, 0, 70)
LogBg.Position = UDim2.new(0, 0, 1, -70)
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
LogLabel.TextSize = 9
LogLabel.Font = Enum.Font.Code
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.Parent = LogBg

local function updateMachineTimer()
    while ScreenGui.Parent do
        if modulesReady() then
            local state, rem = getMachineState()
            if state == "Idle" then
                MachineStateLabel.Text = "⏱️ IDLE"
                MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
                MachineTimerLabel.Text = "00:00"
            elseif state == "InProgress" then
                MachineStateLabel.Text = "⚙️ MUTATING"
                MachineStateLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
                MachineTimerLabel.Text = formatTime(rem)
                MachineTimerLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
            elseif state == "Ready" then
                MachineStateLabel.Text = "✅ READY!"
                MachineStateLabel.TextColor3 = Color3.fromRGB(120, 230, 120)
                MachineTimerLabel.Text = "00:00"
            end
        end
        task.wait(0.5)
    end
end
task.spawn(updateMachineTimer)

function updateUI()
    if State.Running then
        StatusLabel.Text = "Status: RUNNING (Batch #" .. State.CurrentBatch .. " | " .. State.CurrentPhase .. ")"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 150, 255)
        ToggleBtn.Text = "⏹  STOP"
        TweenService:Create(ToggleBtn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(200, 60, 60)}):Play()
    else
        StatusLabel.Text = "Status: IDLE"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
        ToggleBtn.Text = "▶  START BATCH MUTATION"
        TweenService:Create(ToggleBtn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(120, 70, 200)}):Play()
    end
    AutoDetectBtn.Text = "🤖 Auto: " .. (State.AutoDetect and "ON" or "OFF")
    AutoDetectBtn.BackgroundColor3 = State.AutoDetect and Color3.fromRGB(60, 130, 90) or Color3.fromRGB(120, 70, 70)
    WebhookToggleBtn.Text = "🔔 Web: " .. (State.WebhookEnabled and "ON" or "OFF")
    WebhookToggleBtn.BackgroundColor3 = State.WebhookEnabled and Color3.fromRGB(60, 130, 90) or Color3.fromRGB(120, 70, 70)
    WebhookOnlyTargetBtn.Text = "🎯 Only: " .. (State.WebhookOnlyTarget and "ON" or "OFF")
    WebhookOnlyTargetBtn.BackgroundColor3 = State.WebhookOnlyTarget and Color3.fromRGB(120, 80, 180) or Color3.fromRGB(60, 60, 80)
end

function updateStats()
    while ScreenGui.Parent do
        StatsLabel.Text = string.format("Batch: %d\nMut: %d | Gear: %d", 
            State.CurrentBatch, State.Stats.Mutations, State.Stats.GearUsed)
        task.wait(1)
    end
end
task.spawn(updateStats)

local petSelection = {}

local function updateSelectedInfo()
    State.PetQueue = {}
    State.PetQueueOrder = {}
    local names = {}
    for _, pet in ipairs(State.PetList) do
        if petSelection[pet.id] then
            State.PetQueue[pet.id] = {
                id = pet.id, displayName = pet.displayName,
                mutation = pet.mutation, mutationCount = pet.mutationCount,
                mutations = 0, targetHit = false, locked = false,
            }
            table.insert(State.PetQueueOrder, pet.id)
            table.insert(names, pet.displayName .. " (" .. shortUUID(pet.id) .. ")")
        end
    end
    if #names == 0 then
        SelectedInfo.Text = "Belum ada pet dipilih"
        SelectedInfo.TextColor3 = Color3.fromRGB(150, 150, 170)
    else
        SelectedInfo.Text = "✅ " .. #names .. " pet:\n" .. table.concat(names, "\n")
        SelectedInfo.TextColor3 = Color3.fromRGB(150, 230, 150)
    end
    updateProgressPanel()
end

local function refreshPetList(pets)
    for _, c in ipairs(PetListFrame:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    if #pets == 0 then
        local e = Instance.new("TextLabel")
        e.Size = UDim2.new(1, 0, 0, 24); e.BackgroundTransparency = 1
        e.Text = "Belum ada pet — klik Scan"; e.TextColor3 = Color3.fromRGB(150, 150, 170)
        e.TextSize = 10; e.Font = Enum.Font.Gotham
        e.Parent = PetListFrame
        return
    end
    for i, pet in ipairs(pets) do
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, 0, 0, 32)
        row.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
        row.BorderSizePixel = 0
        row.Text = ""
        row.LayoutOrder = i
        row.Parent = PetListFrame
        local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 4); rc.Parent = row
        
        local cb = Instance.new("TextButton")
        cb.Name = "Checkbox"
        cb.Size = UDim2.new(0, 16, 0, 16)
        cb.Position = UDim2.new(0, 3, 0, 8)
        cb.BackgroundColor3 = petSelection[pet.id] and Color3.fromRGB(120, 80, 200) or Color3.fromRGB(60, 60, 80)
        cb.BorderSizePixel = 0
        cb.Text = ""
        cb.Parent = row
        local cbc = Instance.new("UICorner"); cbc.CornerRadius = UDim.new(0, 3); cbc.Parent = cb
        
        local cm = Instance.new("TextLabel")
        cm.Size = UDim2.fromScale(1, 1); cm.BackgroundTransparency = 1
        cm.Text = petSelection[pet.id] and "✓" or ""
        cm.TextColor3 = Color3.fromRGB(255, 255, 255)
        cm.TextSize = 12; cm.Font = Enum.Font.GothamBold
        cm.Parent = cb
        
        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(0.6, 0, 0, 16); name.Position = UDim2.new(0, 24, 0, 2)
        name.BackgroundTransparency = 1
        name.Text = pet.displayName
        name.TextColor3 = pet.mutation and Color3.fromRGB(255, 220, 100) or Color3.fromRGB(220, 220, 240)
        name.TextSize = 10; name.Font = Enum.Font.GothamBold
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.TextTruncate = Enum.TextTruncate.AtEnd
        name.Parent = row
        
        local uuidLbl = Instance.new("TextLabel")
        uuidLbl.Size = UDim2.new(0.6, 0, 0, 12); uuidLbl.Position = UDim2.new(0, 24, 0, 18)
        uuidLbl.BackgroundTransparency = 1
        uuidLbl.Text = shortUUID(pet.id)
        uuidLbl.TextColor3 = Color3.fromRGB(120, 120, 150)
        uuidLbl.TextSize = 8; uuidLbl.Font = Enum.Font.Code
        uuidLbl.TextXAlignment = Enum.TextXAlignment.Left
        uuidLbl.Parent = row
        
        local mut = Instance.new("TextLabel")
        mut.Size = UDim2.new(0.4, -6, 1, 0); mut.Position = UDim2.new(0.6, 0, 0, 0)
        mut.BackgroundTransparency = 1
        mut.Text = (pet.mutation or "N") .. " x" .. (pet.mutationCount or 0)
        mut.TextColor3 = Color3.fromRGB(180, 150, 220)
        mut.TextSize = 9; mut.Font = Enum.Font.Code
        mut.TextXAlignment = Enum.TextXAlignment.Right
        mut.Parent = row
        
        local function toggle()
            if State.Running then log("⚠️ STOP dulu sebelum ubah selection!"); return end
            if petSelection[pet.id] then
                petSelection[pet.id] = nil
                cb.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
                cm.Text = ""
            else
                petSelection[pet.id] = true
                cb.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
                cm.Text = "✓"
            end
            updateSelectedInfo()
        end
        
        cb.MouseButton1Click:Connect(toggle)
        row.MouseButton1Click:Connect(toggle)
    end
    PetListFrame.CanvasSize = UDim2.new(0, 0, 0, #pets * 34 + 8)
end

local function doScan()
    if State.Running then log("⚠️ STOP dulu sebelum scan!"); return end
    log("🔍 Scan...")
    local pets = scanPets()
    State.PetList = pets
    log("   " .. #pets .. " pet unik (UUID-based)")
    refreshPetList(pets)
end

ScanBtn.MouseButton1Click:Connect(doScan)
RefreshBtn.MouseButton1Click:Connect(doScan)

SelectAllBtn.MouseButton1Click:Connect(function()
    if State.Running then log("⚠️ STOP dulu!"); return end
    for _, pet in ipairs(State.PetList) do petSelection[pet.id] = true end
    refreshPetList(State.PetList)
    updateSelectedInfo()
    log("✅ Select all (" .. #State.PetList .. " pet)")
end)

ClearAllBtn.MouseButton1Click:Connect(function()
    if State.Running then log("⚠️ STOP dulu!"); return end
    petSelection = {}
    refreshPetList(State.PetList)
    updateSelectedInfo()
    log("🗑️ Clear all")
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
    sendWebhook("test-uuid-1234", "TEST_MUTATION", true)
end)

ToggleBtn.MouseButton1Click:Connect(function()
    if State.Running then
        stopLoop("Manual stop")
    else
        if #State.PetQueueOrder == 0 then log("❌ Pilih pet dulu! Scan → centang pet"); return end
        if next(State.TargetMutations) == nil then log("❌ Pilih target mutation dulu!"); return end
        State.GearName = GearNameBox.Text ~= "" and GearNameBox.Text or DEFAULT_GEAR_NAME
        State.WebhookURL = WebhookBox.Text:gsub("%s", "")
        State.WebhookMention = MentionBox.Text
        State.Stats.Mutations = 0
        State.Stats.GearUsed = 0
        State.Stats.Fails = 0
        State.Stats.History = {}
        updateHistory()
        updateProgressPanel()
        log("🚀 START Batch — " .. #State.PetQueueOrder .. " pet")
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
updateProgressPanel()
updateSelectedInfo()

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then ToggleBtn:Activate() end
end)

log("✅ GUI loaded (v12.7 Sequential Fix).")
if inventoryStateModule then log("   ✅ inventory.state OK") else log("   ❌ inventory.state GAGAL") end
if getRequestFunction() then log("   ✅ HTTP OK") end
