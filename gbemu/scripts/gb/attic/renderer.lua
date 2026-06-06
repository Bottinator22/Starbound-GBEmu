
local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end
-- I use M-cycles here
function initRenderer()
    local oam = {}
    local renderer = {}
    local cpu = nil
    local backgrounds = {}
    local tiles = {}
    for i=1,2 do
        backgrounds[i] = {}
        for x=0,31 do
            for y=0,31 do
                backgrounds[i][y*32+x+1] = 0
            end
        end
    end
    -- store tile data as its pixels instead of directly for efficiency
    -- 384 tiles are available
    for i=1,384 do
        tiles[i] = {}
        -- tiles are 8x8
        for y=0,7 do
            for x=0,7 do
                tiles[i][y*8+x+1] = 0 -- ranges from 0 to 3
            end
        end
    end
    
    -- in GB, is array of 4 numbers
    -- in CGB, TODO
    local palettes = {}
    
    -- 0 = gb, 1 = gbc
    local gbMode = 0
    -- 0x90 to 9x99 are vblank, all below are on screen
    -- (the screen is 144 pixels high, 0x90 = 144)
    -- a scanline takes 456 tcycles or 114 mcycles
    -- OAM scan is 20 mcycles
    local drawable = root.assetJson("/scripts/quarterscreen.json").drawable
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
    local mode = 0
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
    local parts = 4
    local w=2
    local h=2
    local pixels = {}
    local iw = (160/w)
    local ih = (144/h)
    for i=1,parts do
        pixels[i] = {}
        for i2=1,iw*ih*3 do
            pixels[i][i2] = 0
        end
    end
    local gbPalette = {
        {255,255,255},
        {170,170,170},
        {85, 85, 85},
        {0,  0,  0}
    }
    local function palette(c,p)
        if gbMode == 0 then
            return table.unpack(gbPalette[palettes[c+1]+1])
        else
            -- TODO
        end
    end
    
    local function setPixel(x,y,r,g,b)
        local image = pixels[math.floor(y/ih)*w+math.floor(x/iw)+1]
        local pi = ((x%iw)*ih+(y%ih))*3
        image[pi+1] = r
        image[pi+2] = g
        image[pi+3] = b
    end
    --[[for x=0,159 do
        for y=0,143 do
            setPixel(x,y,255,0,0)
        end
    end]]
    
    
    function renderer.read(addr)
        if addr <= 0x9fff then
            -- vram
            if mode == 3 and lcdOn then
                return 0xff
            end
            if addr <= 0x97ff then
                -- tile data
                local off = (addr - 0x8000)
                local i = math.floor(off/16) + 1
                -- each 2 bytes is a row of 8 pixels
                -- off%16 = 1 byte within tile
                local b = (math.floor((off%16)/2))*8+1
                local parity = 2-(1-(off%2))
                local s = parity-1
                local tile = tiles[i]
                return 
                    (tile[b] & parity) << (7-s)
                    | (tile[b+1] & parity) << (6-s)
                    | (tile[b+2] & parity) << (5-s)
                    | (tile[b+3] & parity) << (4-s)
                    | (tile[b+4] & parity) << (3-s)
                    | (tile[b+5] & parity) << (2-s)
                    | (tile[b+6] & parity) << (1-s)
                    | (tile[b+7] & parity) >> s
            elseif addr <= 0x9bff  then
                -- background 1
                local i = addr - 0x9800 + 1
                return backgrounds[1][i]
            elseif addr <= 0x9fff then
                -- background 2
                local i = addr - 0x9c00 + 1
                return backgrounds[2][i]
            end
        elseif addr <= 0xfe9f then
            -- oam
            if (mode == 3 or mode == 2) and lcdOn then
                return 0xff
            end
            -- temp
            return 0xff
        elseif addr == 0xff4B then
            return windowX
        elseif addr == 0xff4A then
            return windowY
        elseif addr == 0xff47 and gbMode == 0 then
            return 
                  palettes[4] << 6
                | palettes[3] << 4
                | palettes[2] << 2
                | palettes[1]
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
                | mode
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
    function renderer.write(addr,v)
        if addr <= 0x9fff then
            -- vram
            if mode == 3 and lcdOn then
                return
            end
            if addr <= 0x97ff then
                -- tile data
                local off = (addr - 0x8000)
                local i = math.floor(off/16) + 1
                -- each 2 bytes is a row of 8 pixels
                -- off%16 = 1 byte within tile
                local b = (math.floor((off%16)/2))*8+1
                local parity = 2-(1-(off%2))
                local s = parity-1
                local tile = tiles[i]
                for i=0,7 do
                    tile[b+i] = (tile[b+i] ~ (tile[b+i] & parity)) | (((v >> i) & 0x01) << s)
                end
                --[[
                tile[b] = (tile[b] ~ (tile[b] & parity)) | ((v << s) & 0x01)
                tile[b+1] = (tile[b+1] ~ (tile[b+1] & parity)) | (((v >> 1) << s) & 0x01)
                tile[b+2] = (tile[b+2] ~ (tile[b+2] & parity)) | (((v >> 2) << s) & 0x01)
                tile[b+3] = (tile[b+3] ~ (tile[b+3] & parity)) | (((v >> 3) << s) & 0x01)
                tile[b+4] = (tile[b+4] ~ (tile[b+4] & parity)) | (((v >> 4) << s) & 0x01)
                tile[b+5] = (tile[b+5] ~ (tile[b+5] & parity)) | (((v >> 5) << s) & 0x01)
                tile[b+6] = (tile[b+6] ~ (tile[b+6] & parity)) | (((v >> 6) << s) & 0x01)
                tile[b+7] = (tile[b+7] ~ (tile[b+7] & parity)) | (((v >> 7) << s) & 0x01)
                ]]
            elseif addr <= 0x9bff  then
                -- background 1
                local i = addr - 0x9800 + 1
                backgrounds[1][i] = v
            elseif addr <= 0x9fff then
                -- background 2
                local i = addr - 0x9c00 + 1
                backgrounds[2][i] = v
            end
        elseif addr <= 0xfe9f then
            -- oam
            if (mode == 3 or mode == 2) and lcdOn then
                return
            end
        elseif addr == 0xff47 and gbMode == 0 then
            palettes[4] = (v >> 6) & 3
            palettes[3] = (v >> 4) & 3
            palettes[2] = (v >> 2) & 3
            palettes[1] = v & 3
        elseif addr == 0xff45 then
            lyc = v
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
            lcdOn = (v & 0x80) > 0
            windowSelect = (v & 0x40) >> 6
            windowEnabled = (v & 0x20) > 0
            tileIndexMode = (v & 0x10) >> 4
            bgSelect = (v & 0x08) >> 3
            objSize = (v & 0x04) >> 2
            objEnabled = (v & 0x02) > 0
            bgEnabled = (v & 0x01) > 0
        elseif addr == 0xff4A then
            windowY = v
        elseif addr == 0xff4B then
            windowX = v
        end
    end
    
    local lastDoInterrupt = false
    function renderer.update(c,cycles)
        if c == cycles then
            m = 0
        end
        local doInterrupt = false
        while m+scm < c do
            if mode == 2 then
                -- oam scan
                scm = scm + math.min(c-(m+scm),20-scm)
                if scm >= 20 then
                    mode = 3
                end
            elseif scanline >= vblank then
                if mode ~= 1 then
                    cpu.interrupt(0)
                    if vblankInterrupt then
                        cpu.interrupt(1)
                    end
                end
                mode = 1
                if scanline >= vblankEnd then
                    scanline = 0
                else
                    m = m + 114
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
                    mode = 2
                    if oamInterrupt then
                        doInterrupt = true
                    end
                    m = m + scm
                    scm = 0
                    scanline = scanline + 1
                    x = 0
                    if scanline == lyc then
                        doInterrupt = true
                    end
                end
            else
                if lcdOn then
                    -- todo: find colour of pixel
                    local r,g,b = 255,255,255
                    if bgEnabled then
                        local bgX = scrollX+x
                        local bgY = scrollY+scanline
                        local bgIndexX = math.floor(bgX/8)%32
                        local bgIndexY = math.floor(bgY/8)%32
                        local bgI = bgIndexY*32+bgIndexX
                        local bgTileX = 7-(bgX%8)
                        local bgTileY = bgY%8
                        local bgTile = backgrounds[bgSelect+1][bgI+1]
                        if tileIndexMode == 0 then
                            bgTile = 256 + sign8(bgTile)
                        end
                        r,g,b = palette(tiles[bgTile+1][bgTileY*8+bgTileX+1])
                        --b = math.floor(bgTile/384*255)
                    end
                    if windowEnabled then
                        local winX = x+7-windowX
                        local winY = scanline-windowY
                        local winIndexX = math.floor(winX/8)
                        local winIndexY = math.floor(winY/8)
                        if winIndexX >= 0 and winIndexY >= 0 and winIndexX < 32 and winIndexY < 32 then
                            local winI = winIndexY*32+winIndexX
                            local winTileX = 7-(winX%8)
                            local winTileY = winY%8
                            local winTile = backgrounds[windowSelect+1][winI+1]
                            if tileIndexMode == 0 then
                                winTile = 256 + sign8(winTile)
                            end
                            local c = tiles[winTile+1][winTileY*8+winTileX+1]
                            --if c ~= 0 then
                                r,g,b = palette(c)
                                --b = math.floor(winTile/384*255)
                            --end
                        end
                    end
                    setPixel(x,scanline,r,g,b)
                    mode = 3
                else
                    setPixel(x,scanline,255,255,255)
                end
                x = x + 1
                -- temp
                scm = scm + (114-40)/160
            end
        end
        if doInterrupt and not lastDoInterrupt then
            cpu.interrupt(1)
        end
        lastDoInterrupt = doInterrupt
    end
    function renderer.setGBMode(t)
        gbMode = t
        if gbMode == 0 then
            palettes = {3,2,1,0}
        elseif gbMode == 1 then
            -- todo: CGB palettes
            palettes = {}
        end
    end
    function renderer.setCpu(ncpu)
        cpu = ncpu
    end
    function renderer.debug()
        --sb.setLogMap("gbppu_pixels",string.format("%d",#pixels))
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
    end
    
    -- GBC doesn't need to render every frame as long as game logic runs in background
    -- note: if just sending the entirety of VRAM is more efficient than sending the data to render, and processing at the other end is more efficient, do so
    local drawables = {}
    function renderer.getFrame()
        for k,v in next, pixels do
            drawables[k] = string.format(drawable,table.unpack(v))
        end
        return drawables
    end
    return renderer
end
