gameboy = {}
local storage
function gameboy.setStorage(newstorage)
    storage = newstorage
end

function gameboy.new(name)
    local gb = {
        thread=threads.create({
            name=name or "gameboy",
            scripts={
                main={"/scripts/gb/thread.lua"}
            },
            tickRate=60,
            instructionLimit=1000000000,
        }),
        frame=nil
    }
    local promises = {}
    function gb.save(key,onFinish)
        local promise = threads.sendMessage(gb.thread,"getSave")
        if key then
            table.insert(promises,{promise=promise,onFinish=function(save)
                storage[key] = save
                if onFinish then
                    onFinish(save)
                end
            end})
        end
        return promise
    end
    local waitingFrames = 0
    local destroyOnResolve = false
    local destroyed = false
    function gb.update()
        sb.setLogMap("gameboy_waitingFrames",string.format("%.0f",waitingFrames))
        sb.setLogMap("gameboy_promises",string.format("%.0f",#promises))
        local newPromises = {}
        for k,v in next, promises do
            if v.promise:finished() then
                if v.promise:succeeded() then
                    v.onFinish(v.promise:result())
                end
            else
                table.insert(newPromises,v)
            end
        end
        promises = newPromises
        if destroyOnResolve then
            if #promises == 0 then
                threads.stop(gb.thread)
                destroyed = true
            end
        elseif waitingFrames < 1 then
            waitingFrames = waitingFrames + 1
            table.insert(promises,{promise=threads.sendMessage(gb.thread,"getFrame"),onFinish=function(frame)
                waitingFrames = waitingFrames - 1
                gb.frame = frame
            end})
        end
    end
    function gb.setInput(i)
        threads.sendMessage(gb.thread,"setInput",i)
    end
    function gb.dumpMem()
        threads.sendMessage(gb.thread,"dumpMem")
    end
    function gb.setSpeed(ts)
        threads.sendMessage(gb.thread,"setSpeed",ts)
    end
    function gb.dead()
        return destroyed
    end
    function gb.destroy()
        destroyOnResolve = true
    end
    function gb.destroyNow()
        gb.destroy()
        while not destroyed do
            gb.update()
        end
    end
    function gb.readMem(addr)
        return threads.sendMessage(gb.thread,"memRead",addr)
    end
    function gb.readMemRange(from,to)
        return threads.sendMessage(gb.thread,"memReadRange",from,to)
    end
    function gb.readMemMulti(addrs)
        return threads.sendMessage(gb.thread,"memMultiRead",addrs)
    end
    function gb.writeMem(addr,v)
        threads.sendMessage(gb.thread,"memWrite",addr,v)
    end
    function gb.loadRom(rom,save)
        threads.sendMessage(gb.thread,"load",rom,save)
    end
    function gb.loadRomNoReset(rom,save)
        threads.sendMessage(gb.thread,"loadNoReset",rom,save)
    end
    function gb.reset()
        threads.sendMessage(gb.thread,"reset")
    end
    return gb
end
