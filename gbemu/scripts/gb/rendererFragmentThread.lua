require "/scripts/gb/utils.lua"

local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end
local function join(a,b)
    return a << 8 | b
end

local minX = 0
local maxX = 0
local minY = 0
local maxY = 0

local objects
local renderer = {}
local cpu = nil
local backgrounds
local backgroundAttributes
local tiles
local vramBank = 1

-- 0 = gb, 1 = gbc
local gbMode = -1
local function resetVRAMOAM()
    vramBank = 1
    objects = {}
    backgrounds = {}
    backgroundAttributes = {}
    tiles = {}
    for i=1,2 do
        backgrounds[i] = {}
        backgroundAttributes[i] = {}
        for x=0,31 do
            for y=0,31 do
                backgroundAttributes[i][y*32+x+1] = {
                    palette=1,
                    vramBank=1,
                    xFlip=false,
                    yFlip=false,
                    priority=false
                }
                backgrounds[i][y*32+x+1] = 0
            end
        end
    end
    -- store tile data as its pixels instead of directly for efficiency
    -- 384 tiles are available per bank
    for b=1,2 do
        tiles[b] = {}
        for i=1,384 do
            tiles[b][i] = {}
            -- tiles are 8x8
            for y=0,7 do
                for x=0,7 do
                    tiles[b][i][y*8+x+1] = 1 -- ranges from 1 to 4
                end
            end
        end
    end

    -- there are 40 objects
    for i=1,40 do
        objects[i] = {0,0,0,{
            priority=true,
            xFlip=false,
            yFlip=false,
            palette=1,
            vramBank=1,
            index=i
        }}
    end
end
function cgbColourNew(c)
    return cgbColour(c,{})
end
--[[
-- TODO
local function colourCompMult(c)
    -- simple colour math would just always multiply this by 8
    if c > 0x0f then
        return 8*c
    else
        return 6*c
    end
end
function cgbColour(c,o)
    local r = colourCompMult((c & 0x001f))
    local g = colourCompMult((c & 0x03e0) >> 5)
    local b = colourCompMult((c & 0x7c00) >> 10)
    o[1] = math.min(math.floor(r*0.9+0.3*g+0.3*b),255)
    o[2] = math.min(math.floor(g*0.9+0.4*r+0.4*b),255)
    o[3] = math.min(math.floor(b*0.9+0.3*r+0.3*g),255)
    
    return o
end
]]
function cgbColour(c,o)
    o[1] = (c & 0x001f) << 3
    o[2] = (c & 0x03e0) >> 2
    o[3] = (c & 0x7c00) >> 7
    
    return o
end

-- in GB, palettes is array of 4 numbers, objPalettes is array of 2 arrays of 4 numbers
-- in CGB, both are arrays of 8 arrays of 3 numbers, which are converted to VGA colours when modified
local palettes = {}
local objPalettes = {}

