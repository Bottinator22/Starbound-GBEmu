require "/scripts/gb/core.lua" 

local gb
local timescale
local cpuTester
local updateDelay = 0
function init()
    gb = createGB()
    message.setHandler("getFrame", function(_,_)
        return gb.getFrame()
    end)
    message.setHandler("load", function(_,_,rom,save)
        gb.loadRom(rom,save)
        gb.reset()
        cpuTester = gb.test()
    end)
    message.setHandler("loadNoReset", function(_,_,rom,save)
        gb.loadRom(rom,save)
    end)
    message.setHandler("reset", function(_,_)
        gb.reset()
    end)
    message.setHandler("getSave", function(_,_)
        return gb.getSave()
    end)
    message.setHandler("setSpeed", function(_,_,s)
        timescale = s
    end)
    message.setHandler("memRead",function(_,_,addr)
        return gb.memRead(addr)
    end)
    message.setHandler("memWrite",function(_,_,addr,v)
        gb.memWrite(addr,v)
    end)
    message.setHandler("memMultiRead",function(_,_,addrs)
        local out = {}
        for k,v in next, addrs do
            out[k] = gb.memRead(v)
        end
        return out
    end)
    message.setHandler("memReadRange",function(_,_,addrmi,addrma)
        local out = {}
        for v=addrmi,addrma do
            table.insert(out,gb.memRead(v))
        end
        return out
    end)
    message.setHandler("dumpMem",function(_,_)
        local out = ""
        for i=0,0xfff0,0x10 do
            out = out..string.format("\n%04x: %02x %02x %02x %02x %02x %02x %02x %02x | %02x %02x %02x %02x %02x %02x %02x %02x",i,
                gb.memRead(i  ),gb.memRead(i+1),gb.memRead(i+2),gb.memRead(i+3),gb.memRead(i+4),gb.memRead(i+5),gb.memRead(i+6),gb.memRead(i+7),
                gb.memRead(i+8),gb.memRead(i+9),gb.memRead(i+10),gb.memRead(i+11),gb.memRead(i+12),gb.memRead(i+13),gb.memRead(i+14),gb.memRead(i+15)
            )
        end
        sb.logInfo(out)
    end)
    message.setHandler("setInput",function(_,_,i)
        gb.setInput(i)
    end)
    script.setUpdateDelta(1)
end
function update()
    if not cpuTester then
        updateDelay = updateDelay - 1
        if updateDelay <= 0 then
            gb.update(timescale)
            gb.debug()
        end
    else
        if not coroutine.resume(cpuTester) then
            cpuTester = coroutine.create(function() while true do coroutine.yield() end end)
        end
    end
end
function uninit()
end
