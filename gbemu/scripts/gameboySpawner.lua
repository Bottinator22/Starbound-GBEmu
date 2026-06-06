require "/scripts/terra_base64.lua"

-- TODO: allow importing/exporting saves from items
function init()
    shared.gameboys = shared.gameboys or {}
    shared.gameboySaves = shared.gameboySaves or root.getConfiguration("gameboySaves") or {}
    message.setHandler("/createGB", function (_,l,name)
        if not l then return "no" end
        if not name or #name == 0 then
            return "Need a name."
        end
        if shared.gameboys[name] and world.entityExists(shared.gameboys[name]) then
            return "Gameboy vehicle with that name already exists."
        end
        local doff = 2.5
        local p = world.lineCollision(mcontroller.position(),{mcontroller.xPosition(),mcontroller.yPosition()-30},{"Block","Platform","Null","Slippery","Dynamic"}) or mcontroller.position()
        shared.gameboys[name] = world.spawnVehicle("compositerailplatform",{p[1],p[2]+doff},sb.jsonMerge(root.assetJson("/scripts/gameboyVehicleParams.json"),{gbName=name}))
        return "Spawned a gameboy vehicle."
    end)
    message.setHandler("/setGBROM", function (_,l,inp)
        if not l then return "no" end
        local first = true
        local name
        local path
        for v in string.gmatch(inp,"([^ ]+)") do
            if first then
                name = string.gsub(v, '%s+', '')
                first = false
            elseif path then
                path = path.." "..v
            else
                path = v
            end
        end
        if not path then
            return "Need a path."
        end
        path = string.gsub(path, '%s+', '')
        if not root.assetOrigin(path) then
            return "Can't find a rom under that path!"
        end
        local gb = shared.gameboys[name]
        if gb and world.entityExists(gb) then
            world.callScriptedEntity(gb, "loadROM", path)
        else
            return "Can't find a gameboy of that name!"
        end
    end)
    message.setHandler("/setGBROMNoReset", function (_,l,inp)
        if not l then return "no" end
        local first = true
        local name
        local path
        for v in string.gmatch(inp,"([^ ]+)") do
            if first then
                name = string.gsub(v, '%s+', '')
                first = false
            elseif path then
                path = path.." "..v
            else
                path = v
            end
        end
        if not path then
            return "Need a path."
        end
        path = string.gsub(path, '%s+', '')
        if not root.assetOrigin(path) then
            return "Can't find a rom under that path!"
        end
        local gb = shared.gameboys[name]
        if gb and world.entityExists(gb) then
            world.callScriptedEntity(gb, "loadROMNoReset", path)
        else
            return "Can't find a gameboy of that name!"
        end
    end)
    message.setHandler("/resetGB", function (_,l,name)
        if not l then return "no" end
        local gb = shared.gameboys[name]
        if gb and world.entityExists(gb) then
            world.callScriptedEntity(gb, "reset")
        else
            return "Can't find a gameboy of that name!"
        end
    end)
    message.setHandler("/dumpGBMem", function (_,l,name)
        if not l then return "no" end
        local gb = shared.gameboys[name]
        if gb and world.entityExists(gb) then
            world.callScriptedEntity(gb, "dumpMemory")
        else
            return "Can't find a gameboy of that name!"
        end
    end)
    message.setHandler("/setGBSpeed", function (_,l,inp)
        if not l then return "no" end
        local first = true
        local name
        local num
        for v in string.gmatch(inp,"([^ ]+)") do
            if first then
                name = string.gsub(v, '%s+', '')
                first = false
            else
                num = tonumber(v)
                break
            end
        end
        if not num then
            return "Need a timescale number."
        end
        local gb = shared.gameboys[name]
        if gb and world.entityExists(gb) then
            world.callScriptedEntity(gb, "setSpeed", num)
        else
            return "Can't find a gameboy of that name!"
        end
    end)
    message.setHandler("/importSaveFromFile", function (_,l,inp)
        if not l then return "no" end
        local first = true
        local name
        local path
        for v in string.gmatch(inp,"([^ ]+)") do
            if first then
                name = string.gsub(v, '%s+', '')
                first = false
            elseif path then
                path = path.." "..v
            else
                path = v
            end
        end
        if not path then
            return "Need a path."
        end
        path = string.gsub(path, '%s+', '')
        if not root.assetOrigin(path) then
            return "Can't find a save under that path!"
        end
        if not shared.gameboySaves[name] then
            return "Need a save to overwrite!"
        end
        local t = {}
        local save = root.assetData(path)
        for i=1,#save do
            t[i] = string.byte(save,i)
        end
        shared.gameboySaves[name].sram = octetsToBase64(t)
        return "Imported save."
    end)
    message.setHandler("/destroyGB", function (_,l,name)
        if not l then return "no" end
        local gb = shared.gameboys[name]
        if gb and world.entityExists(gb) then
            world.callScriptedEntity(gb, "saveAndDestroy")
            shared.gameboys[name] = nil
        else
            return "Can't find a gameboy of that name!"
        end
    end)
    script.setUpdateDelta(0)
end
function update(dt)
end
function uninit()
    root.setConfiguration("gameboySaves",shared.gameboySaves) -- I wish I had a better place to store this...
end
