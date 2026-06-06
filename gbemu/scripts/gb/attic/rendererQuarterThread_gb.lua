require "/scripts/gb/utils.lua"

local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end

local minX = 0
local maxX = 0
local minY = 0
local maxY = 0

local objects = {}
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

-- there are 40 objects
for i=1,40 do
    objects[i] = {0,0,0,{
        priority=true,
        xFlip=false,
        yFlip=false,
        palette=0
    }}
end

-- in GB, is array of 4 numbers
-- in CGB, TODO
local palettes = {}
local objPalettes = {}

-- 0 = gb, 1 = gbc
local gbMode = -1
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
local m = 0
local scm = 0
local lcdOn = true
local objSize = 0
local w=2
local h=2
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
        return table.unpack(gbPalette[palettes[c+1]+1])
    else
        sb.logWarn("Attempting to render in CGB/uninitialized mode!")
        -- TODO
    end
end
local function objPalette(c,p)
    if gbMode == 0 then
        return table.unpack(gbPalette[objPalettes[p][c+1]+1])
    else
        sb.logWarn("Attempting to render in CGB/uninitialized mode!")
        -- TODO
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
        memWrite(v[1],v[2])
    end
end

function memWrite(addr,v)
    if addr <= 0x9fff then
        -- vram
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
        local i = (addr&0xfc) >> 2
        local i2 = addr&0x03
        local obj = objects[i+1]
        if i2 == 3 then
            obj[4].priority = (v & 0x80) > 0
            obj[4].yFlip = (v & 0x40) > 0
            obj[4].xFlip = (v & 0x20) > 0
            obj[4].palette = ((v & 0x10) >> 4)+1
        else
            obj[i2+1] = v
        end
    elseif addr == 0xff47 and gbMode == 0 then
        palettes[4] = (v >> 6) & 3
        palettes[3] = (v >> 4) & 3
        palettes[2] = (v >> 2) & 3
        palettes[1] = v & 3
    elseif addr == 0xff48 and gbMode == 0 then
        objPalettes[1][4] = (v >> 6) & 3
        objPalettes[1][3] = (v >> 4) & 3
        objPalettes[1][2] = (v >> 2) & 3
        objPalettes[1][1] = v & 3
    elseif addr == 0xff49 and gbMode == 0 then
        objPalettes[2][4] = (v >> 6) & 3
        objPalettes[2][3] = (v >> 4) & 3
        objPalettes[2][2] = (v >> 2) & 3
        objPalettes[2][1] = v & 3
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
        palettes = {3,2,1,0}
        objPalettes = {
            {3,2,1,0},
            {3,2,1,0}
        }
    elseif gbMode == 1 then
        -- todo: CGB palettes
        palettes = {}
        objPalettes = {}
    end
end

-- GBC doesn't need to render every frame as long as game logic runs in background
-- note: if just sending the entirety of VRAM is more efficient than sending the data to render, and processing at the other end is more efficient, do so

-- I use M-cycles here
function init()
    local myName = config.getParameter("gbRenderName")
    if config.getParameter("upperX") then
        minX = hblank/2
        maxX = hblank
    else
        minX = 0
        maxX = hblank/2
    end
    if config.getParameter("upperY") then
        minY = vblank/2
        maxY = vblank
    else
        minY = 0
        maxY = vblank/2
    end
    drawable = root.assetJson("/scripts/gb/quarterscreen.json").drawable
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
        for scanline=0,vblank do
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
        -- do the entire quarter frame here
        local nw = 0
        if writes.vblank then
            nw = nw + #writes.vblank
            commitWrites(writes.vblank)
        end
        for scanline=0,minY do
            local w = writes[string.format("sl_%d",scanline)]
            if w then
                nw = nw + #w
                commitWrites(w)
            end
        end
        for scanline=minY,maxY-1 do
            local w = writes[string.format("sl_%d",scanline)]
            if w then
                nw = nw + #w
                commitWrites(w)
            end
            local lineObjs = {}
            local nLineObjs = 0
            if objEnabled then
                for i=1,40 do
                    local v = objects[i]
                    if v[2] > minX and v[2] <= maxX+8 and scanline >= v[1]-16 and scanline < v[1]+objSize-16 then
                        nLineObjs = nLineObjs + 1
                        table.insert(lineObjs,v)
                        if nLineObjs >= 10 then
                            break
                        end
                    end
                end
            end
            -- I'd like to make this more efficient but hard to do so without overburdening the per-pixel code
            table.sort(lineObjs,function(a,b) return a[2] < b[2] end)
            
            for x=minX,maxX-1 do
                if lcdOn then
                    local bgC
                    local winC
                    local objC
                    local objP
                    local objPriority = true
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
                        bgC = tiles[bgTile+1][bgTileY*8+bgTileX+1]
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
                            winC = tiles[winTile+1][winTileY*8+winTileX+1]
                            --if c ~= 0 then
                                --b = math.floor(winTile/384*255)
                            --end
                        end
                    end
                    for i=1,nLineObjs do
                        local obj = lineObjs[i]
                        if x >= obj[2]-8 and  x < obj[2] then
                            -- draw the object
                            -- always uses the lower indexes
                            local tileX = x-obj[2]+8
                            if not obj[4].xFlip then
                                tileX = 7-tileX
                            end
                            local tileY = scanline-obj[1]+16
                            if obj[4].yFlip then
                                tileY = 7-tileY
                            end
                            local tile
                            if tileY > 7 and objSize > 8 then
                                tileY = tileY - 8
                                tile = tiles[obj[3]+2]
                            else
                                tile = tiles[obj[3]+1]
                            end
                            objC = tile[tileY*8+tileX+1]
                            objPriority = obj[4].priority
                            --[[if (tileY < 0 or tileY >= 8) or (tileX < 0 or tileX >= 8) then
                                objP = nil
                                objC = 3
                            else]]
                            objP = obj[4].palette
                            --end
                            if objC ~= 0 then
                                break
                            end
                        end
                    end
                    local c = winC or bgC or 0
                    local p = 0
                    local isObj = false
                    if objC and objC ~= 0 then
                        if not objPriority or c == 0 then
                            isObj = true
                        end
                    end
                    if isObj then
                        r,g,b = objPalette(objC,objP)
                    else
                        r,g,b = palette(c)
                    end
                    setPixel(x,scanline,r,g,b)
                else
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
        return out
    end)
    script.setUpdateDelta(0)
end
function update()
    -- actually, do nothing
end
