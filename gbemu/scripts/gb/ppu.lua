
local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end
local function join(a,b)
    return a << 8 | b
end
-- I use M-cycles here

local maxRequestedFrames = 1

-- DMA should take either 160 or 640 mcycles, likely the former
function initPpu(bus,cpu)
    local renderThread = threads.create({
            name="gameboyRendererDistributor",
            scripts={
                main={"/scripts/gb/rendererDistThread.lua"}
            },
            tickRate=120,
            instructionLimit=1000000000,
        })
        
    local framePromises = {}
        
    local ppu = {}
    local vram = {} -- storage only
    for i=1,0x4000 do
        vram[i] = 0
    end
    local oam = {}
    for i=1,0x00a0 do
        oam[i] = 0
    end
    
    local writes = {}
    local frameWrites = {}
    local totalFrameWrites = 0
    local function storeWrites(sl)
        if #writes > 0 then
            if sl == -1 then
                --[[
                if frameWrites.vblank then
                    sb.logWarn("PPU overwriting VBlank writes!")
                end]]
                frameWrites.vblank = writes
            else
                --[[
                if frameWrites[string.format("sl_%d",sl)] then
                    sb.logWarn(string.format("PPU overwriting scanline %d writes!",sl))
                end]]
                frameWrites[string.format("sl_%d",sl)] = writes
            end
            totalFrameWrites = totalFrameWrites + #writes
            writes = {}
        end
    end
    local requestedFrames = 0
    local function requestFrame()
        if #framePromises >= maxRequestedFrames then
            threads.sendMessage(renderThread,"writes",frameWrites,true)
        else
            table.insert(framePromises,threads.sendMessage(renderThread,"writes",frameWrites,false))
        end
        frameWrites = {}
        requestedFrames = requestedFrames + 1
        sb.setLogMap("gbppu_writes",totalFrameWrites)
        totalFrameWrites = 0
    end
    
    local palettes = 0
    local obj0palettes = 0
    local obj1palettes = 0
    
    local colourBAddr = 0
    local colourBAutoInc = false
    local colourSAddr = 0
    local colourSAutoInc = false
    local colourMem = {} -- first 64 bytes is background, second 64 bytes is sprites
    
    local vramBank = 0
    
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
    local oamOrdering = 0
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
    
    ppu.vdmaActive = false
    local vdmaHblank = false
    local vdmaSource = 0x0000
    local vdmaDest = 0x8000
    local vdmaTransferLen = 0 -- amount of bytes * 16
    local vdmaTransferActive = false
    
    function ppu.read(addr)
        if addr <= 0x9fff then
            -- vram
            if mode == 3 and lcdOn then
                return 0xff
            end
            local i = addr & 0x1fff
            return vram[i+1+0x2000*vramBank]
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
        elseif addr == 0xff47 then
            return palettes
        elseif addr == 0xff48 then
            return obj0palettes
        elseif addr == 0xff49 then
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
        elseif gbMode == 1 then
            if addr == 0xff4f then
                return vramBank
            elseif addr == 0xff55 then
                return bit(not vdmaTransferActive) << 7
                    | (vdmaTransferLen & 0x7f)
            elseif addr == 0xff68 then
                return 0x40
                    | bit(colourBAutoInc) << 7
                    | colourBAddr
            elseif addr == 0xff69 then
                if mode == 3 and lcdOn then
                    return 0xff
                else
                    return colourMem[colourBAddr+1]
                end
            elseif addr == 0xff6a then
                return 0x40
                    | bit(colourSAutoInc) << 7
                    | colourSAddr
            elseif addr == 0xff6b then
                if mode == 3 and lcdOn then
                    return 0xff
                else
                    return colourMem[colourSAddr+65]
                end
            elseif addr == 0xff6c then
                return 0xfe | oamOrdering
            else
                return 0xff
            end
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
            vram[i+1+vramBank*0x2000] = v
            table.insert(writes,{addr,v,false,vramBank+1})
        elseif addr <= 0xfe9f then
            -- oam
            if (mode == 3 or mode == 2) and lcdOn then
                return
            end
            
            local i = addr & 0x00ff
            oam[i+1] = v
            table.insert(writes,{addr,v})
        else
            table.insert(writes,{addr,v,mode == 3 and lcdOn})
            --sb.setLogMap("gbppu_iowrite",string.format("%04x=%02x",addr,v))
            if addr == 0xff47 then
                palettes = v
            elseif addr == 0xff48 then
                obj0palettes = v
            elseif addr == 0xff49 then
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
                --sb.setLogMap("gbppu_lcdwrite",string.format("%02x",v))
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
                if cpu.isDoubleSpeed() then
                    dmaTimer = 80
                end
                for i=0x00,0x9f do
                    ppu.write(0xfe00 | i,bus.read(join(v,i)))
                end
                bus.setDMA(true)
            elseif gbMode == 1 then
                -- GBC only registers
                if addr == 0xff4f then
                    vramBank = v & 0x01
                elseif addr == 0xff68 then
                    colourBAddr = v & 0x3f
                    colourBAutoInc = (v & 0x80) > 0
                elseif addr == 0xff69 then
                    if mode ~= 3 or not lcdOn then
                        table.insert(writes,{colourBAddr,v,mode == 3 and lcdOn})
                        colourMem[colourBAddr+1] = v
                    end
                    if colourBAutoInc then
                        colourBAddr = (colourBAddr + 1) & 0x3f
                    end
                elseif addr == 0xff6a then
                    colourSAddr = v & 0x3f
                    colourSAutoInc = (v & 0x80) > 0
                elseif addr == 0xff6b then
                    if mode ~= 3 or not lcdOn then
                        table.insert(writes,{colourSAddr+64,v,mode == 3 and lcdOn})
                        colourMem[colourSAddr+65] = v
                    end
                    if colourSAutoInc then
                        colourSAddr = (colourSAddr + 1) & 0x3f
                    end
                elseif addr == 0xff6c then
                    oamOrdering = v & 0x01
                elseif addr == 0xff51 then
                    vdmaSource = (vdmaSource & 0x00ff) | (v << 8)
                elseif addr == 0xff52 then
                    vdmaSource = (vdmaSource & 0xff00) | (v & 0xf0)
                elseif addr == 0xff53 then
                    vdmaDest = (vdmaDest & 0x00ff) | ((v & 0x1f) << 8) | 0x8000
                elseif addr == 0xff54 then
                    vdmaDest = (vdmaDest & 0xff00) | (v & 0xf0)
                elseif addr == 0xff55 then
                    if vdmaTransferActive then
                        vdmaTransferActive = (v & 0x80) > 0
                    else
                        vdmaHblank = (v & 0x80) > 0
                        vdmaTransferLen = v & 0x7f
                        vdmaTransferActive = true
                        ppu.vdmaActive = not vdmaHblank
                    end
                end
            end
        end
    end
    
    function ppu.vdma()
        if vdmaHblank then
            ppu.vdmaActive = false
        end
        vdmaTransferLen = (vdmaTransferLen - 1) & 0x7f
        for i=1,16 do
            ppu.write(vdmaDest,bus.read(vdmaSource))
            vdmaDest = vdmaDest + 1
            vdmaSource = (vdmaSource + 1)&0xffff
            if vdmaDest > 0x9fff then
                vdmaTransferActive = false
                vdmaDest = 0x8000
                break
            end
        end
        if vdmaTransferLen == 0x7f then
            ppu.vdmaActive = false
            vdmaTransferActive = false
        end
        return 8
    end
    
    local lastDoInterrupt = false
    local oamScanNow = true
    local oamScanNewFrame = true
    local phase = "unknown"
    function ppu.waitingTime(c)
        return (m+scm)-c
    end
    function ppu.update(c,cycles)
        if dmaTimer > 0 then
            dmaTimer = dmaTimer - cycles
            if dmaTimer <= 0 then
                bus.setDMA(false)
            end
        end
        local doInterrupt = false
        local lastC = m+scm
        if m+scm < c then
            if not lcdOn then
                m = c
                scm = 0
                mode = 1
                scanline = 0
                x = 0
                oamScanNow = true
                oamScanNewFrame = true
                phase = "lcdoff"
            elseif scanline+1 >= vblank and not oamScanNewFrame then
                if scanline < vblank then
                    m = m + scm
                    scm = 0
                    requestFrame()
                    cpu.interrupt(0)
                    if vblankInterrupt then
                        cpu.interrupt(1)
                    end
                    oamScanNow = false
                end
                phase = "vblank"
                mode = 1
                if scm > 0 then
                    sb.logWarn("Scanline cycles in VBlank?")
                end
                m = m + 114
                scm = 0
                if hblankInterrupt then
                    --doInterrupt = true
                end
                scanline = scanline + 1
                if scanline == lyc and lycInterrupt then
                    cpu.interrupt(1)
                end
                if scanline >= vblankEnd then
                    storeWrites(-1)
                    oamScanNow = true
                    oamScanNewFrame = true
                end
            elseif oamScanNow then
                if mode ~= 2 then
                    m = m + scm
                    scm = 0
                    if oamScanNewFrame then
                        scanline = 0
                    else
                        scanline = scanline + 1
                    end
                    if scanline == lyc and lycInterrupt then
                        cpu.interrupt(1)
                    end
                    if oamInterrupt then
                        cpu.interrupt(1)
                    end
                end
                mode = 2
                -- oam scan
                --scm = scm + math.min(c-(m+scm),20-scm)
                scm = 20
                oamScanNow = false
                oamScanNewFrame = false
                phase = "oamscan"
            elseif x >= hblank then
                phase = "hblank"
                if mode ~= 0 then
                    storeWrites(scanline)
                    if hblankInterrupt then
                        cpu.interrupt(1)
                    end
                    if vdmaTransferActive and vdmaHblank and not cpu.halted() then
                        ppu.vdmaActive = true
                    end
                end
                mode = 0
                --scm = scm + cycles--math.min(c-(m+scm),114-scm)
                scm = 114
                x = 0
                oamScanNow = true
                oamScanNewFrame = false
            else
                phase = "draw"
                mode = 3
                -- skip to hblank
                x = hblank
                scm = 114-54
            end
        end
        if m+scm < c then
            sb.logWarn(string.format("PPU is behind %.1f cycles! This tick went for %.1f cycles. PPU went through %.1f cycles. PPU phase is %s.", c-(m+scm), cycles, (m+scm)-lastC, phase or "undefined"))
        end
        if doInterrupt and not lastDoInterrupt then
            cpu.interrupt(1)
        end
        lastDoInterrupt = doInterrupt
    end
    function ppu.reset()
        m = 0
        x = 0
        scanline = 0
        frameWrites = {}
        writes = {}
        lcdOn = true
        oamScanNow = true
        lycInterrupt = false
        oamInterrupt = false
        vblankInterrupt = false
        hblankInterrupt = false
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
            -- TODO: this data doesn't match the renderer on startup
            for i=1,128 do
                if i <= 64 then
                    colourMem[i] = 0xff
                else
                    colourMem[i] = math.random(0,255)
                end
            end
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
        --sb.setLogMap("gbppu_lcdEnabled",sb.print(lcdOn))
        --sb.setLogMap("gbppu_dmaTimer",sb.print(dmaTimer))
        --[[
        sb.setLogMap("gbppu_statint_vblank",sb.print(vblankInterrupt))
        sb.setLogMap("gbppu_statint_hblank",sb.print(hblankInterrupt))
        sb.setLogMap("gbppu_statint_oam",sb.print(oamInterrupt))
        sb.setLogMap("gbppu_statint_lyc",sb.print(lycInterrupt))
        sb.setLogMap("gbppu_statint_lyc_c",string.format("%d",lyc))
        
        ]]
        sb.setLogMap("gbppu_waitingFrames",string.format("%d",#framePromises))
        
        --sb.setLogMap("gbppu_phase",string.format("%s",phase))
        --[[
        sb.setLogMap("gbppu_vdmaActive",string.format("%s",vdmaTransferActive))
        sb.setLogMap("gbppu_vdmaRunning",string.format("%s",ppu.vdmaActive))
        sb.setLogMap("gbppu_vdmaHDMA",string.format("%s",vdmaHblank))
        sb.setLogMap("gbppu_vdmaLength",string.format("%02x",vdmaTransferLen))
        sb.setLogMap("gbppu_vdmaSource",string.format("%04x",vdmaSource))
        sb.setLogMap("gbppu_vdmaDest",string.format("%04x",vdmaDest))
        ]]
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
