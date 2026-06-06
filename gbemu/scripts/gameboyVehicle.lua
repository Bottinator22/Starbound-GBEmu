require "/scripts/gameboy.lua"
require "/scripts/vec2.lua"

local gb
local gbName
local gameName
local screen
function init()
    lastUsed = os.clock()
    vehicle.setInteractive(false)
    mcontroller.applyParameters(config.getParameter("movementSettings"))
    shared.gameboySaves = shared.gameboySaves or root.getConfiguration("gameboySaves") or {}
    gameboy.setStorage(shared.gameboySaves)
    gb = gameboy.new()
    gbName = config.getParameter("gbName","gameboy")
    if config.getParameter("rom") then
        loadROM(config.getParameter("rom"))
    end
    storage.screen = storage.screen or world.spawnMonster("mechmultidrone",mcontroller.position(),sb.jsonMerge(
        root.assetJson("/scripts/gameboyScreenParams.json"),
        {ownerId=entity.id()}
    ))
    screen = storage.screen
    storage.screenOffset = storage.screenOffset or {0,12}
end
local function saveName(gn)
    return string.format("%s_%s",gbName,gn)
end
function loadROM(r)
    gameName = string.match(r,"^.+/(.+)%.(.+)$")
    gb.loadRom(r,shared.gameboySaves[saveName(gameName)])
end
function loadROMNoReset(r)
    gameName = string.match(r,"^.+/(.+)%.(.+)$")
    gb.loadRomNoReset(r,shared.gameboySaves[saveName(gameName)])
end
function reset(r)
    gb.reset()
end
function applySave()
    root.setConfiguration("gameboySaves",shared.gameboySaves) -- I wish I had a better place to store this...
end
function dumpMemory()
    gb.dumpMem()
end
function setSpeed(ts)
    gb.setSpeed(ts)
end
local destroying = false
local t = 0
local lastReset = false
local lastForceSave = false
local doingWeirdStuff = false
function toggleWeirdStuff()
    doingWeirdStuff = not doingWeirdStuff
end
function update(dt)
    gb.update()
    if gb.dead() then
        vehicle.destroy()
        return
    end
    if destroying then
        return
    end
    if not world.entityExists(screen) then
        sb.logError("GB screen died!")
        saveAndDestroy()
        return
    end
    if gb.frame then
        world.callScriptedEntity(screen,"setFrame",gb.frame)
    end
    vehicle.setInteractive(not vehicle.entityLoungingIn("seat"))
    if vehicle.entityLoungingIn("seat") then
        animator.setAnimationState("seat","occupied")
    else
        animator.setAnimationState("seat","empty")
    end
    if vehicle.controlHeld("seat","altFire") then
        gb.setInput({false,false,false,false,false,false,false,false})
        local mov = {0,0}
        if vehicle.controlHeld("seat","up")    then mov[2] = mov[2] + 1 end
        if vehicle.controlHeld("seat","down")  then mov[2] = mov[2] - 1 end
        if vehicle.controlHeld("seat","right") then mov[1] = mov[1] + 1 end
        if vehicle.controlHeld("seat","left")  then mov[1] = mov[1] - 1 end
        storage.screenOffset = vec2.add(storage.screenOffset, vec2.mul(mov,dt*8))
        local resetK = vehicle.controlHeld("seat","jump") and vehicle.controlHeld("seat","special1") and vehicle.controlHeld("seat","special2")
        if resetK and not lastReset then
            -- manual reset
            gb.reset()
        end
        lastReset = resetK
        if vehicle.controlHeld("seat","special3") and not lastForceSave then
            -- force a save now
            t = 10000
        end
        lastForceSave = vehicle.controlHeld("seat","special3")
    else
        if doingWeirdStuff then
            local button = math.random(0,11)
            gb.setInput({
                0 <= button and button <= 1,
                2 <= button and button <= 3,
                4 <= button and button <= 5,
                6 <= button and button <= 7,
                button == 8,
                button == 9,
                button == 10,
                button == 11
            })
        else
            gb.setInput({
                vehicle.controlHeld("seat","down"),
                vehicle.controlHeld("seat","up"),
                vehicle.controlHeld("seat","left"),
                vehicle.controlHeld("seat","right"),
                vehicle.controlHeld("seat","jump"),
                vehicle.controlHeld("seat","special3"),
                vehicle.controlHeld("seat","special2"),
                vehicle.controlHeld("seat","special1")
            })
        end
        lastReset = true
        lastForceSave = true
    end
    t = t + 1
    if t > 240 then
        if gameName then
            gb.save(saveName(gameName),applySave)
        end
        t = 0
    end
    sb.setLogMap("gbvehicle_saveTimer",string.format("%d",t))
    world.callScriptedEntity(screen,"mcontroller.setPosition",vec2.add(mcontroller.position(),storage.screenOffset))
end
function saveAndDestroy()
    t = -1000000
    destroying = true
    if gameName then
        gb.save(saveName(gameName),applySave)
    end
    gb.destroy()
end
function applyDamage(damageRequest)
    return {}
end
function uninit()
    if not gb.dead() then
        if gameName then
            gb.save(saveName(gameName),applySave)
        end
        gb.destroyNow()
    end
end