local colourMem = {} -- first 64 bytes is background, second 64 bytes is sprites
function updatePalette(n)
    local p = (n // 4) + 1
    local c = (n & 0x3) + 1
    cgbColour(join(colourMem[n*2+2],colourMem[n*2+1]),palettes[p][c])
end
function updateObjPalette(n)
    local p = (n // 4) + 1
    local c = (n & 0x3) + 1
    cgbColour(join(colourMem[n*2+66],colourMem[n*2+65]),objPalettes[p][c])
end

-- 0x90 to 9x99 are vblank, all below are on screen
-- (the screen is 144 pixels high, 0x90 = 144)
-- a scanline takes 456 tcycles or 114 mcycles
-- OAM scan is 20 mcycles
local drawable
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
local oamOrdering = 0
local m = 0
local scm = 0
local lcdOn = true
local objSize = 8
local w=1
local h=6
local pixels = {}
local iw = (160/w)
local ih = (144/h)
for i2=1,iw*ih*3 do
    pixels[i2] = 0
end
local gbPalette = {
    {255,255,255},
    {170,170,170},
    {85, 85, 85},
    {0,  0,  0}
}
local function palette(c,p)
    if gbMode == 0 then
        if c == 0 then
            return 255,255,255
        else
            return table.unpack(gbPalette[palettes[c]])
        end
    else
        if c == 0 then
            return 0xf8,0xf8,0xf8
        else
            return table.unpack(palettes[p][c])
        end
    end
end
local function objPalette(c,p)
    if gbMode == 0 then
        if c == 0 then
            return 255,255,255
        else
            return table.unpack(gbPalette[objPalettes[p][c]])
        end
    else
        if c == 0 then
            return 0xf8,0xf8,0xf8
        else
            return table.unpack(objPalettes[p][c])
        end
    end
end

local function setPixel(x,y,r,g,b)
    --local image = pixels[math.floor(y/ih)*w+math.floor(x/iw)+1]
    local pi = ((x%iw)*ih+(y%ih))*3
    pixels[pi+1] = r
    pixels[pi+2] = g
    pixels[pi+3] = b
end
--[[for x=0,159 do
    for y=0,143 do
        setPixel(x,y,255,0,0)
    end
end]]

-- memRead ommitted since it isn't needed here

local function commitWrites(w)
    for k,v in next, w do
        memWrite(v[1],v[2],v[3],v[4])
    end
end

function memWrite(addr,v,drawing,vramBank)
    if addr <= 0x007f then
        -- direct colour ram index, exclusive to here
        colourMem[addr+1] = v
        local p = addr // 2
        if addr <= 0x003f then
            updatePalette(p)
        else
            updateObjPalette(p-32)
        end
    elseif addr <= 0x9fff then
        -- vram
        if addr <= 0x97ff then
            -- tile data
            local off = (addr - 0x8000)
            local i = off//16 + 1
            -- each 2 bytes is a row of 8 pixels
            -- off%16 = 1 byte within tile
            local b = ((off%16)//2)*8+1
            local parity = 2-(1-(off%2))
            local s = parity-1
            local tile = tiles[vramBank][i]
            for i=0,7 do
                tile[b+i] = (((tile[b+i])-1 ~ ((tile[b+i]-1) & parity)) | (((v >> i) & 0x01) << s))+1
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
        elseif vramBank == 1 then
            if addr <= 0x9bff  then
                -- background 1
                local i = addr - 0x9800 + 1
                backgrounds[1][i] = v
            elseif addr <= 0x9fff then
                -- background 2
                local i = addr - 0x9c00 + 1
                backgrounds[2][i] = v
            end
        else
            if addr <= 0x9bff  then
                -- background 1 attributes
                local i = addr - 0x9800 + 1
                backgroundAttributes[1][i].palette = (v & 0x07) + 1
                backgroundAttributes[1][i].vramBank = ((v & 0x08) >> 3) + 1
                backgroundAttributes[1][i].xFlip = (v & 0x20) > 0
                backgroundAttributes[1][i].yFlip = (v & 0x40) > 0
                backgroundAttributes[1][i].priority = (v & 0x80) > 0
            elseif addr <= 0x9fff then
                -- background 2 attributes
                local i = addr - 0x9c00 + 1
                backgroundAttributes[2][i].palette = (v & 0x07) + 1
                backgroundAttributes[2][i].vramBank = ((v & 0x08) >> 3) + 1
                backgroundAttributes[2][i].xFlip = (v & 0x20) > 0
                backgroundAttributes[2][i].yFlip = (v & 0x40) > 0
                backgroundAttributes[2][i].priority = (v & 0x80) > 0
            end
        end
    elseif addr <= 0xfe9f then
        -- oam
        local i = (addr&0xfc) >> 2
        local i2 = addr&0x03
        local obj = objects[i+1]
        if i2 == 3 then
            obj[4].priority = (v & 0x80) > 0
            obj[4].yFlip = (v & 0x40) > 0
            obj[4].xFlip = (v & 0x20) > 0
            if gbMode == 0 then
                obj[4].palette = ((v & 0x10) >> 4)+1
            else
                obj[4].vramBank = ((v & 0x08) >> 3)+1
                obj[4].palette = (v & 0x07) + 1
            end
        else
            obj[i2+1] = v
        end
    elseif addr == 0xff47 and gbMode == 0 then
        palettes[4] = ((v >> 6) & 3) + 1
        palettes[3] = ((v >> 4) & 3) + 1
        palettes[2] = ((v >> 2) & 3) + 1
        palettes[1] = (v & 3) + 1
    elseif addr == 0xff48 and gbMode == 0 then
        objPalettes[1][4] = ((v >> 6) & 3) + 1
        objPalettes[1][3] = ((v >> 4) & 3) + 1
        objPalettes[1][2] = ((v >> 2) & 3) + 1
        objPalettes[1][1] = (v & 3) + 1
    elseif addr == 0xff49 and gbMode == 0 then
        objPalettes[2][4] = ((v >> 6) & 3) + 1
        objPalettes[2][3] = ((v >> 4) & 3) + 1
        objPalettes[2][2] = ((v >> 2) & 3) + 1
        objPalettes[2][1] = (v & 3) + 1
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
        objSize = 8+((v & 0x04) >> 2)*8
        objEnabled = (v & 0x02) > 0
        bgEnabled = (v & 0x01) > 0
    elseif addr == 0xff4A then
        windowY = v
    elseif addr == 0xff4B then
        windowX = v
    elseif gbMode == 1 then
        --if addr == 0xff4f then
            --vramBank = (v & 0x01)+1
            --[[
        elseif addr == 0xff68 then
            colourBAddr = v & 0x3f
            colourBAutoInc = (v & 0x80) > 0
        elseif addr == 0xff69 then
            if not drawing then
                colourMem[colourBAddr+1] = v
                updatePalette(colourBAddr // 2)
            end
            if colourBAutoInc then
                colourBAddr = (colourBAddr + 1) & 0x3f
            end
        elseif addr == 0xff6a then
            colourSAddr = v & 0x3f
            colourSAutoInc = (v & 0x80) > 0
        elseif addr == 0xff6b then
            if not drawing then
                colourMem[colourSAddr+65] = v
                updateObjPalette(colourSAddr // 2)
            end
            if colourSAutoInc then
                colourSAddr = (colourSAddr + 1) & 0x3f
            end]]
        --end
        if addr == 0xff6c then
            oamOrdering = v & 0x01
            sb.setLogMap("gbppu_r_oamOrdering",string.format("%d",oamOrdering))
        end
    end
end
--[[
function renderer.update(c,cycles)
    if c == cycles then
        m = 0
    end
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
]]
function setGBMode(t)
    gbMode = t
    if gbMode == 0 then
        palettes = {4,3,2,1}
        objPalettes = {
            {4,3,2,1},
            {4,3,2,1}
        }
    elseif gbMode == 1 then
        -- TODO: what's stored by default in memory doesn't match starting object palettes, also completely mismatches the data in the PPU
        palettes = {}
        objPalettes = {}
        for i=1,8 do
            palettes[i] = {}
            objPalettes[i] = {}
            for i2=1,4 do
                palettes[i][i2] = cgbColourNew(0xffff)
                objPalettes[i][i2] = cgbColourNew(math.random(0,65535))
            end
        end
        colourMem = {}
        for i=1,128 do
            if i <= 64 then
                colourMem[i] = 0xff
            else
                colourMem[i] = math.random(0,255)
            end
        end
    end
    resetVRAMOAM()
end

local function sortObjects0(a,b)
    if a[2] == b[2] then
        return a[4].index < b[4].index
    end
    return a[2] < b[2] 
end
-- GBC doesn't need to render every frame as long as game logic runs in background
-- note: if just sending the entirety of VRAM is more efficient than sending the data to render, and processing at the other end is more efficient, do so

-- I use M-cycles here
function init()
    local myName = config.getParameter("gbRenderName")
    local xIndex = config.getParameter("xIndex")
    local yIndex = config.getParameter("yIndex")
    local fragWidth = hblank//w
    local fragHeight = vblank//h
    minX = (xIndex-1)*fragWidth
    maxX = xIndex*fragWidth
    minY = (yIndex-1)*fragHeight
    maxY = yIndex*fragHeight
    drawable = root.assetJson("/scripts/gb/sixthscreen2.json").drawable
    message.setHandler("setGBMode",function(_,_,t)
        setGBMode(t)
    end)
    message.setHandler("frameskipWrites",function(_,_,writes)
        if gbMode == -1 then
            return
        end
        -- just update memory, don't draw a frame
        local n = 0
        if writes.vblank then
            n = n + #writes.vblank
            commitWrites(writes.vblank)
        end
        for scanline=0,vblank-1 do
            local w = writes[string.format("sl_%d",scanline)]
            if w then
                n = n + #w
                commitWrites(w)
            end
        end
        sb.setLogMap("gbppu_r_writes",string.format("%d",n))
    end)
    message.setHandler("doFrame",function(_,_,writes)
        if gbMode == -1 then
            return nil
        end
        local time = os.clock()
        -- do the entire fragment of the frame here
        local nw = 0
        if writes.vblank then
            nw = nw + #writes.vblank
            commitWrites(writes.vblank)
        end
        local winCounter = 0
        for scanline=0,minY-1 do
            local w = writes[string.format("sl_%d",scanline)]
            if w then
                nw = nw + #w
                commitWrites(w)
            end
            local winVisible = windowEnabled and windowY >= 0 and windowY <= 143 and windowX >= 0 and windowX <= 166
            if winVisible and scanline >= windowY then
                winCounter = winCounter + 1
            end
        end
        
        for scanline=minY,maxY-1 do
            local w = writes[string.format("sl_%d",scanline)]
            if w then
                nw = nw + #w
                commitWrites(w)
            end
            
            local forcedObjPriority = not bgEnabled and (gbMode == 1)
            local bgActualEnabled = bgEnabled or (gbMode == 1)
            
            local lineObjs = {}
            local nLineObjs = 0
            local nLineObjsFull = 0
            if objEnabled then
                for i=1,40 do
                    local v = objects[i]
                    if v[2] > 0 and v[2] <= hblank+8 and scanline >= v[1]-16 and scanline < v[1]+objSize-16 then
                        nLineObjsFull = nLineObjsFull + 1
                        if v[2] > minX and v[2] <= maxX+8 then
                            nLineObjs = nLineObjs + 1
                            table.insert(lineObjs,v)
                        end
                        if nLineObjsFull >= 10 then
                            break
                        end
                    end
                end
            end
            -- I'd like to make this more efficient but hard to do so without overburdening the per-pixel code
            if oamOrdering == 1 or gbMode == 0 then
                table.sort(lineObjs,sortObjects0)
            else
                -- don't sort, just leave it to be by OAM index
            end
            
            local bgY = scrollY+scanline
            local bgIndexY = (bgY//8)%32
            
            local winY = scanline-windowY
            local winY2 = winCounter
            local winIndexY = winY//8
            local winIndexY2 = winY2//8
            local winVisible = windowEnabled and windowY >= 0 and windowY <= 143 and windowX >= 0 and windowX <= 166
            if winVisible and scanline >= windowY then
                winCounter = winCounter + 1
            end
            
            for x=minX,maxX-1 do
                if lcdOn then
                    local bgC
                    local bgP
                    local winC
                    local winP
                    local objC
                    local objP
                    local objPriority = true
                    local noObjPriority = false
                    local r,g,b = 255,255,255
                    if bgActualEnabled then
                        local bgX = scrollX+x
                        local bgIndexX = (bgX//8)%32
                        local bgI = bgIndexY*32+bgIndexX
                        local bgTileX = 7-(bgX%8)
                        local bgTileY = bgY%8
                        local bgTile = backgrounds[bgSelect+1][bgI+1]
                        local bgBank = 1
                        if tileIndexMode == 0 then
                            bgTile = 256 + sign8(bgTile)
                        end
                        if gbMode == 1 then
                            local bgAttributes = backgroundAttributes[bgSelect+1][bgI+1]
                            if bgAttributes.priority then
                                noObjPriority = true
                            end
                            bgBank = bgAttributes.vramBank
                            if bgAttributes.xFlip then
                                bgTileX = 7-bgTileX
                            end
                            if bgAttributes.yFlip then
                                bgTileY = 7-bgTileY
                            end
                            bgP = bgAttributes.palette
                        end
                        bgC = tiles[bgBank][bgTile+1][bgTileY*8+bgTileX+1]
                        --b = math.floor(bgTile/384*255)
                    end
                    if windowEnabled then
                        local winX = x+7-windowX
                        local winIndexX = winX//8
                        if winIndexX >= 0 and winIndexY >= 0 and winIndexX < 32 and winIndexY2 < 32 then
                            local winI = winIndexY2*32+winIndexX
                            local winTileX = 7-(winX%8)
                            local winTileY = winY2%8
                            local winTile = backgrounds[windowSelect+1][winI+1]
                            local winBank = 1
                            if tileIndexMode == 0 then
                                winTile = 256 + sign8(winTile)
                            end
                            if gbMode == 1 then
                                local winAttributes = backgroundAttributes[windowSelect+1][winI+1]
                                if winAttributes.priority then
                                    noObjPriority = true
                                end
                                winBank = winAttributes.vramBank
                                if winAttributes.xFlip then
                                    winTileX = 7-winTileX
                                end
                                if winAttributes.yFlip then
                                    winTileY = 7-winTileY
                                end
                                winP = winAttributes.palette
                            end
                            winC = tiles[winBank][winTile+1][winTileY*8+winTileX+1]
                        end
                    end
                    for i=1,nLineObjs do
                        local obj = lineObjs[i]
                        if x >= obj[2]-8 and  x < obj[2] then
                            -- draw the object
                            -- always uses the lower indexes
                            local objBank = 1
                            if gbMode == 1 then
                                objBank = obj[4].vramBank
                            end
                            local tileX = x-obj[2]+8
                            if not obj[4].xFlip then
                                tileX = 7-tileX
                            end
                            local tileY = scanline-obj[1]+16
                            if obj[4].yFlip then
                                if objSize > 8 then
                                    tileY = 15-tileY
                                else
                                    tileY = 7-tileY
                                end
                            end
                            local tileIndex = obj[3]
                            if objSize > 8 then
                                tileIndex = tileIndex & 0xfe
                            end
                            local tile
                            if tileY > 7 and objSize > 8 then
                                tileY = tileY - 8
                                tile = tiles[objBank][tileIndex+2]
                            else
                                tile = tiles[objBank][tileIndex+1]
                            end
                            objC = tile[tileY*8+tileX+1]
                            objPriority = obj[4].priority
                            --[[if (tileY < 0 or tileY >= 8) or (tileX < 0 or tileX >= 8) then
                                objP = nil
                                objC = 3
                            else]]
                            objP = obj[4].palette
                            --end
                            if objC ~= 1 then
                                break
                            end
                        end
                    end
                    local c = winC or bgC or 0
                    local p = winP or bgP or 1
                    local isObj = false
                    if noObjPriority then
                        objPriority = true
                    end
                    if objC and objC ~= 1 then
                        if forcedObjPriority or not objPriority or c == 1 then
                            isObj = true
                        end
                    end
                    if isObj then
                        r,g,b = objPalette(objC,objP)
                    else
                        r,g,b = palette(c,p)
                    end
                    --[[
                    if w then
                        r = 255-r
                    end]]
                    setPixel(x,scanline,r,g,b)
                else
                    --[[if w then
                        setPixel(x,scanline,0,255,255)
                    else
                        setPixel(x,scanline,255,255,255)
                    end]]
                    setPixel(x,scanline,255,255,255)
                end
            end
        end
        for scanline=maxY,vblank-1 do
            local w = writes[string.format("sl_%d",scanline)]
            if w then
                nw = nw + #w
                commitWrites(w)
            end
        end
        sb.setLogMap("gbppu_r_writes",string.format("%d",nw))
        
        --[[
        sb.setLogMap("gbppu_r_scanline",string.format("%d",scanline))
        sb.setLogMap("gbppu_r_lcdEnabled",sb.print(lcdOn))
        sb.setLogMap("gbppu_r_tileMode",sb.print(tileIndexMode))
        sb.setLogMap("gbppu_r_bgEnabled",sb.print(bgEnabled))
        sb.setLogMap("gbppu_r_bgSelect",string.format("%d",bgSelect))
        sb.setLogMap("gbppu_r_bgScroll",string.format("[%d,%d]",scrollX,scrollY))
        sb.setLogMap("gbppu_r_winEnabled",sb.print(windowEnabled))
        sb.setLogMap("gbppu_r_winSelect",string.format("%d",windowSelect))
        sb.setLogMap("gbppu_r_winPos",string.format("[%d,%d]",windowX,windowY))
        sb.setLogMap("gbppu_r_objEnabled",sb.print(objEnabled))
        sb.setLogMap("gbppu_r_objSize",string.format("%d",objSize))
        ]]
        local out = string.format(drawable,table.unpack(pixels))
        sb.setLogMap(string.format("gbppu_%s_renderTime",myName),string.format("%.4f",os.clock()-time))
        --[[if gbMode == 1 then
            local test = ""
            local test2 = ""
            for i=1,64 do
                test = test..string.format("%02x",colourMem[i])
                test2 = test2..string.format("%02x",colourMem[i+64])
            end
            sb.setLogMap("gbppu_cm_bcgColourMem",test)
            sb.setLogMap("gbppu_cm_objColourMem",test2)
        end]]
        return out
    end)
    script.setUpdateDelta(0)
end
function update()
    -- actually, do nothing
end
