
local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end
local function join(a,b)
    return a << 8 | b
end
-- I use M-cycles here

function initApu()
    local soundThread = threads.create({
            name="gameboySound",
            scripts={
                main={"/scripts/gb/soundThread.lua"}
            },
            tickRate=120,
            instructionLimit=100000000,
        })
        
    local framePromises = {}
        
    local apu = {}
    
    local frameWrites = {}
    local function requestFrame()
        if #framePromises > 0 then
            threads.sendMessage(soundThread,"frameskipWrites",frameWrites)
        else
            table.insert(framePromises,threads.sendMessage(soundThread,"doFrame",frameWrites))
        end
        frameWrites = {}
    end
    
    local soundOn = false
    local ch1Timer = 0
    local ch2Timer = 0
    local ch3Timer = 0
    local ch4Timer = 0
    local ch1TimerPre = 0
    local ch2TimerPre = 0
    local ch3TimerPre = 0
    local ch4TimerPre = 0
    
    -- 0 = gb, 1 = gbc
    local gbMode = 0
    
    local ioRegs = {}
    for i=1,0x80 do
        ioRegs[i] = 0x00
    end
    
    function apu.read(addr)
        if addr == 0xff13 or addr == 0xff18 or addr == 0xff1d or addr == 0xff1b or addr == 0xff20 then
            -- write only registers
            return 0xff
        elseif addr == 0xff11 or addr == 0xff16 then
            -- only upper 2 bits are readable
            return ioRegs[(addr&0x007f)+1] | 0x3f
        elseif addr == 0xff14 or addr == 0xff19 or addr == 0xff1e or addr == 0xff23 then
            -- only bit 6 is readable
            return ioRegs[(addr&0x007f)+1] | 0xbf
        elseif addr == 0xff26 then
            return bit(soundOn) << 7
            | bit(ch4Timer ~= 0) << 3
            | bit(ch3Timer ~= 0) << 2
            | bit(ch2Timer ~= 0) << 1
            | bit(ch1Timer ~= 0)
            | 0x70
        else
            return ioRegs[(addr&0x007f)+1]
        end
    end
    function apu.write(addr,v)
        table.insert(frameWrites,{addr,v})
        if addr == 0xff26 then
            soundOn = (v & 0x80) > 0
            if not soundOn then
                for k,v in next, ioRegs do
                    ioRegs[k] = 0x00
                end
                ch1TimerPre = 0
                ch2TimerPre = 0
                ch3TimerPre = 0
                ch4TimerPre = 0
                ch1Timer = 0
                ch2Timer = 0
                ch3Timer = 0
                ch4Timer = 0
            end
        end
        if soundOn then
            if addr == 0xff11 then
                ch1TimerPre = math.floor((64-(v & 0x3f))*16383.984375) | 0 -- estimated machine cycles in a second
            elseif addr == 0xff16 then
                ch2TimerPre = math.floor((64-(v & 0x3f))*16383.984375) | 0
            elseif addr == 0xff1b then
                ch3TimerPre = math.floor((256-v)*16383.984375) | 0
            elseif addr == 0xff20 then
                ch4TimerPre = math.floor((64-(v & 0x3f))*16383.984375) | 0
            elseif addr == 0xff14 then
                local initial = (v & 0x80) > 0
                local sel = (v & 0x40) > 0
                if initial then
                    if sel then
                        ch1Timer = ch1TimerPre
                    else
                        ch1Timer = -1
                    end
                end
            elseif addr == 0xff19 then
                local initial = (v & 0x80) > 0
                local sel = (v & 0x40) > 0
                if initial then
                    if sel then
                        ch2Timer = ch2TimerPre
                    else
                        ch2Timer = -1
                    end
                end
            elseif addr == 0xff1e then
                local initial = (v & 0x80) > 0
                local sel = (v & 0x40) > 0
                if initial then
                    if sel then
                        ch3Timer = ch3TimerPre
                    else
                        ch3Timer = -1
                    end
                end
            elseif addr == 0xff23 then
                local initial = (v & 0x80) > 0
                local sel = (v & 0x40) > 0
                if initial then
                    if sel then
                        ch4Timer = ch4TimerPre
                    else
                        ch4Timer = -1
                    end
                end
            end
            ioRegs[(addr&0x007f)+1] = v
        end
    end
    
    local lastDoInterrupt = false
    function apu.update(c,cycles)
        if ch1Timer > 0 then
            ch1Timer = math.max(ch1Timer-cycles,0)
        end
        if ch2Timer > 0 then
            ch2Timer = math.max(ch2Timer-cycles,0)
        end
        if ch3Timer > 0 then
            ch3Timer = math.max(ch3Timer-cycles,0)
        end
        if ch4Timer > 0 then
            ch4Timer = math.max(ch4Timer-cycles,0)
        end
    end
    function apu.setGBMode(t)
        --threads.sendMessage(soundThread,"setGBMode",t)
        gbMode = t
    end
    function apu.debug()
        sb.setLogMap("gbapu_waitingFrames",string.format("%d",#framePromises))
    end
    
    -- TODO
    function apu.getFrameSound()
        local nFramePromises = {}
        for k,v in next, framePromises do
            if v:finished() then
                if v:succeeded() then
                end
            else
                table.insert(nFramePromises,v)
            end
        end
        framePromises = nFramePromises
    end
    return apu
end
