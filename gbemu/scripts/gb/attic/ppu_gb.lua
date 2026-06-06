
local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end
local function join(a,b)
    return a << 8 | b
end
-- I use M-cycles here

-- DMA should take either 160 or 640 mcycles, likely the former
function initPpu(bus,cpu)
    local renderThread = threads.create({
            name="gameboyRendererDistributor",
            scripts={
                main={"/scripts/gb/rendererDistThread.lua"}
            },
            tickRate=120,
            instructionLimit=100000000,
        })
        
    local framePromises = {}
        
    local ppu = {}
    local vram = {} -- storage only
    for i=1,0x2000 do
        vram[i] = 0
    end
    local oam = {}
    for i=1,0x00a0 do
        oam[i] = 0
    end
    
    local writes = {}
    local frameWrites = {}
    local function storeWrites(sl)
        if #writes > 0 then
            if sl == -1 then
                frameWrites.vblank = writes
            else
                frameWrites[string.format("sl_%d",sl)] = writes
            end
            writes = {}
        end
    end
    local requestedFrames = 0
    local function requestFrame()
        if #framePromises > 0 then
            threads.sendMessage(renderThread,"writes",frameWrites)
        else
            table.insert(framePromises,threads.sendMessage(renderThread,"writes",frameWrites))
        end
        frameWrites = {}
        requestedFrames = requestedFrames + 1
    end
    
    -- in GB, is array of 4 numbers
    -- in CGB, TODO
    --local palettes = {}
    local palettes = 0
    local obj0palettes = 0
    local obj1palettes = 0
    
    -- 0 = gb, 1 = gbc
    local gbMode = -1
    -- 0x90 to 9x99 are vblank, all below are on screen
    -- (the screen is 144 pixels high, 0x90 = 144)
    -- a scanline takes 456 tcycles or 114 mcycles
    -- OAM scan is 20 mcycles
    local vblank = 0x90
    local vblankEnd = 0x99
    local hblank = 160
    local hblankEnd = 160
    local scanline = 0x00
    local lyc = 0x00
    local x = 0
    local windowX = 0
    local windowY = 0
    local windowSelect = 0
    local windowEnabled = false
    local scrollX = 0
    local scrollY = 0
    local bgSelect = 0
    local lastCycle = 0
    local mode = 1
    local tileIndexMode = 0
    local bgEnabled = false
    local objEnabled = false
    local lycInterrupt = false
    local oamInterrupt = false
    local vblankInterrupt = false
    local hblankInterrupt = false
    local m = 0
    local scm = 0
    local lcdOn = true
    local objSize = 0
    local dmaTimer = 0
    
    function ppu.read(addr)
        if addr <= 0x9fff then
            -- vram
            if mode == 3 and lcdOn then
                return 0xff
            end
            local i = addr & 0x1fff
            return vram[i+1]
        elseif addr <= 0xfe9f then
            -- oam
            if (mode == 3 or mode == 2) and lcdOn then
                return 0xff
            end
            -- temp
            local i = addr & 0x00ff
            return oam[i+1] or 0xff
        elseif addr == 0xff4B then
            return windowX
        elseif addr == 0xff4A then
            return windowY
        elseif addr == 0xff47 and gbMode == 0 then
            return palettes
        elseif addr == 0xff48 and gbMode == 0 then
            return obj0palettes
        elseif addr == 0xff49 and gbMode == 0 then
            return obj1palettes
        elseif addr == 0xff45 then
            return lyc
        elseif addr == 0xff44 then
            return scanline
        elseif addr == 0xff43 then
            return scrollX
        elseif addr == 0xff42 then
            return scrollY
        elseif addr == 0xff41 then
            return 
                  bit(lycInterrupt) << 6
                | bit(oamInterrupt) << 5
                | bit(vblankInterrupt) << 4
                | bit(hblankInterrupt) << 3
                | bit(scanline == lyc) << 2
                | (lcdOn and mode or 1)
        elseif addr == 0xff40 then
            return 
                  bit(lcdOn) << 7
                | windowSelect << 6
                | bit(windowEnabled) << 5
                | tileIndexMode << 4
                | bgSelect << 3
                | objSize << 2
                | bit(objEnabled) << 1
                | bit(bgEnabled)
        else
            return 0xff
        end
    end
    function ppu.write(addr,v)
        if addr <= 0x9fff then
            -- vram
            if mode == 3 and lcdOn then
                return
            end
            local i = addr & 0x1fff
            vram[i+1] = v
            table.insert(writes,{addr,v})
        elseif addr <= 0xfe9f then
            -- oam
            if (mode == 3 or mode == 2) and lcdOn then
                return
            end
            
            local i = addr & 0x00ff
            oam[i+1] = v
            table.insert(writes,{addr,v})
        else
            table.insert(writes,{addr,v})
            if addr == 0xff47 and gbMode == 0 then
                palettes = v
            elseif addr == 0xff48 and gbMode == 0 then
                obj0palettes = v
            elseif addr == 0xff49 and gbMode == 0 then
                obj1palettes = v
            elseif addr == 0xff45 then
                lyc = v
                if scanline == lyc and lycInterrupt then
                    cpu.interrupt(1)
                end
            elseif addr == 0xff43 then
                scrollX = v
            elseif addr == 0xff42 then
                scrollY = v
            elseif addr == 0xff41 then
                lycInterrupt = (v & 0x40) > 0    -- 01000000
                oamInterrupt = (v & 0x20) > 0    -- 00100000
                vblankInterrupt = (v & 0x10) > 0 -- 00010000
                hblankInterrupt = (v & 0x08) > 0 -- 00001000
            elseif addr == 0xff40 then
                local wasLcdOn = lcdOn
                lcdOn = (v & 0x80) > 0
                windowSelect = (v & 0x40) >> 6
                windowEnabled = (v & 0x20) > 0
                tileIndexMode = (v & 0x10) >> 4
                bgSelect = (v & 0x08) >> 3
                objSize = (v & 0x04) >> 2
                objEnabled = (v & 0x02) > 0
                bgEnabled = (v & 0x01) > 0
                if not lcdOn and wasLcdOn and mode ~= 1 and mode ~= 0 then
                    sb.logWarn("LCD was turned off while drawing!")
                end
                if lcdOn and not wasLcdOn then
                    if scanline == lyc and lycInterrupt then
                        cpu.interrupt(1)
                    end
                end
            elseif addr == 0xff4A then
                windowY = v
            elseif addr == 0xff4B then
                windowX = v
            elseif addr == 0xff46 then
                -- OAM DMA
                dmaTimer = 160
                for i=0x00,0x9f do
                    ppu.write(0xfe00 | i,bus.read(join(v,i)))
                end
                bus.setDMA(true)
            end
        end
    end
    
    local lastDoInterrupt = false
    function ppu.update(c,cycles)
        if dmaTimer > 0 then
            dmaTimer = dmaTimer - cycles
            if dmaTimer <= 0 then
                bus.setDMA(false)
            end
        end
        local doInterrupt = false
        while m+scm < c do
            if not lcdOn then
                m = c
                scm = 0
                mode = 1
                scanline = 0
                x = 0
            elseif mode == 2 then
                -- oam scan
                scm = scm + math.min(c-(m+scm),20-scm)
                if scm >= 20 then
                    mode = 3
                end
            elseif scanline >= vblank then
                if mode ~= 1 then
                    requestFrame()
                    cpu.interrupt(0)
                    if vblankInterrupt then
                        cpu.interrupt(1)
                    end
                end
                mode = 1
                if scanline >= vblankEnd then
                    scanline = 0
                    storeWrites(-1)
                    if scanline == lyc and lycInterrupt then
                        doInterrupt = true
                    end
                else
                    m = m + 114
                    scm = 0
                    if hblankInterrupt then
                        doInterrupt = true
                    end
                    scanline = scanline + 1
                    if scanline == lyc and lycInterrupt then
                        doInterrupt = true
                    end
                end
            elseif x >= hblank then
                if hblankInterrupt and mode ~= 0 then
                    doInterrupt = true
                end
                mode = 0
                scm = scm + math.min(c-(m+scm),114-scm)
                if scm >= 114 then
                    storeWrites(scanline)
                    mode = 2
                    if oamInterrupt then
                        doInterrupt = true
                    end
                    m = m + scm
                    scm = 0
                    scanline = scanline + 1
                    x = 0
                    if scanline == lyc and lycInterrupt then
                        doInterrupt = true
                    end
                end
            else
                mode = 3
                -- skip to hblank
                x = hblank
                scm = scm + (114-40)
            end
        end
        if doInterrupt and not lastDoInterrupt then
            cpu.interrupt(1)
        end
        lastDoInterrupt = doInterrupt
    end
    function ppu.resetCycles(mc)
        m = m - mc
    end
    function ppu.setGBMode(t)
        if gbMode == t then
            return
        end
        threads.sendMessage(renderThread,"setGBMode",t)
        gbMode = t
        if gbMode == 0 then
            palettes = 0 << 6
                | 1 << 4
                | 2 << 2
                | 3
        elseif gbMode == 1 then
            -- todo: CGB palettes
            palettes = 0
        end
    end
    function ppu.forceFrame()
        if not lcdOn then
            storeWrites(-1)
            requestFrame()
        end
    end
    function ppu.debug()
        --[[
        sb.setLogMap("gbppu_mode",string.format("%d",mode))
        sb.setLogMap("gbppu_scanline",string.format("%d",scanline))
        sb.setLogMap("gbppu_lcdEnabled",sb.print(lcdOn))
        sb.setLogMap("gbppu_tileMode",sb.print(tileIndexMode))
        sb.setLogMap("gbppu_bgEnabled",sb.print(bgEnabled))
        sb.setLogMap("gbppu_bgSelect",string.format("%d",bgSelect))
        sb.setLogMap("gbppu_bgScroll",string.format("[%d,%d]",scrollX,scrollY))
        sb.setLogMap("gbppu_winEnabled",sb.print(windowEnabled))
        sb.setLogMap("gbppu_winSelect",string.format("%d",windowSelect))
        sb.setLogMap("gbppu_winPos",string.format("[%d,%d]",windowX,windowY))
        sb.setLogMap("gbppu_objEnabled",sb.print(objEnabled))
        sb.setLogMap("gbppu_objSize",string.format("%d",objSize))
        ]]
        --[[
        sb.setLogMap("gbppu_lcdEnabled",sb.print(lcdOn))
        sb.setLogMap("gbppu_statint_vblank",sb.print(vblankInterrupt))
        sb.setLogMap("gbppu_statint_hblank",sb.print(hblankInterrupt))
        sb.setLogMap("gbppu_statint_oam",sb.print(oamInterrupt))
        sb.setLogMap("gbppu_statint_lyc",sb.print(lycInterrupt))
        sb.setLogMap("gbppu_statint_lyc_c",string.format("%d",lyc))
        ]]
        sb.setLogMap("gbppu_waitingFrames",string.format("%d",#framePromises))
    end
    
    -- GBC doesn't need to render every frame as long as game logic runs in background
    -- note: if just sending the entirety of VRAM is more efficient than sending the data to render, and processing at the other end is more efficient, do so
    local drawables
    function ppu.getFrame()
        --[[
        for k,v in next, pixels do
            drawables[k] = string.format(drawable,table.unpack(v))
        end
        ]]
        local nFramePromises = {}
        for k,v in next, framePromises do
            if v:finished() then
                if v:succeeded() and v:result() then
                    drawables = v:result()
                end
            else
                table.insert(nFramePromises,v)
            end
        end
        framePromises = nFramePromises
        return drawables
    end
    function ppu.getRequestedFrames()
        local out = requestedFrames
        requestedFrames = 0
        return out
    end
    return ppu
end
