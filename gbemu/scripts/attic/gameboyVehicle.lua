require "/scripts/gameboy.lua"

local screens = {"screen00","screen01","screen10","screen11"}
local gb
local gbName
local gameName
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
    for k,v in next, screens do
        animator.resetTransformationGroup(v)
        animator.scaleTransformationGroup(v,{1,-1},animator.partPoint(v,"center"))
    end
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
local t = 0
function update(dt)
    gb.update()
    if gb.dead() then
        vehicle.destroy()
        return
    end
    if gb.frame then
        animator.setGlobalTag("screen00",gb.frame[3])
        animator.setGlobalTag("screen01",gb.frame[1])
        animator.setGlobalTag("screen10",gb.frame[4])
        animator.setGlobalTag("screen11",gb.frame[2])
    end
    vehicle.setInteractive(not vehicle.entityLoungingIn("seat"))
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
    t = t + 1
    if t > 240 then
        if gameName then
            gb.save(saveName(gameName),applySave)
        end
        t = 0
    end
    sb.setLogMap("gbvehicle_saveTimer",string.format("%d",t))
end
function saveAndDestroy()
    t = -1000000
    if gameName then
        gb.save(saveName(gameName),applySave)
    end
    gb.destroy()
end
function applyDamage(damageRequest)
    return {}
end
