require "/scripts/terra_base64.lua"

loader = {}
local bankSize = 0x4000
local sramBankSize = 0x2000
local bankNums = {
    2,
    4,
    8,
    16,
    32,
    64,
    128,
    256,
    [53]=72,
    [54]=80,
    [55]=96
}
local sBankNums = {
    0,
    1,
    1,
    4
}
function loader.loadAsMemComponent(p,save)
    local headerOff = 0
    save = save or {}
    local ds = root.assetData(p)
    local d = {}
    local sram = nil
    if save.sram then
        sram = base64ToOctets(save.sram)
    end
    for i=1,#ds do
        d[i] = string.byte(ds,i)
    end
    ds = nil
    local rom = {
        bank = 1,
        unmoddedBank = 1,
        banks = bankNums[d[0x0148+1+headerOff]+1],
        sramBanks = sBankNums[d[0x0149+1+headerOff]+1],
        sramBank = 0,
        sram=sram,
        sramEnabled=false,
        rtcRegisters = {
            0,
            0,
            0,
            0,
            0
        },
        rtcSelected = 0,
        rtcLatch = 0,
        rtcEpoch=save.rtcTime or os.time(),
        rtcHaltTime=save.rtcTime or 0,
        rtcHalt=save.rtcHalt,
        sramIsRtc=false, -- also used for IR on HuC1
        timer = false,
        battery = false,
        rumble = false,
        sensor=false,
        bankSwitched=false,
        sgb = d[0x0146+1+headerOff] == 0x03,
        cgb = (d[0x0143+1+headerOff] & 0x80) > 0
    }
    local function rtcTimer()
        if rom.rtcHalt then
            return rom.rtcHaltTime
        else
            return os.time()-rom.rtcEpoch
        end
    end
    if not sram then
        sram = jarray()
        for i=1,sramBankSize*rom.sramBanks do
            table.insert(sram,0xff)
        end
        rom.sram = sram
    end
    local switcher = "none"
    
    -- realistically emulate bank mirroring by binary ANDing target bank
    local bankANDOp = 2^binutil.minBits(rom.banks)-1
    local sramBankANDOp = 2^binutil.minBits(rom.sramBanks)-1
    
    -- unfortunately I cannot implement sub-second RTC functionality without sacrificing the real-time nature of the clock
    -- due to the limitations of Lua's time values, which don't have milliseconds
    -- range tests could be implemented later tho
    
    local bankMode = 0
    local writeFuncs = {
        none=function(a,v)
            if a >= 0xa000 and sram and rom.sramEnabled then
                sram[a-0x9FFF] = v
            end
        end,
        mbc1=function(a,v)
            if a < 0x2000 then
                local e = (v & 0x0F) == 0xA
                rom.sramEnabled = e
            elseif a < 0x4000 then
                local lowerBits = v & 0x1f
                local upperBits = rom.unmoddedBank & 0x60
                if lowerBits == 0 then
                    lowerBits = 1
                end
                rom.unmoddedBank = lowerBits | upperBits
                rom.bank = rom.unmoddedBank & bankANDOp
            elseif a < 0x6000 then
                if bankMode == 0 then
                    local lowerBits = rom.unmoddedBank & 0x1f
                    local upperBits = (v & 0x03) << 5
                    rom.unmoddedBank = lowerBits | upperBits
                    rom.bank = rom.unmoddedBank & bankANDOp
                else
                    rom.sramBank = v & sramBankANDOp
                end
            elseif a < 0x8000 then
                bankMode = v & 1
            elseif sram and rom.sramEnabled then
                -- sram
                sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1] = v
            end
        end,
        mbc2=function(a,v)
            if a < 0x4000 then
                if (a & 0x0100) > 0 then
                    local lowerBits = v & 0x0f
                    if lowerBits == 0 then
                        lowerBits = 1
                    end
                    rom.unmoddedBank = lowerBits
                    rom.bank = rom.unmoddedBank & bankANDOp
                else
                    local e = (v & 0x0F) == 0xA
                    rom.sramEnabled = e
                end
            elseif a < 0x6000 then
                if bankMode == 0 then
                    local lowerBits = rom.unmoddedBank & 0x1f
                    local upperBits = (v & 0x03) << 5
                    rom.unmoddedBank = lowerBits | upperBits
                    rom.bank = rom.unmoddedBank & bankANDOp
                else
                    rom.sramBank = v & sramBankANDOp
                end
            elseif a < 0x8000 then
                bankMode = v & 1
            elseif sram and rom.sramEnabled then
                -- sram
                sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1] = v
            end
        end,
        mbc3=function(a,v)
            if a < 0x2000 then
                local e = (v & 0x0F) == 0xA
                rom.sramEnabled = e
            elseif a < 0x4000 then
                if v & bankANDOp == 00 then
                    rom.bank = 1
                else
                    rom.bank = v & bankANDOp
                end
            elseif a < 0x6000 then
                if rom.timer and (v & 0x08 > 0) then
                    -- rtc register select
                    rom.rtcSelected = v & 0x7
                    rom.sramIsRtc = true
                else
                    rom.sramBank = v & sramBankANDOp & 0x03
                    rom.sramIsRtc = false
                end
            elseif a < 0x8000 then
                if rom.timer then
                    if rom.rtcLatch == 0 and v == 1 then
                        local tSince = rtcTimer()
                        rom.rtcRegisters[1] = math.floor(tSince)%60
                        rom.rtcRegisters[2] = math.floor(tSince/60)%60
                        rom.rtcRegisters[3] = math.floor(tSince/3600)%24
                        rom.rtcRegisters[4] = math.floor(tSince/86400)&0xff
                        local day = math.floor(tSince/86400)
                        local carry = day > 0x1ff
                        rom.rtcRegisters[5] = 
                            (day&0x100) >> 8
                            | bit(rom.rtcHalt) << 6
                            | bit(carry) << 7
                    end
                    rom.rtcLatch = v
                end
            elseif (sram or rom.sramIsRtc) and rom.sramEnabled then
                -- sram
                if rom.sramIsRtc and rom.timer then
                    local tSince = rtcTimer()
                    local sec = math.floor(tSince)%60
                    local min = math.floor(tSince/60)%60
                    local hour = math.floor(tSince/3600)%24
                    local day = math.floor(tSince/86400)
                    local dayTrunc = day&0x1ff
                    local dayTrunc2 = day&0xff
                    --local off = v-oreg
                    local reg = v
                    if rom.rtcSelected == 0x00 then
                        -- seconds
                        local off = v-sec
                        rom.rtcEpoch = rom.rtcEpoch - off
                        rom.rtcHaltTime = rom.rtcHaltTime + off
                    elseif rom.rtcSelected == 0x01 then
                        -- minutes
                        local off = v-min
                        rom.rtcEpoch = rom.rtcEpoch - off*60
                        rom.rtcHaltTime = rom.rtcHaltTime + off*60
                    elseif rom.rtcSelected == 0x02 then
                        -- hours
                        local off = v-hour
                        rom.rtcEpoch = rom.rtcEpoch - off*3600
                        rom.rtcHaltTime = rom.rtcHaltTime + off*3600
                    elseif rom.rtcSelected == 0x03 then
                        -- days
                        local off = v-dayTrunc2
                        rom.rtcEpoch = rom.rtcEpoch - off*86400
                        rom.rtcHaltTime = rom.rtcHaltTime + off*86400
                    elseif rom.rtcSelected == 0x04 then
                        
                        -- some flags
                        local halt = (v & 0x40) > 0
                        local carry = (v & 0x80) > 0
                        local oldCarry = day > dayTrunc
                        local wasHalt = rom.rtcHalt
                        if halt and not wasHalt then
                            rom.rtcHaltTime = tSince
                            rom.rtcHalt = true
                        elseif wasHalt and not halt then
                            rom.rtcEpoch = os.time()-rom.rtcHaltTime
                            rom.rtcHalt = false
                        end
                        
                        if not carry and oldCarry then
                            while day > dayTrunc do
                                day = day - 0x200
                                rom.rtcEpoch = rom.rtcEpoch + 44236800
                                rom.rtcHaltTime = rom.rtcHaltTime - 44236800
                            end
                        elseif carry and not oldCarry then
                            rom.rtcEpoch = rom.rtcEpoch - 44236800
                            rom.rtcHaltTime = rom.rtcHaltTime + 44236800
                        end
                        
                        -- days top bit
                        if ((dayTrunc & 0x100) >> 8) ~= (v & 0x01) then
                            if v == 0x00 then
                                rom.rtcEpoch = rom.rtcEpoch + 22118400
                                rom.rtcHaltTime = rom.rtcHaltTime - 22118400
                            else
                                rom.rtcEpoch = rom.rtcEpoch - 22118400
                                rom.rtcHaltTime = rom.rtcHaltTime + 22118400
                            end
                        end
                        local newDay = math.floor(rtcTimer()/86400)
                        reg = (newDay&0x100) >> 8
                            | bit(rom.rtcHalt) << 6
                            | bit(newDay > 0x1ff) << 7
                    end
                    if rom.rtcSelected == 0x04 then
                        --sb.logInfo(string.format("rtc register 4 written, %02x",reg))
                    else
                        --sb.logInfo(string.format("rtc register %d modified %02x, diff %d, time diff %d", rom.rtcSelected, v, off, rom.rtcHaltTime-tSince))
                    end
                    rom.rtcRegisters[rom.rtcSelected+1] = reg
                else
                    sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1] = v
                end
            end
        end,
        mbc4=function(a,v)
            -- very likely to be incorrect
            if a < 0x2000 then
                local e = (v & 0x0F) == 0xA
                rom.sramEnabled = e
            elseif a < 0x4000 then
                if v & bankANDOp == 00 then
                    rom.bank = 1
                else
                    rom.bank = v & bankANDOp
                end
            elseif a < 0x6000 then
                rom.sramBank = v & sramBankANDOp & 0x03
            elseif a < 0x8000 then
            elseif sram and rom.sramEnabled then
                -- sram
                sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1] = v
            end
        end,
        mbc5=function(a,v)
            if a < 0x2000 then
                local e = (v & 0x0F) == 0xA
                rom.sramEnabled = e
            elseif a < 0x3000 then
                local lowerBits = v & 0xff
                local upperBits = rom.unmoddedBank & 0x100
                rom.unmoddedBank = lowerBits | upperBits
                rom.bank = rom.unmoddedBank & bankANDOp
            elseif a < 0x4000 then
                local lowerBits = rom.unmoddedBank & 0xff
                local upperBits = (v & 0x01) << 8
                rom.unmoddedBank = lowerBits | upperBits
                rom.bank = rom.unmoddedBank & bankANDOp
            elseif a < 0x6000 then
                if rom.rumble then
                    rom.sramBank = v & sramBankANDOp & 0x07
                    -- v & 0x08 is rumble
                else
                    rom.sramBank = v & sramBankANDOp & 0x0f
                end
            elseif a < 0x8000 then
                bankMode = v & 1
            elseif sram and rom.sramEnabled then
                -- sram
                sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1] = v
            end
        end,
        mbc6=nil, -- TODO
        mbc7=nil, -- TODO
        mmm01=nil, -- TODO
        m161=function(a)
            if a < 0x8000 and not rom.bankSwitched then
                rom.bank = v & bankANDOp & 0x7
                rom.bankSwitched = true
            else
            end
        end,
        huc1=function(a,v)
            if a < 0x2000 then
                local e = (v & 0x0F) == 0xE
                rom.sramIsRtc = e
            elseif a < 0x4000 then
                local lowerBits = v & 0x3f
                if lowerBits == 0 then
                    lowerBits = 1
                end
                rom.bank = lowerBits & bankANDOp
            elseif a < 0x6000 then
                rom.sramBank = v & sramBankANDOp & 0x03
            elseif a < 0x8000 then
            elseif sram and not rom.sramIsRtc then
                -- sram
                sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1] = v
            end
        end,
        huc3=nil -- TODO
    }
    local readFuncs = {
        none=function(a) 
            if a < 0x8000 then
                return d[a+1]
            elseif sram and rom.sramEnabled then
                return sram[a-0x7FFF]
            else
                return 0xFF
            end
        end,
        mbc1=function(a)
            if a < 0x4000 then
                return d[a+1]
            elseif a < 0x8000 then
                return d[(bankSize*rom.bank)+(a-0x4000)+1]
            elseif sram and rom.sramEnabled then
                -- sram
                return sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1]
            else
                return 0xFF
            end
        end,
        mbc2=function(a)
            if a < 0x4000 then
                return d[a+1]
            elseif a < 0x8000 then
                return d[(bankSize*rom.bank)+(a-0x4000)+1]
            elseif sram and rom.sramEnabled then
                -- sram
                return (sram[((a-0xa000) & 0x1ff)+1] & 0x0f) | (math.random(0,0xf) << 4)
            else
                return 0xFF
            end
        end,
        mbc3=function(a)
            if a < 0x4000 then
                return d[a+1]
            elseif a < 0x8000 then
                return d[(bankSize*rom.bank)+(a-0x4000)+1]
            elseif (sram or rom.sramIsRtc) and rom.sramEnabled then
                -- sram
                if rom.sramIsRtc and rom.timer then
                    return rom.rtcRegisters[rom.rtcSelected+1]
                else
                    return sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1]
                end
            else
                return 0xFF
            end
        end,
        mbc4=function(a)
            if a < 0x4000 then
                return d[a+1]
            elseif a < 0x8000 then
                return d[(bankSize*rom.bank)+(a-0x4000)+1]
            elseif sram and rom.sramEnabled then
                -- sram
                return sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1]
            else
                return 0xFF
            end
        end,
        mbc5=function(a)
            if a < 0x4000 then
                return d[a+1]
            elseif a < 0x8000 then
                return d[(bankSize*rom.bank)+(a-0x4000)+1]
            elseif sram and rom.sramEnabled then
                -- sram
                return sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1]
            else
                return 0xFF
            end
        end,
        -- TODO: mbc6 works VERY differently
        mbc6=nil,
        -- TODO: mbc7
        mbc7=nil,
        -- TODO: mmm01 stores its header differently
        mmm01=nil,
        m161=function(a)
            if a < 0x8000 then
                return d[(bankSize*2*rom.bank)+a+1]
            else
                return 0xFF
            end
        end,
        huc1=function(a)
            if a < 0x4000 then
                return d[a+1]
            elseif a < 0x8000 then
                return d[(bankSize*rom.bank)+(a-0x4000)+1]
            elseif (sram or rom.sramIsRtc) and rom.sramEnabled then
                if rom.sramIsRtc then
                    -- IR sensor
                    return 0xc0 -- TODO: maybe ask Starbound?
                else
                    -- sram
                    return sram[(sramBankSize*rom.sramBank)+(a-0xa000)+1]
                end
            else
                return 0xFF
            end
        end,
        huc3=nil -- TODO
    }
    local mCycleFuncs = {}
    local resetFuncs = {
        m161=function()
            rom.bankSwitched = false
            rom.bank = 0
        end
    }
    -- TODO: wisdomtree, ems, bung use a different system
    -- also, mmm01 stores its type at the last 32kib instead, and that's also the default banks
    local t = d[0x0147+1+headerOff] -- ROM type
    switcher = "none"
    if t == 0x00 then
        switcher = "none"
        sram = nil
    elseif t == 0x01 then
        switcher = "mbc1"
        sram = nil
    elseif t == 0x02 then
        switcher = "mbc1"
    elseif t == 0x03 then
        switcher = "mbc1"
        rom.battery = true
    elseif t == 0x05 then
        switcher = "mbc2"
        sram = nil
    elseif t == 0x06 then
        switcher = "mbc2"
        rom.battery = true
        sram = nil
    elseif t == 0x08 then
        switcher = "none"
    elseif t == 0x09 then
        switcher = "none"
        rom.battery = true
    elseif t == 0x0B then
        switcher = "mmm01"
        sram = nil
    elseif t == 0x0C then
        switcher = "mmm01"
    elseif t == 0x0D then
        switcher = "mmm01"
        rom.battery = true
    elseif t == 0x0F then
        switcher = "mbc3"
        rom.timer = true
        rom.battery = true
        sram = nil
    elseif t == 0x10 then
        switcher = "mbc3"
        rom.battery = true
        rom.timer = true
    elseif t == 0x11 then
        switcher = "mbc3"
        sram = nil
    elseif t == 0x12 then
        switcher = "mbc3"
    elseif t == 0x13 then
        switcher = "mbc3"
        rom.battery = true
    elseif t == 0x15 then
        switcher = "mbc4"
        sram = nil
    elseif t == 0x16 then
        switcher = "mbc4"
    elseif t == 0x17 then
        switcher = "mbc4"
        rom.battery = true
    elseif t == 0x19 then
        switcher = "mbc5"
        sram = nil
    elseif t == 0x1A then
        switcher = "mbc5"
    elseif t == 0x1B then
        switcher = "mbc5"
        rom.battery = true
    elseif t == 0x1C then
        switcher = "mbc5"
        sram = nil
        rom.rumble = true
    elseif t == 0x1D then
        switcher = "mbc5"
        rom.rumble = true
    elseif t == 0x1E then
        switcher = "mbc5"
        rom.battery = true
        rom.rumble = true
    elseif t == 0x20 then
        switcher = "mbc6"
    elseif t == 0x22 then
        switcher = "mbc7"
        rom.battery = true
        rom.rumble = true
        rom.sensor = true
    elseif t == 0xfc then
        switcher = "pocketcamera"
    elseif t == 0xfd then
        switcher = "tama5"
    elseif t == 0xfe then
        switcher = "huc3"
        sram = nil
    elseif t == 0xff then
        switcher = "huc1"
        rom.battery = true
    else
        sb.logWarn(string.format("Unknown/unsupported ROM type %02x", t))
    end
    if not readFuncs[switcher] then
        sb.logWarn(string.format("Unsupported ROM switcher %s", switcher))
    end
    
    rom.read = readFuncs[switcher]
    rom.write = writeFuncs[switcher]
    rom.update = mCycleFuncs[switcher] or function(c,cycles) end
    rom.reset = resetFuncs[switcher] or function() end
    if not rom.read or not rom.write then
        sb.logWarn(string.format("Unsupported ROM switcher %s", switcher))
        return nil
    end
    local features = ""
    if rom.battery then
        features = features.." battery"
    end
    if rom.rumble then
        features = features.." rumble"
    end
    if rom.timer then
        features = features.." timer"
    end
    if rom.sram then
        features = features.." sram"
    end
    function rom.debug()
        sb.setLogMap("gbrom_switcher",switcher)
        sb.setLogMap("gbrom_features",features)
        sb.setLogMap("gbrom_romBank",string.format("%02x",rom.bank))
        sb.setLogMap("gbrom_sramBank",rom.sramIsRtc and (rom.timer and string.format("rtc%d",rom.rtcSelected) or "ir") or string.format("%02x",rom.sramBank))
        sb.setLogMap("gbrom_sramEnabled",sb.print(rom.sramEnabled))
        if rom.timer then
            sb.setLogMap("gbrom_rtcRegisters",string.format("%02x, %02x, %02x, %02x, %02x (%d selected)",
                rom.rtcRegisters[1],rom.rtcRegisters[2],rom.rtcRegisters[3],rom.rtcRegisters[4],rom.rtcRegisters[5],
                rom.rtcSelected))
            sb.setLogMap("gbrom_rtcTime",string.format("%d",rtcTimer()))
            sb.setLogMap("gbrom_rtcEpoch",rom.rtcHalt and string.format("%d (halted)",os.time()-rom.rtcHaltTime) or string.format("%d",rom.rtcEpoch))
        end
        --sb.setLogMap("gbrom_sramIsRtc",sb.print(rom.sramIsRtc))
    end
    function rom.getGBMode()
        --return 0
        return rom.cgb and 1 or 0
    end
    function rom.warn()
        sb.logWarn(string.format("romBank: %02x", rom.bank))
    end
    function rom.getSave()
        return {
            sram=octetsToBase64(rom.sram),
            rtcHalt=rom.rtcHalt,
            rtcTime=rom.rtcHalt and rom.rtcHaltTime or rom.rtcEpoch
        }
    end
    return rom
end
