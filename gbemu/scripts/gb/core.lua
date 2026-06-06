require "/scripts/gb/utils.lua"
require "/scripts/gb/cpu.lua"
require "/scripts/gb/loader.lua"
require "/scripts/gb/ppu.lua"
require "/scripts/gb/apu.lua"

local stopped = false

local lastSB = 0
local asciiLog = ""
local function logLinkAscii(n)
    if n ~= 0 then
        local c = string.char(n)
        if c == "\n" then
            sb.logInfo(string.format("GB logged line: %s",asciiLog))
        else
            asciiLog = asciiLog..c
        end
    end
end
local function createBus()
    local bus = {}
    local testMem
    local busComp = {}
    local cpu = nil
    local rom = nil
    local ppu = nil
    local apu = nil
    local gb = nil
    local gbMode = -1
    local components = {
        nil, -- rom
        nil, -- cpu
        nil, -- ppu
        busComp, -- other
        nil,  -- sound
        nil -- gb
    }
    local ioPorts = {
        -- 0x00
        6,6,6,0,6,6,6,6,0,0,0,0,0,0,0,2,
        5,5,5,5,5,0,5,5,5,5,5,5,5,5,5,0,
        -- 0x20
        5,5,5,5,5,5,5,0,0,0,0,0,0,0,0,0,
        5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
        -- 0x40
        3,3,3,3,3,3,3,3,3,3,3,3,0,2,0,3,
        0,3,3,3,3,3,6,0,0,0,0,0,0,0,0,0,
        -- 0x60
        0,0,0,0,0,0,0,0,3,3,3,3,3,0,0,0,
        4,0,4,4,4,4,4,4,0,0,0,0,0,0,0,0,
        -- 0x80
    }
    local dma = false
    local busVal = 0x00
    local wram = {}
    for i=1,32768 do
        wram[i] = math.random(0,255)
    end
    local useTestMem = false
    local wramBank = 1
    local unknownFF72 = 0
    local unknownFF73 = 0
    local unknownFF74 = 0
    local unknownFF75 = 0
    function busComp.read(addr)
        if gbMode == 1 then
            if addr == 0xff70 then
                return 0xf8 | wramBank
            elseif addr == 0xff72 then
                return unknownFF72
            elseif addr == 0xff73 then
                return unknownFF73
            elseif addr == 0xff74 then
                return unknownFF74
            elseif addr == 0xff75 then
                return unknownFF75 | 0x8f
            elseif addr == 0xff76 then
                return 0x00
            elseif addr == 0xff77 then
                return 0x00
            end
        end
        return 0xff
    end
    function busComp.write(addr,v)
        if gbMode == 1 then
            if addr == 0xff70 then
                wramBank = v & 0x07
                if wramBank == 0 then
                    wramBank = 1
                end
            elseif addr == 0xff6c then
                unknownBitFF6C = v
            elseif addr == 0xff72 then
                unknownFF72 = v
            elseif addr == 0xff73 then
                unknownFF73 = v
            elseif addr == 0xff74 then
                unknownFF74 = v
            elseif addr == 0xff75 then
                unknownFF75 = v
            end
        end
    end
    local function _read(addr)
        if useTestMem then
            gb.logInfo(string.format("%04x->%02x",addr,testMem[addr+1]))
            return testMem[addr+1]
        end
        if addr & 0x8000 > 0 then
            -- RAM
            if dma and addr < 0xff80 then
                return 0xff
            end
            if addr < 0xa000 then
                -- VRAM
                return ppu.read(addr)
            elseif addr < 0xc000 then
                -- ExRAM
                if rom then
                    return rom.read(addr)
                else
                    return 0xff
                end
            elseif addr < 0xfe00 then
                -- WRAM and ECHO
                local i = addr & 0x1fff
                if i < 0x1000 then
                    -- bank 0
                    return wram[i+1]
                else
                    return wram[wramBank*4096+i+1]
                end
            elseif addr < 0xfea0 then
                -- OAM
                return ppu.read(addr)
            elseif addr < 0xff00 then
                -- unused/open bus
                return busVal
            elseif addr < 0xff80 then
                -- I/O ports
                local comp = ioPorts[(addr & 0x00ff) + 1]
                if components[comp] then
                    return components[comp].read(addr)
                else
                    return 0xff
                end
            elseif addr <= 0xffff then
                -- HRAM and Interrupt Enable Register (0xffff)
                return cpu.read(addr)
            end
        else
            if dma then
                return 0xff
            end
            -- ROM
            if rom then
                return rom.read(addr)
            else
                return 0xff
            end
        end
    end
    function bus.read(addr)
        busVal = _read(addr&0xffff)
        if busVal and (busVal < 0 or busVal > 0xff) then
            sb.logWarn(string.format("Value read at %04x is out of range! %.0f", addr, busVal))
            cpu.warn()
            rom.warn()
        end
        return busVal
    end
    function bus.write(_addr, v)
        local addr = _addr&0xffff
        busVal = v
        if busVal and (busVal < 0 or busVal > 0xff) then
            sb.logWarn(string.format("Value written at %04x is out of range! %.0f", addr, busVal))
            cpu.warn()
            rom.warn()
        end
        if useTestMem then
            gb.logInfo(string.format("%04x<-%02x",addr,v))
            testMem[addr+1] = v
            return
        end
        if addr & 0x8000 > 0 then
            -- RAM
            -- according to a test in BGB, OAM DMA only blocks reads, not writes
            -- TODO: is this a detail of BGB or accurate to hardware? I don't have a Gameboy to test with
            -- crashing Pokemon Blue and seeing if screen turns off is enough for that
            -- according to a Reddit post, reads/writes during OAM DMA corrupt what OAM DMA is reading/writing
            --if dma and addr < 0xff80 then
            --    return
            --end
            if addr < 0xa000 then
                -- VRAM
                ppu.write(addr,v)
            elseif addr < 0xc000 then
                -- ExRAM
                if rom then
                    rom.write(addr,v)
                end
            elseif addr < 0xfe00 then
                -- WRAM and ECHO
                local i = addr & 0x1fff
                if i < 0x1000 then
                    -- bank 0
                    wram[i+1] = v
                else
                    wram[wramBank*4096+i+1] = v
                end
            elseif addr < 0xfea0 then
                -- OAM
                ppu.write(addr,v)
            elseif addr < 0xff00 then
                -- unused/open bus
            elseif addr < 0xff80 then
                -- I/O ports
                local comp = ioPorts[(addr & 0x00ff) + 1]
                if components[comp] then
                    return components[comp].write(addr,v)
                end
            elseif addr <= 0xffff then
                -- HRAM and Interrupt Enable Register (0xffff)
                cpu.write(addr,v)
            end
        else
            --if dma then
            --    return
            --end
            -- ROM
            if rom then
                rom.write(addr,v)
            end
        end
    end
    function bus.useTestMemory(n)
        useTestMem = n
        if not testMem then
            testMem = {}
            for i=1,65536 do
                testMem[i] = math.random(0,255)
            end
        end
    end
    function bus.setRom(r)
        rom = r
        components[1] = r
    end
    function bus.setCpu(c)
        cpu = c
        components[2] = c
    end
    function bus.setPpu(r)
        ppu = r
        components[3] = r
    end
    function bus.setApu(s)
        apu = s
        components[5] = s
    end
    function bus.setGb(g)
        gb = g
        components[6] = g
    end
    function bus.setDMA(d)
        dma = d
    end
    function bus.setGBMode(t)
        gbMode = t
    end
    function bus.debug()
        sb.setLogMap("gbbus_dma",sb.print(dma))
    end
    function bus.test()
        rom.sramEnabled = true
        for i=0,65536 do
            local v = bus.read(i)
            if not v then
                sb.logWarn(string.format("%02x is not mapped", i))
                if i >= 0xff00 and i < 0xff80 then 
                    sb.logWarn((i & 0x00ff) + 1)
                    sb.logWarn(ioPorts[(i & 0x00ff) + 1])
                end
            end
        end
        rom.sramEnabled = false
    end
    return bus
end
function createGB()
    -- in order, d-pad (down,up,left,right) then buttons (start,select,b,a)
    local buttons = {false,false,false,false,false,false,false,false}
    local buttonMode = 0
    local gb = {}
    local bus = createBus()
    local rom
    local cpu = initCpu(bus,gb)
    local ppu = initPpu(bus,cpu)
    local apu = initApu()
    local gbMode = -1
    local testLogs = {}
    local testMode = false
    function gb.logInfo(t)
        if testMode then
            table.insert(testLogs,t)
        end
    end
    function gb.outputLogs()
        for k,v in next, testLogs do
            sb.logInfo(v)
        end
        testLogs = {}
    end
    function gb.clearLogs()
        testLogs = {}
    end
    function gb.setEnableTestLogs(o)
        testMode = o
    end
    bus.setCpu(cpu)
    bus.setPpu(ppu)
    bus.setApu(apu)
    bus.setGb(gb)
    function gb.isInputHeldAndSelected()
        local b1 = false
        local b2 = false
        local b3 = false
        local b4 = false
        if buttonMode & 0x01 == 0 then
            -- d-pad
            b1 = buttons[1]
            b2 = buttons[2]
            b3 = buttons[3]
            b4 = buttons[4]
        end
        if buttonMode & 0x02 == 0 then
            -- buttons
            b1 = b1 or buttons[5]
            b2 = b2 or buttons[6]
            b3 = b3 or buttons[7]
            b4 = b4 or buttons[8]
        end
        return b1 or b2 or b3 or b4
    end
    
    local divider = 0xab
    local timer = 0
    local timerModulo = 0
    local timerEnabled = false
    local timerClocks = {
        256,
        4,
        16,
        64
    }
    local timerMaxMcycles = 256
    local timerClockNum = 0
    local divMcycles = 0x33
    local timerMcycles = divMcycles*4
    
    function gb.resetDiv()
        divider = 0
    end
    
    function gb.read(addr)
        -- TODO: link cable
        if addr == 0xff00 then
            local b1 = false
            local b2 = false
            local b3 = false
            local b4 = false
            if buttonMode & 0x01 == 0 then
                -- d-pad
                b1 = buttons[1]
                b2 = buttons[2]
                b3 = buttons[3]
                b4 = buttons[4]
            end
            if buttonMode & 0x02 == 0 then
                -- buttons
                b1 = b1 or buttons[5]
                b2 = b2 or buttons[6]
                b3 = b3 or buttons[7]
                b4 = b4 or buttons[8]
            end
            return 
                (buttonMode << 4) | 0xc0
                | bit(not b1) << 3
                | bit(not b2) << 2
                | bit(not b3) << 1
                | bit(not b4)
        elseif addr == 0xff01 then
            -- TODO
            return 0xff
        elseif addr == 0xff02 then
            -- TODO
            return 0xff
        elseif addr == 0xff04 then
            return divider
        elseif addr == 0xff05 then
            return timer
        elseif addr == 0xff06 then
            return timerModulo
        elseif addr == 0xff07 then
            return
                  bit(timerEnabled) << 2
                | timerClockNum
        elseif addr == 0xff56 and gbMode == 1 then
            -- TODO: IR
            return 0x00
        end
        return 0xff
    end
    function gb.write(addr, v)
        if addr == 0xff00 then
            buttonMode = (v & 0x30) >> 4
        elseif addr == 0xff01 then
            -- TODO
            lastSB = v
        elseif addr == 0xff02 and ((v & 0x80) > 0) then
            -- TODO
            --logLinkAscii(lastSB)
            --cpu.interrupt(3)
        elseif addr == 0xff04 then
            gb.resetDiv()
        elseif addr == 0xff05 then
            timer = v
        elseif addr == 0xff06 then
            timerModulo = v
        elseif addr == 0xff07 then
            timerClockNum = v & 0x03
            timerEnabled = (v & 0x04) > 0
            timerMaxMcycles = timerClocks[timerClockNum+1]
            timerMcycles = math.floor(divMcycles*timerMaxMcycles/64)
        elseif addr == 0xff56 then
            -- TODO: IR
        end
    end
    gb.memRead = bus.read
    gb.memWrite = bus.write
    function gb.loadRom(r,save)
        rom = loader.loadAsMemComponent(r,save)
        bus.setRom(rom)
        -- note: loads without reset
    end
    function gb.reset()
        if not rom then
            sb.logWarn("Tried to reset with no ROM!")
            return
        end
        rom.reset()
        cpu.reset()
        ppu.reset()
        gbMode = rom.getGBMode()
        bus.setGBMode(gbMode)
        ppu.setGBMode(gbMode)
        cpu.setGBMode(gbMode)
    end
    local cpuTime = 0
    local ppuTime = 0
    local apuTime = 0
    local numCycles = 0
    local cyclesPerUpdate = 69905*0.25 --... apparently the original number here was 4x what it should be
    local ticks = 0
    local rfps = 0
    function gb.update(ts)
        if not rom then
            return
        end
        local time = os.clock()
        --cpuTime = 0
        --ppuTime = 0
        --apuTime = 0
        local it = 0
        local c = cyclesPerUpdate*(ts or 1)
        while numCycles < c and not stopped do
            it = it + 1
            --local s = os.clock()
            local l = ppu.vdmaActive and ppu.vdma() or cpu.update()
            --cpuTime = cpuTime + os.clock()-s
            if l == -1 then
                -- continue for a bit
                l = math.min(
                    cpu.untilHaltExit(),
                    ppu.waitingTime(numCycles),
                    c-numCycles,
                    cpu.speedMultConj()*(timerMaxMcycles-timerMcycles)
                )
                if l <= 0 then
                    l = 0.5
                end
                cpu.updateAutoHalt(l)
            end
            numCycles = numCycles + l
            --s = os.clock()
            ppu.update(numCycles,l)
            --ppuTime = ppuTime + os.clock()-s
            --s = os.clock()
            apu.update(numCycles,l)
            --apuTime = apuTime + os.clock()-s
            local tl = l
            if cpu.isDoubleSpeed() then
                tl = l * 2
            end
            divMcycles = divMcycles + tl
            timerMcycles = timerMcycles + tl
            if timerMcycles >= timerMaxMcycles then
                timerMcycles = timerMcycles - timerMaxMcycles
                if timerEnabled then
                    timer = timer + 1
                    if timer >= 256 then
                        timer = timerModulo
                        cpu.interrupt(2)
                    end
                end
            end
            if divMcycles >= 64 then
                divMcycles = divMcycles - 64
                divider = (divider + 1) & 0xff
            end
        end
        numCycles = numCycles - c
        ppu.resetCycles(c)
        --apu.resetCycles()
        ppu.forceFrame()
        sb.setLogMap("gb_updateTime",string.format("%.4f",os.clock()-time))
        sb.setLogMap("gb_iterations",string.format("%d",it))
        ticks = ticks + 1
        if ticks > 60 then
            rfps = ppu.getRequestedFrames()
            ticks = 0
        end
        sb.setLogMap("gbppu_requestedFPS",string.format("%d",rfps))
    end
    function gb.getFrame()
        return ppu.getFrame()
    end
    function gb.getSave()
        if rom then
            return rom.getSave()
        end
    end
    function gb.test()
        bus.test()
        return cpu.test()
    end
    function gb.debug()
        if rom then
            rom.debug()
        end
        cpu.debug()
        ppu.debug()
        bus.debug()
        --sb.setLogMap("gb_cpu",string.format("%.5f",cpuTime))
        --sb.setLogMap("gb_ppu",string.format("%.5f",ppuTime))
        --sb.setLogMap("gb_apu",string.format("%.5f",apuTime))
        --sb.setLogMap("gb_link_log",string.format("%s",asciiLog))
        --[[
        sb.setLogMap("gb_divider",string.format("%02x",divider))
        sb.setLogMap("gb_timer",string.format("%02x",timer))
        sb.setLogMap("gb_timerModulo",string.format("%02x",timerModulo))
        sb.setLogMap("gb_timerMaxMcycles",string.format("%d",timerMaxMcycles))
        sb.setLogMap("gb_timerMcycles",string.format("%d",timerMcycles))
        sb.setLogMap("gb_timerEnabled",sb.print(timerEnabled))
        ]]
    end
    function gb.setInput(newbuttons)
        for i=1,8 do
            if buttons[i] ~= newbuttons[i] then
                cpu.interrupt(4)
                break
            end
        end
        if cpu.stopped() then
            if buttonMode & 0x01 == 0 then
                -- d-pad
                for i=1,4 do
                    if buttons[i] ~= newbuttons[i] then
                        cpu.exitStop()
                        break
                    end
                end
            end
            if buttonMode & 0x02 == 0 then
                -- buttons
                for i=5,8 do
                    if buttons[i] ~= newbuttons[i] then
                        cpu.exitStop()
                        break
                    end
                end
            end
        end
        buttons = newbuttons
    end
    return gb
end
