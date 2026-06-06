
-- util functions that are unrelated to the rom
local function nop() return 1 end
local function join(a,b)
    return a << 8 | b
end
local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end
local function invEndian(n)
    return
          n & 0x80 >> 7
        | n & 0x40 >> 5
        | n & 0x20 >> 3
        | n & 0x10 >> 1
        | n & 0x08 << 1
        | n & 0x04 << 3
        | n & 0x02 << 5
        | n & 0x01 << 7
end
function initCpu(bus,gb)
    local gbMode = -1
    local cpu = {}
    local stopped = false
    local speedSwitchRequested = false
    local fastMode = false
    local autoHaltExit = false
    local autoHaltExitTimer = 0
    -- internal
    local noInterrupts = false
    local halted = false
    local nextInterrupt = nil
    -- RAM values
    local hram = {}
    for i=1,127 do
        hram[i] = math.random(0,255)
    end
    local ier = 0x00
    local waitingInterrupts = 0x00
    -- registers
    local sp = 0xFFFE
    local pc = 0x0100
    local r = {
        0x01, -- a (1) (a value of 0x11 indicates CGB/GBA)
        0xb0, -- f (2)
        0x00, -- b (3)
        0x13, -- c (4)
        0x00, -- d (5)
        0xd8, -- e (6)
        0x01, -- h (7)
        0x4d -- l (8)
    }
    -- F util funcs
    -- also forces F's lower 4 bits to be 0, which they should be
    local function setZ(n)
        r[2] = r[2] & 0x70 | (0x80*n)
    end
    local function setC(n)
        r[2] = r[2] & 0xe0 | (0x10*n)
    end
    local function setN(n)
        r[2] = r[2] & 0xb0 | (0x40*n)
    end
    local function setH(n)
        r[2] = r[2] & 0xd0 | (0x20*n)
    end
    local function getZ()
        return (r[2] & 0x80) > 0
    end
    local function getH()
        return (r[2] & 0x20) > 0
    end
    local function getN()
        return (r[2] & 0x40) > 0
    end
    local function getC()
        return (r[2] & 0x10) > 0
    end
    local function getCi()
        return (r[2] & 0x10) >> 4
    end
    local instrv1 = 0
    local instrv2 = 0
    local currentInstruction = nil
    local instructionMCycle = 1
    -- util funcs
    local function inc16(r1,r2)
        r[r2] = r[r2] + 1
        if r[r2] == 256 then
            r[r1] = r[r1] + 1
            r[r2] = 0
        end
        if r[r1] == 256 then
            r[r1] = 0
        end
    end
    local function dec16(r1,r2)
        r[r2] = r[r2] - 1
        if r[r2] == -1 then
            r[r1] = r[r1] - 1
            r[r2] = 255
        end
        if r[r1] == -1 then
            r[r1] = 255
        end
    end
    local function push(a,b)
        sp = (sp - 2)&0xffff
        bus.write(sp, b)
        bus.write(sp+1, a)
    end
    local function push16(n)
        push((n & 0xff00) >> 8, n & 0x00ff)
    end
    local function pop()
        sp = (sp + 2) & 0xffff
        return bus.read(sp-1),bus.read(sp-2)
    end
    local function pop16()
        return join(pop())
    end
    local function call(a)
        push16(pc+1)
        pc = a - 1
    end
    local function sub8r(r1,n)
        setN(1)
        if (r[r1] & 0xf) - (n & 0xf) < 0 then
            setH(1)
        else
            setH(0)
        end
        r[r1] = r[r1] - n
        if r[r1] < 0 then
            r[r1] = r[r1] & 0xff
            setC(1)
        else
            setC(0)
        end
        if r[r1] == 0 then
            setZ(1)
        else
            setZ(0)
        end
    end
    local function sbc8r(r1,n,o)
        setN(1)
        if (r[r1] & 0xf) - (n & 0xf) - o < 0 then
            setH(1)
        else
            setH(0)
        end
        r[r1] = r[r1] - n - o
        if r[r1] < 0 then
            r[r1] = r[r1] & 0xff
            setC(1)
        else
            setC(0)
        end
        if r[r1] == 0 then
            setZ(1)
        else
            setZ(0)
        end
    end
    local function add8r(r1,n)
        setN(0)
        if (r[r1] & 0xf) + (n & 0xf) > 0xf then
            setH(1)
        else
            setH(0)
        end
        r[r1] = r[r1] + n
        if r[r1] >= 256 then
            r[r1] = r[r1] & 0xff
            setC(1)
        else
            setC(0)
        end
        if r[r1] == 0 then
            setZ(1)
        else
            setZ(0)
        end
    end
    local function adc8r(r1,n,o)
        setN(0)
        if (r[r1] & 0xf) + (n & 0xf) + o > 0xf then
            setH(1)
        else
            setH(0)
        end
        r[r1] = r[r1] + n + o
        if r[r1] >= 256 then
            r[r1] = r[r1] & 0xff
            setC(1)
        else
            setC(0)
        end
        if r[r1] == 0 then
            setZ(1)
        else
            setZ(0)
        end
    end
    
    -- instruction templates
    local function ldrrxxyy(r1,r2)
        return  
            function()
                pc = pc + 2
                r[r1] = bus.read(pc)
                r[r2] = bus.read(pc-1)
                return 3
            end
        
    end
    local function ldrxx(r1)
        return 
            function()
                pc = pc + 1
                r[r1] = bus.read(pc)
                return 2
            end
        
    end
    local function ldatrr_r(r1,r2,r3)
        return
            function()
                bus.write(join(r[r1],r[r2]), r[r3])
                return 2
            end
    
    end
    local function ldr_atrr(r1,r2,r3)
        return
            function()
                r[r1] = bus.read(join(r[r2],r[r3]))
                return 2
            end
    
    end
    local function ldr_r(r1,r2)
        return 
            function()
                r[r1] = r[r2]
                return 1
            end
    
    end
    local function ldiatrr_r(r1,r2,r3)
        return 
            function()
                bus.write(join(r[r1],r[r2]), r[r3])
                inc16(r1,r2)
                return 2
            end
    
    end
    local function ldir_atrr(r1,r2,r3)
        return
            function()
                r[r1] = bus.read(join(r[r2],r[r3]))
                inc16(r2,r3)
                return 2
            end
    
    end
    local function lddatrr_r(r1,r2,r3)
        return 
            function()
                bus.write(join(r[r1],r[r2]), r[r3])
                dec16(r1,r2)
                return 2
            end
    
    end
    local function lddr_atrr(r1,r2,r3)
        return 
            function()
                r[r1] = bus.read(join(r[r2],r[r3]))
                dec16(r2,r3)
                return 2
            end
    
    end
    local function incrr(r1, r2)
        return
            function()
                inc16(r1,r2)
                return 2
            end
    
    end
    local function decrr(r1, r2)
        return
            function()
                dec16(r1,r2)
                return 2
            end
    
    end
    local function incr(r1)
        return
            function()
                setN(0)
                r[r1] = r[r1] + 1
                if r[r1] == 256 then
                    r[r1] = 0
                    setZ(1)
                else
                    setZ(0)
                end
                if r[r1] & 0xf == 0 then
                    setH(1)
                else
                    setH(0)
                end
                return 1
            end
    
    end
    local function decr(r1)
        return
            function()
                setN(1)
                r[r1] = r[r1] - 1
                if r[r1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                if r[r1] == -1 then
                    r[r1] = 255
                end
                if r[r1] & 0xf == 0xf then
                    setH(1)
                else
                    setH(0)
                end
                return 1
            end
    
    end
    local function addrr_rr(r1,r2,r3,r4)
        return
            function()
                setN(0)
                r[r2] = r[r2] + r[r4]
                local o = 0
                if r[r2] >= 256 then
                    r[r2] = r[r2] & 0xff
                    o = 1
                end
                if (r[r1] & 0xf) + (r[r3] & 0xf) + o > 15 then
                    setH(1)
                else
                    setH(0)
                end
                r[r1] = r[r1] + r[r3] + o
                if r[r1] >= 256 then
                    r[r1] = r[r1] & 0xff
                    setC(1)
                else
                    setC(0)
                end
                return 2
            end
    
    end
    local function addr_r(r1,r2)
        return
            function()
                add8r(r1,r[r2])
                return 1
            end
    
    end
    local function adcr_r(r1,r2)
        return
            function()
                adc8r(r1, r[r2],getCi())
                return 1
            end
    
    end
    local function subr_r(r1,r2)
        return
            function()
                sub8r(r1, r[r2])
                return 1
            end
    
    end
    local function sbcr_r(r1,r2)
        return
            function()
                sbc8r(r1, r[r2], getCi())
                return 1
            end
    
    end
    local function jr()
        return
            function()
                pc = pc + 1
                pc = pc + sign8(bus.read(pc))
                return 3
            end
    
    end
    local function jrc(f,inv)
        return
            function()
                pc = pc + 1
                if f() == (not inv) then
                    pc = pc + sign8(bus.read(pc))
                    return 3
                else
                    return 2
                end
            end
    
    end
    local function jp()
        return
            function()
                pc = join(bus.read(pc+2),bus.read(pc+1))-1
                return 4
            end
    
    end
    local function jpc(f,inv)
        return
            function()
                if f() == (not inv) then
                    pc = join(bus.read(pc+2),bus.read(pc+1))-1
                    return 4
                else
                    pc = pc + 2
                    return 3
                end
            end
    
    end
    local function callt()
        return
            function()
                pc = pc + 2
                call(join(bus.read(pc),bus.read(pc-1)))
                return 6
            end
    
    end
    local function callc(f,inv)
        return
            function()
                pc = pc + 2
                if f() == (not inv) then
                    call(join(bus.read(pc),bus.read(pc-1)))
                    return 6
                else
                    return 3
                end
            end
    
    end
    local function rst(t)
        return
            function()
                call(t)
                return 4
            end
    
    end
    local function ret()
        return
            function()
                pc = pop16()-1
                return 4
            end
    
    end
    local function reti()
        return
            function()
                pc = pop16()-1
                noInterrupts = false
                return 4
            end
    
    end
    local function retc(f,inv)
        return
            function()
                if f() == (not inv) then
                    pc = pop16()-1
                    return 5
                else
                    return 2
                end
            end
    
    end
    local function andr_r(r1,r2)
        return
            function()
                r[r1] = r[r1] & r[r2]
                r[2] = 0x20
                if r[r1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 1
            end
    
    end
    local function xorr_r(r1,r2)
        return
            function()
                r[r1] = r[r1] ~ r[r2]
                r[2] = 0x00
                if r[r1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 1
            end
    
    end
    local function orr_r(r1,r2)
        return
            function()
                r[r1] = r[r1] | r[r2]
                r[2] = 0x00
                if r[r1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 1
            end
    
    end
    local function cpr_r(r1,r2)
        return
            function()
                setN(1)
                local v = r[r1] - r[r2]
                if (r[r1] & 0xf) - (r[r2] & 0xf) < 0 then
                    setH(1)
                else
                    setH(0)
                end
                if v < 0 then
                    v = v & 0xff
                    setC(1)
                else
                    setC(0)
                end
                if v == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 1
            end
    
    end
    local function pushrr(r1,r2)
        return
            function()
                push(r[r1],r[r2])
                return 4
            end
    
    end
    local function poprr(r1,r2)
        return
            function()
                r[r1],r[r2] = pop()
                return 3
            end
    
    end
    
    local undefined = function() return 1 end
    -- the actual instruction list
    local instructions = {
        --0x00
        nop, -- nop
        ldrrxxyy(3,4), -- ld bc, $xxyy
        ldatrr_r(3,4,1), -- ld [bc], a
        incrr(3,4), -- inc bc
        incr(3), -- inc b
        decr(3), -- dec b
        ldrxx(3), -- ld b, $xx
            -- rlca
            function ()
                local s = r[1] << 1 -- left shift
                local c = (s & 0x100) >> 8 -- get carry (AND with 100000000 to get bit 8)
                r[1] = (s & 0xfe) | c -- OR carry with left shifted byte (11111110 | 00000001 = 11111111)
                r[2] = 0 -- clear f
                setC(c)
                return 1
            end,
            -- ld [$xxyy], sp
            function()
                pc = pc + 2
                instrv1 = bus.read(pc)
                instrv2 = bus.read(pc-1)
                bus.write(join(instrv1,instrv2)+1,(sp & 0xff00) >> 8)
                bus.write(join(instrv1,instrv2),sp & 0xff)
                return 5
            end,
        addrr_rr(7,8,3,4), -- add hl, bc
        ldr_atrr(1,3,4), -- ld a, [bc]
        decrr(3,4), -- dec bc
        incr(4), -- inc c
        decr(4), -- dec c
        ldrxx(4), -- ld c, $xx
            -- rrca
            function ()
                local s = r[1] >> 1 -- right shift
                local c = r[1] & 1 -- get carry (AND with 100000000 to get bit 8)
                r[1] = s | (c << 7) -- OR carry with right shifted byte (01111111 | 10000000 = 11111111) (ANDing is unnecessary here as right shift in Lua truncates bits shifted to bit <0
                r[2] = 0 -- clear f
                setC(c)
                return 1
            end,
        -- 0x10
            -- stop
            function()
                if gb.isInputHeldAndSelected() then
                    if waitingInterrupts & ier > 0 then
                        -- do nothing
                    else
                        -- 2-byte halt
                        halted = true
                        pc = pc + 1
                    end
                elseif gbMode == 1 and speedSwitchRequested then
                    if waitingInterrupts & ier > 0 then
                        if noInterrupts then
                            gb.resetDiv()
                            fastMode = not fastMode
                        else
                            -- TODO: non-deterministic CPU glitch?
                        end
                    else
                        pc = pc + 1
                        halted = true
                        autoHaltExit = true
                        autoHaltExitTimer = 0x20000/4
                        gb.resetDiv()
                        fastMode = not fastMode
                    end
                elseif waitingInterrupts & ier > 0 then
                    stopped = true
                    gb.resetDiv()
                else
                    pc = pc + 1
                    stopped = true
                    gb.resetDiv()
                end
                return 1
            end,
        ldrrxxyy(5,6), -- ld de, $xxyy
        ldatrr_r(5,6,1), -- ld [de], a
        incrr(5,6), -- inc de
        incr(5), -- inc d
        decr(5), -- dec d
        ldrxx(5), -- ld d, $xx
            -- rla
            function ()
                local s = r[1] << 1 -- left shift
                local c = (s & 0x100) >> 8 -- get carry (AND with 100000000 to get bit 8)
                r[1] = (s & 0xfe) | ((r[2] & 0x10) >> 4) -- OR old carry with left shifted byte (11111110 | 00000001 = 11111111)
                r[2] = 0 -- clear f
                setC(c)
                return 1
            end,
        jr(), -- jr $xx
        addrr_rr(7,8,5,6), -- add hl, de
        ldr_atrr(1,5,6), -- ld a, [de]
        decrr(5,6), -- dec de
        incr(6), -- inc e
        decr(6), -- dec e
        ldrxx(6), -- ld e, $xx
            -- rra
            function ()
                local s = r[1] >> 1 -- right shift
                local c = r[1] & 1 -- get carry (AND with 100000000 to get bit 8)
                r[1] = s | ((r[2] & 0x10) << 3) -- OR old carry with right shifted byte (01111111 | 10000000 = 11111111) (ANDing is unnecessary here as right shift in Lua truncates bits shifted to bit <0
                r[2] = 0 -- clear f
                setC(c)
                return 1
            end,
        -- 0x20
        jrc(getZ,true), -- jr nz, $xx
        ldrrxxyy(7,8), -- ld hl, $xxyy
        ldiatrr_r(7,8,1), -- ldi [hl], a
        incrr(7,8), -- inc hl
        incr(7), -- inc h
        decr(7), -- dec h
        ldrxx(7), -- ld h, $xx
            -- daa
            function ()
                local off = 0
                local subf = getN()
                local a = r[1]
                if (a & 0xf > 0x9 and not subf) or getH() then
                    off = off | 0x6
                end
                if (a > 0x99 and not subf) or getC() then
                    off = off | 0x60
                    setC(1)
                else
                    setC(0)
                end
                setH(0)
                if subf then
                    off = off * -1
                end
                a = (a + off) & 0xff
                setZ(a == 0 and 1 or 0)
                r[1] = a
                return 1
            end,
        jrc(getZ,false), -- jr z, $xx
        addrr_rr(7,8,7,8), -- add hl, hl
        ldir_atrr(1,7,8), -- ldi a, [hl]
        decrr(7,8), -- dec hl
        incr(8), -- inc l
        decr(8), -- dec l
        ldrxx(8), -- ld l, $xx
            -- cpl
            function ()
                setH(1)
                setN(1)
                r[1] = r[1] ~ 0xff
                return 1
            end,
        -- 0x30
        jrc(getC,true), -- jr nc, $xx
            -- ld sp, $xxyy
            function()
                pc = pc + 2
                sp = join(bus.read(pc),bus.read(pc-1))
                return 3
            end,
        lddatrr_r(7,8,1), -- ldd [hl], a
            -- inc sp
            function()
                sp = (sp + 1) & 0xffff
                return 2
            end, 
            -- inc (hl)
            function()
                setN(0)
                local v = bus.read(join(r[7],r[8]))+1
                if v == 256 then
                    v = 0
                    setZ(1)
                else
                    setZ(0)
                end
                if v & 15 == 0 then
                    setH(1)
                else
                    setH(0)
                end
                bus.write(join(r[7],r[8]), v)
                return 3
            end,
            -- dec (hl)
            function()
                setN(1)
                local v = bus.read(join(r[7],r[8]))-1
                if v == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                if v == -1 then
                    v = 0xff
                end
                if v & 0xf == 0xf then
                    setH(1)
                else
                    setH(0)
                end
                bus.write(join(r[7],r[8]), v)
                return 3
            end,
            -- ld (hl), $xx
            function()
                pc = pc + 1
                bus.write(join(r[7],r[8]), bus.read(pc))
                return 3
            end,
            -- scf
            function ()
                setN(0)
                setH(0)
                setC(1)
                return 1
            end,
        jrc(getC,false), -- jr c, $xx
            -- add hl, sp
            function()
                setN(0)
                r[8] = r[8] + (sp & 0xff)
                local o = 0
                if r[8] >= 256 then
                    r[8] = r[8] & 0xff
                    o = 1
                end
                local l = (sp & 0xff00) >> 8
                if (r[7] & 0xf) + (l & 0xf) + o >= 16 then
                    setH(1)
                else
                    setH(0)
                end
                r[7] = r[7] + l + o
                if r[7] >= 256 then
                    r[7] = r[7] & 0xff
                    setC(1)
                else
                    setC(0)
                end
                return 2
            end, 
        lddr_atrr(1,7,8), -- ldd a, [hl]
            -- dec sp
            function()
                sp = (sp - 1) & 0xffff
                return 2
            end, 
        incr(1), -- inc a
        decr(1), -- dec a
        ldrxx(1), -- ld a, $xx
            -- ccf
            function ()
                setN(0)
                setH(0)
                setC(getCi() ~ 1)
                return 1
            end,
        -- 0x40
        ldr_r(3,3), -- ld b,b
        ldr_r(3,4), -- ld b,c
        ldr_r(3,5), -- ld b,d
        ldr_r(3,6), -- ld b,e
        ldr_r(3,7), -- ld b,h
        ldr_r(3,8), -- ld b,l
        ldr_atrr(3,7,8), -- ld b, [hl]
        ldr_r(3,1), -- ld b,a
        ldr_r(4,3), -- ld c,b
        ldr_r(4,4), -- ld c,c
        ldr_r(4,5), -- ld c,d
        ldr_r(4,6), -- ld c,e
        ldr_r(4,7), -- ld c,h
        ldr_r(4,8), -- ld c,l
        ldr_atrr(4,7,8), -- ld c, [hl]
        ldr_r(4,1), -- ld c,a
        -- 0x50
        ldr_r(5,3), -- ld d,b
        ldr_r(5,4), -- ld d,c
        ldr_r(5,5), -- ld d,d
        ldr_r(5,6), -- ld d,e
        ldr_r(5,7), -- ld d,h
        ldr_r(5,8), -- ld d,l
        ldr_atrr(5,7,8), -- ld d, [hl]
        ldr_r(5,1), -- ld d,a
        ldr_r(6,3), -- ld e,b
        ldr_r(6,4), -- ld e,c
        ldr_r(6,5), -- ld e,d
        ldr_r(6,6), -- ld e,e
        ldr_r(6,7), -- ld e,h
        ldr_r(6,8), -- ld e,l
        ldr_atrr(6,7,8), -- ld e, [hl]
        ldr_r(6,1), -- ld e,a
        -- 0x60
        ldr_r(7,3), -- ld h,b
        ldr_r(7,4), -- ld h,c
        ldr_r(7,5), -- ld h,d
        ldr_r(7,6), -- ld h,e
        ldr_r(7,7), -- ld h,h
        ldr_r(7,8), -- ld h,l
        ldr_atrr(7,7,8), -- ld h, [hl]
        ldr_r(7,1), -- ld h,a
        ldr_r(8,3), -- ld l,b
        ldr_r(8,4), -- ld l,c
        ldr_r(8,5), -- ld l,d
        ldr_r(8,6), -- ld l,e
        ldr_r(8,7), -- ld l,h
        ldr_r(8,8), -- ld l,l
        ldr_atrr(8,7,8), -- ld l, [hl]
        ldr_r(8,1), -- ld l,a
        -- 0x70
        ldatrr_r(7,8,3), -- ld [hl],b
        ldatrr_r(7,8,4), -- ld [hl],c
        ldatrr_r(7,8,5), -- ld [hl],d
        ldatrr_r(7,8,6), -- ld [hl],e
        ldatrr_r(7,8,7), -- ld [hl],h
        ldatrr_r(7,8,8), -- ld [hl],l
            -- halt
            function()
                halted = true
                return 1
            end, 
        ldatrr_r(7,8,1), -- ld [hl],a
        ldr_r(1,3), -- ld a,b
        ldr_r(1,4), -- ld a,c
        ldr_r(1,5), -- ld a,d
        ldr_r(1,6), -- ld a,e
        ldr_r(1,7), -- ld a,h
        ldr_r(1,8), -- ld a,l
        ldr_atrr(1,7,8), -- ld a, [hl]
        ldr_r(1,1), -- ld a,a
        -- 0x80
        addr_r(1,3), -- add a,b
        addr_r(1,4), -- add a,c
        addr_r(1,5), -- add a,d
        addr_r(1,6), -- add a,e
        addr_r(1,7), -- add a,h
        addr_r(1,8), -- add a,a
            -- add a, [hl]
            function()
                add8r(1, bus.read(join(r[7],r[8])))
                return 2
            end,
        addr_r(1,1), -- add a,l
        adcr_r(1,3), -- adc a,b
        adcr_r(1,4), -- adc a,c
        adcr_r(1,5), -- adc a,d
        adcr_r(1,6), -- adc a,e
        adcr_r(1,7), -- adc a,h
        adcr_r(1,8), -- adc a,l
            -- adc a, [hl]
            function()
                adc8r(1, bus.read(join(r[7],r[8])),getCi())
                return 2
            end,
        adcr_r(1,1), -- adc a,a
        -- 0x90
        subr_r(1,3), -- sub a,b
        subr_r(1,4), -- sub a,c
        subr_r(1,5), -- sub a,d
        subr_r(1,6), -- sub a,e
        subr_r(1,7), -- sub a,h
        subr_r(1,8), -- sub a,a
            -- sub a, [hl]
            function()
                sub8r(1, bus.read(join(r[7],r[8])))
                return 2
            end,
        subr_r(1,1), -- sub a,l
        sbcr_r(1,3), -- sbc a,b
        sbcr_r(1,4), -- sbc a,c
        sbcr_r(1,5), -- sbc a,d
        sbcr_r(1,6), -- sbc a,e
        sbcr_r(1,7), -- sbc a,h
        sbcr_r(1,8), -- sbc a,l
            -- sbc a, [hl]
            function()
                sbc8r(1, bus.read(join(r[7],r[8])), getCi())
                return 2
            end,
        sbcr_r(1,1), -- sbc a,a
        -- 0xa0
        andr_r(1,3), -- and a,b
        andr_r(1,4), -- and a,c
        andr_r(1,5), -- and a,d
        andr_r(1,6), -- and a,e
        andr_r(1,7), -- and a,h
        andr_r(1,8), -- and a,a
            -- and a, [hl]
            function()
                r[1] = r[1] & bus.read(join(r[7],r[8]))
                r[2] = 0x20
                if r[1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        andr_r(1,1), -- and a,l
        xorr_r(1,3), -- xor a,b
        xorr_r(1,4), -- xor a,c
        xorr_r(1,5), -- xor a,d
        xorr_r(1,6), -- xor a,e
        xorr_r(1,7), -- xor a,h
        xorr_r(1,8), -- xor a,l
            -- xor a, [hl]
            function()
                r[1] = r[1] ~ bus.read(join(r[7],r[8]))
                r[2] = 0x00
                if r[1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        xorr_r(1,1), -- xor a,a
        -- 0xb0
        orr_r(1,3), -- or a,b
        orr_r(1,4), -- or a,c
        orr_r(1,5), -- or a,d
        orr_r(1,6), -- or a,e
        orr_r(1,7), -- or a,h
        orr_r(1,8), -- or a,l
            -- or a, [hl]
            function()
                r[1] = r[1] | bus.read(join(r[7],r[8]))
                r[2] = 0x00
                if r[1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        orr_r(1,1), -- or a,a
        cpr_r(1,3), -- cp a,b
        cpr_r(1,4), -- cp a,c
        cpr_r(1,5), -- cp a,d
        cpr_r(1,6), -- cp a,e
        cpr_r(1,7), -- cp a,h
        cpr_r(1,8), -- cp a,l
            -- cp a, [hl]
            function()
                setN(1)
                local re = bus.read(join(r[7],r[8]))
                local v = r[1] - re
                if (r[1] & 0xf) - (re & 0xf) < 0 then
                    setH(1)
                else
                    setH(0)
                end
                if v < 0 then
                    v = v & 0xff
                    setC(1)
                else
                    setC(0)
                end
                if v == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        cpr_r(1,1), -- cp a,a
        -- 0xc0
        retc(getZ,true), -- ret nz
        poprr(3,4), -- pop bc
        jpc(getZ, true), -- jp nz, $xxyy
        jp(), -- jp $xxyy
        callc(getZ, true), -- call nz, $xxyy
        pushrr(3,4), -- push bc
            -- add a, $xx
            function()
                pc = pc + 1
                add8r(1,bus.read(pc))
                return 2
            end,
        rst(0x0000), -- rst 00h
        retc(getZ,false), -- ret z
        ret(), -- ret
        jpc(getZ,false), -- jp z, $xxyy
            -- CB PREFIX
            function()
                -- target register
                pc = pc + 1
                instrv1 = bus.read(pc)
                local re = instrv1 & 0x07
                re = re + 3
                if re == 10 then
                    re = 1
                end
                if instrv1 & 0x80 > 0 then
                    -- RES or SET
                    -- target bit value
                    local v = (instrv1 & 0x40) >> 6
                    -- target bit
                    local b = (instrv1 & 0x38) >> 3
                    if re == 9 then
                        -- (hl)
                        local mv = bus.read(join(r[7],r[8]))
                        if v > 0 then
                            mv = mv | (1 << b)
                        else
                            mv = mv & (1 << b ~ 0xff)
                        end
                        bus.write(join(r[7],r[8]), mv & 0xff)
                    else
                        if v > 0 then
                            r[re] = (r[re] | (1 << b)) & 0xff
                        else
                            r[re] = (r[re] & (1 << b ~ 0xff)) & 0xff
                        end
                    end
                else
                    if instrv1 & 0x40 > 0 then
                        -- BIT
                        setN(0)
                        setH(1)
                        
                        local b = (instrv1 & 0x38) >> 3
                        if re == 9 then
                            -- (hl)
                            setZ((bus.read(join(r[7],r[8])) >> b) & 1 ~ 1)
                        else
                            setZ((r[re] >> b) & 1 ~ 1)
                        end
                    else
                        -- Rdc,SdA,SWAP,SRL
                        local mv
                        if re == 9 then
                            mv = bus.read(join(r[7],r[8]))
                        else
                            mv = r[re]
                        end
                        if instrv1 & 0x20 > 0 then
                            r[2] = 0
                            -- SdA,SWAP,SRL
                            if instrv1 & 0x10 > 0 then
                                -- SWAP, SRL
                                if instrv1 & 0x08 > 0 then
                                    -- SRL
                                    local s = mv >> 1 -- right shift
                                    local c = mv & 1 -- get carry (AND original number with 1 to get s bit -1)
                                    mv = s -- do not fill in new bit
                                    setC(c)
                                else
                                    -- SWAP
                                    mv = ((mv & 0xf0) >> 4) | ((mv & 0x0f) << 4)
                                end
                            else
                                -- SdA
                                local d = instrv1 & 0x08 > 0 -- true = R, false = L
                                if d then
                                    -- SRA
                                    local s = mv >> 1 -- right shift
                                    local c = mv & 1 -- get carry (AND original number with 1 to get s bit -1)
                                    mv = s | (mv & 0x80) -- OR with bit 0 of original number
                                    setC(c)
                                else
                                    -- SLA
                                    local s = mv << 1 -- left shift
                                    local c = (s & 0x100) >> 8 -- get carry (AND with 100000000 to get bit 8)
                                    mv = (s & 0xfe) -- AND to get rid of the excess bits
                                    setC(c)
                                end
                            end
                        else
                            -- Rdc
                            local cm = instrv1 & 0x10 > 0 -- true = Rd, false = RdC
                            local d = instrv1 & 0x08 > 0 -- true = R, false = L
                            if cm then
                                if d then
                                    -- RR
                                    local s = mv >> 1 -- right shift
                                    local c = mv & 1 -- get carry (AND original number with 1 to get s bit -1)
                                    mv = s | ((r[2] & 0x10) << 3) -- OR old carry with right shifted byte (01111111 | 10000000 = 11111111) (ANDing is unnecessary here as right shift in Lua truncates bits shifted to bit <0
                                    r[2] = 0
                                    setC(c)
                                else
                                    -- RL
                                    local s = mv << 1 -- left shift
                                    local c = (s & 0x100) >> 8 -- get carry (AND with 100000000 to get bit 8)
                                    mv = (s & 0xfe) | ((r[2] & 0x10) >> 4) -- OR old carry with left shifted byte (11111110 | 00000001 = 11111111)
                                    r[2] = 0
                                    setC(c)
                                end
                            else
                                r[2] = 0
                                if d then
                                    -- RRC
                                    local s = mv >> 1 -- right shift
                                    local c = mv & 1 -- get carry (AND original number with 1 to get s bit -1)
                                    mv = s | (c << 7) -- OR carry with right shifted byte (01111111 | 10000000 = 11111111) (ANDing is unnecessary here as right shift in Lua truncates bits shifted to bit <0
                                    setC(c)
                                else
                                    -- RLC
                                    local s = mv << 1 -- left shift
                                    local c = (s & 0x100) >> 8 -- get carry (AND with 100000000 to get bit 8)
                                    mv = (s & 0xfe) | c -- OR carry with left shifted byte (11111110 | 00000001 = 11111111)
                                    setC(c)
                                end
                            end
                        end
                        if mv == 0 then
                            setZ(1)
                        else
                            setZ(0)
                        end
                        if re == 9 then
                            bus.write(join(r[7],r[8]),mv & 0xff)
                        else
                            r[re] = mv & 0xff
                        end
                    end
                end
                if re ~= 9 then -- (hl)
                    return 2
                end
                return 3
            end,
        callc(getZ,false), -- call z, $xxyy
        callt(), -- call $xxyy
            -- adc a, $xx
            function()
                pc = pc + 1
                adc8r(1,bus.read(pc),getCi())
                return 2
            end,
        rst(0x0008), -- rst 08h
        -- 0xd0
        retc(getC,true), -- ret nc
        poprr(5,6), -- pop de
        jpc(getC, true), -- jp nc, $xxyy
        undefined, -- undefined
        callc(getC, true), -- call nc, $xxyy
        pushrr(5,6), -- push de
            -- sub a, $xx
            function()
                pc = pc + 1
                sub8r(1,bus.read(pc))
                return 2
            end,
        rst(0x0010), -- rst 10h
        retc(getC,false), -- ret c
        reti(), -- reti
        jpc(getC,false), -- jp c, $xxyy
        undefined, -- undefined
        callc(getC,false), -- call c, $xxyy
        undefined, -- undefined
            -- sbc a, $xx
            function()
                pc = pc + 1
                sbc8r(1,bus.read(pc),getCi())
                return 2
            end,
        rst(0x0018), -- rst 18h
        -- 0xe0
            -- ld ($ffxx), a
            function()
                pc = pc + 1
                bus.write(0xff00 | bus.read(pc), r[1])
                return 3
            end,
        poprr(7,8), -- pop hl
            -- ld ($ff00+c), a
            function()
                bus.write(0xff00 | r[4], r[1])
                return 2
            end,
        undefined, -- undefined
        undefined, -- undefined
        pushrr(7,8), -- push hl
            -- and a, $xx
            function()
                pc = pc + 1
                r[1] = r[1] & bus.read(pc)
                r[2] = 0x20
                if r[1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        rst(0x0020), -- rst 20h
            -- add sp, $xx
            function()
                r[2] = 0
                pc = pc + 1
                local rv = bus.read(pc)
                if (sp & 0xf) + (rv & 0xf) > 0xf then
                    setH(1)
                else
                    setH(0)
                end
                if (sp & 0xff) + (rv & 0xff) > 0xff then
                    setC(1)
                else
                    setC(0)
                end
                sp = (sp + sign8(rv)) & 0xffff
                return 4
            end,
            -- jp hl
            function()
                pc = join(r[7],r[8])-1
                return 1
            end,
            -- ld ($xxyy), a
            function()
                pc = pc + 2
                bus.write(join(bus.read(pc),bus.read(pc-1)),r[1])
                return 4
            end,
        undefined, -- undefined
        undefined, -- undefined
        undefined, -- undefined
            -- xor a, $xx
            function()
                pc = pc + 1
                r[1] = r[1] ~ bus.read(pc)
                r[2] = 0x00
                if r[1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        rst(0x0028), -- rst 28h
        -- 0xf0
            -- ld a, ($ffxx)
            function()
                pc = pc + 1
                r[1] = bus.read(0xff00 | bus.read(pc))
                return 3
            end,
            function() -- pop af
                local a,f = pop()
                r[1] = a
                r[2] = f & 0xf0
                return 3
            end,
            -- ld a, ($ff00+c)
            function()
                r[1] = bus.read(0xff00 | r[4])
                return 2
            end,
            -- di
            function()
                noInterrupts = true
                return 1
            end,
        undefined, -- undefined
        pushrr(1,2), -- push af
            -- or a, $xx
            function()
                pc = pc + 1
                r[1] = r[1] | bus.read(pc)
                r[2] = 0x00
                if r[1] == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        rst(0x0030), -- rst 30h
            -- ld hl, sp+$xx
            function()
                pc = pc + 1
                r[2] = 0
                local rv = bus.read(pc)
                local v = sp + sign8(rv)
                if (sp & 0xf) + (rv & 0xf) > 0xf then
                    setH(1)
                else
                    setH(0)
                end
                if (sp & 0xff) + (rv & 0xff) > 0xff then
                    setC(1)
                else
                    setC(0)
                end
                r[7] = (v & 0xff00) >> 8
                r[8] = v & 0x00ff
                return 3
            end,
            -- ld sp, hl
            function()
                sp = join(r[7],r[8])
                return 2
            end,
            -- ld a, ($xxyy)
            function()
                pc = pc + 2
                r[1] = bus.read(join(bus.read(pc),bus.read(pc-1)))
                return 4
            end,
            -- ei
            function()
                noInterrupts = false
                return 1
            end,
        undefined, -- undefined
        undefined, -- undefined
            -- cp a, $xx
            function()
                pc = pc + 1
                setN(1)
                local v = r[1] - bus.read(pc)
                if (r[1] & 0xf) - (v & 0xf) < 0 then
                    setH(1)
                else
                    setH(0)
                end
                if v < 0 then
                    v = v & 0xff
                    setC(1)
                else
                    setC(0)
                end
                if v == 0 then
                    setZ(1)
                else
                    setZ(0)
                end
                return 2
            end,
        rst(0x0038), -- rst 38h
    }
    function cpu.interrupt(i)
        if i == 4 then
            if gbMode == 1 then
                -- apparently joypad interrupt doesn't work on GBC?
                return
            end
        end
        if (ier >> i) & 1 ~= 0 then
            halted = false
            autoHaltExit = false
        end
        if currentInstruction == undefined or noInterrupts or ((ier >> i) & 1 == 0) then
            waitingInterrupts = waitingInterrupts | (1 << i)
            return
        end
        noInterrupts = true
        nextInterrupt = 0x0040 + 0x08*i
    end
    function cpu.read(addr)
        if addr == 0xffff then
            return ier
        elseif addr == 0xff0f then
            return waitingInterrupts | 0xe0
        elseif addr == 0xff4d then
            if gbMode == 1 then
                return 0x7e
                    | bit(fastMode) << 7
                    | bit(speedSwitchRequested)
            else
                return 0xff
            end
        else
            return hram[addr-0xFF7F]
        end
    end
    function cpu.write(addr, v)
        if addr == 0xffff then
            ier = v&0x1f
        elseif addr == 0xff0f then
            waitingInterrupts = v&0x1f
        elseif addr == 0xff4d then
            if gbMode == 1 then
                speedSwitchRequested = (v & 0x01) > 0
            end
        else
            hram[addr-0xFF7F] = v
        end
    end
    function cpu.update()
        if stopped then
            return 1
        end
        if not (noInterrupts or currentInstruction == undefined) and waitingInterrupts & ier > 0 then
            local w = waitingInterrupts & ier
            for i=0,4 do
                if (w >> i) & 1 > 0 then
                    waitingInterrupts = waitingInterrupts ~ (1 << i)
                    cpu.interrupt(i)
                end
            end
        end
        if halted then
            return -1
        end
        if nextInterrupt then
            push16(pc)
            pc = nextInterrupt
            nextInterrupt = nil
        end
        local i = bus.read(pc)
        currentInstruction = instructions[i+1]
        if not currentInstruction then
            sb.logWarn("CPU found null instruction!")
            sb.logInfo(i)
            sb.logInfo(pc)
            currentInstruction = undefined
            return 1
        elseif currentInstruction == undefined then
            return 8 -- do nothing; unknown opcode
        else
            local cycles = currentInstruction()
            pc = pc + 1
            if fastMode then
                cycles = cycles * 0.5
            end
            return cycles
        end
    end
    function cpu.untilHaltExit()
        if autoHaltExit then
            return autoHaltExitTimer
        else
            return 2^256
        end
    end
    function cpu.updateAutoHalt(c)
        if autoHaltExit then
            autoHaltExitTimer = autoHaltExitTimer - c
            if autoHaltExitTimer <= 0 then
                autoHaltExit = false
                halted = false
            end
        end
    end
    function cpu.speedMult()
        if fastMode then
            return 2
        else
            return 1
        end
    end
    function cpu.speedMultConj()
        if fastMode then
            return 0.5
        else
            return 1
        end
    end
    function cpu.isDoubleSpeed()
        return fastMode
    end
    function cpu.setGBMode(t)
        gbMode = t
        fastMode = false
        if t == 0 then
            r[1] = 0x01
        elseif t == 1 then
            r[1] = 0x11
            r[3] = 0x00
        end
    end
    function cpu.warn()
        sb.logWarn(string.format("pc: %04x",pc))
    end
    function cpu.debug()
        sb.setLogMap("gbcpu_r_pc",string.format("%04x",pc))
        sb.setLogMap("gbcpu_r_sp",string.format("%04x",sp))
        --[[
        sb.setLogMap("gbcpu_r_a",string.format("%02x",r[1]))
        sb.setLogMap("gbcpu_r_f",string.format("%02x",r[2]))
        sb.setLogMap("gbcpu_r_b",string.format("%02x",r[3]))
        sb.setLogMap("gbcpu_r_c",string.format("%02x",r[4]))
        sb.setLogMap("gbcpu_r_d",string.format("%02x",r[5]))
        sb.setLogMap("gbcpu_r_e",string.format("%02x",r[6]))
        sb.setLogMap("gbcpu_r_h",string.format("%02x",r[7]))
        sb.setLogMap("gbcpu_r_l",string.format("%02x",r[8]))
        ]]
        sb.setLogMap("gbcpu_ier", hexToBinary(string.format("%02x",ier)))
        sb.setLogMap("gbcpu_st_undefined", sb.print(currentInstruction == undefined))
        sb.setLogMap("gbcpu_st_halted", sb.print(halted))
        sb.setLogMap("gbcpu_st_noInterrupts", sb.print(noInterrupts))
        sb.setLogMap("gbcpu_st_stopped", sb.print(stopped))
        sb.setLogMap("gbcpu_st_waitingInterrupts", hexToBinary(string.format("%02x",waitingInterrupts)))
        sb.setLogMap("gbcpu_st_fast", sb.print(fastMode))
    end
    
    local function yielder(maxTime)
        local time = os.clock()
        if not maxTime then maxTime = 0.015 end
        return function(force)
            if os.clock()-time > maxTime or force then
                coroutine.yield()
                time = os.clock()
            end
        end
    end
    local testsEnabled = false
    function cpu.test()
        if testsEnabled then
            return coroutine.create(function()
                local yield = yielder(0.05)
                bus.useTestMemory(true)
                gb.setEnableTestLogs(true)
                -- this will leave the CPU in an invalid init state!
                for i=0,255 do
                    local asset = string.format("/scripts/gb/cputests/%02x.json",i)
                    -- for some reason the CB prefix tests in this file are just... wrong
                    -- for now, just don't run more than 1 cycle for these tests
                    if root.assetOrigin(asset) then
                        local tests = root.assetJson(asset)
                        for k,v in next, tests do
                            gb.clearLogs()
                            local test = string.format("%s (%02x)",v.name,i)
                            gb.logInfo(string.format("starting test %s",test))
                            r[1] = v.initial.a or r[1]
                            r[2] = v.initial.f or r[2]
                            r[3] = v.initial.b or r[3]
                            r[4] = v.initial.c or r[4]
                            r[5] = v.initial.d or r[5]
                            r[6] = v.initial.e or r[6]
                            r[7] = v.initial.h or r[7]
                            r[8] = v.initial.l or r[8]
                            pc = v.initial.pc-1 or pc
                            sp = v.initial.sp or sp
                            for _,v2 in next,v.initial.ram do
                                bus.write(v2[1],v2[2])
                            end
                            halted = false
                            autoHaltExit = false
                            stopped = false
                            noInterrupts = true
                            nextInterrupt = nil
                            gb.logInfo("running instructions")
                            local c = 0
                            while c < 1 do
                                c = c + cpu.update()
                            end
                            gb.logInfo("observing result")
                            if v.final.ram then
                                for _,v2 in next, v.final.ram do
                                    local val = bus.read(v2[1])
                                    if val ~= v2[2] then
                                        gb.outputLogs()
                                        sb.logWarn(string.format("Test %s failed! Memory at %04x was %02x, should be %02x",test,v2[1],val,v2[2]))
                                        break
                                    end
                                end
                            end
                            if v.final.registers then
                                local function registerError(r,val,exp)
                                    gb.outputLogs()
                                    sb.logWarn(string.format("Test %s failed! Register %s was %02x, should be %02x",test,r,val,exp))
                                end
                                if v.final.a then if r[1] ~= v.final.a then registerError("a",r[1],v.final.a) end end
                                if v.final.f then if r[2] ~= v.final.f then registerError("f",r[2],v.final.f) end end
                                if v.final.b then if r[3] ~= v.final.b then registerError("a",r[3],v.final.b) end end
                                if v.final.c then if r[4] ~= v.final.c then registerError("a",r[4],v.final.c) end end
                                if v.final.d then if r[5] ~= v.final.d then registerError("a",r[5],v.final.d) end end
                                if v.final.e then if r[6] ~= v.final.e then registerError("a",r[6],v.final.e) end end
                                if v.final.h then if r[7] ~= v.final.h then registerError("a",r[7],v.final.h) end end
                                if v.final.l then if r[8] ~= v.final.l then registerError("a",r[8],v.final.l) end end
                                if v.final.pc then if pc ~= v.final.pc then registerError("pc",pc,v.final.pc) end end
                                if v.final.sp then if sp ~= v.final.sp then registerError("sp",sp,v.final.sp) end end
                            end
                            yield()
                        end
                    end
                end
                bus.useTestMemory(false)
                gb.setEnableTestLogs(false)
            end)
        end
    end
    function cpu.stopped()
        return stopped
    end
    function cpu.halted()
        return halted
    end
    function cpu.exitStop()
        stopped = false
    end
    function cpu.reset()
        -- reset everything to initial state
        ier = 0x00
        waitingInterrupts = 0x00
        -- registers
        sp = 0xFFFE
        pc = 0x0100
        r = {
            0x01, -- a (1) (a value of 0x11 indicates CGB/GBA)
            0xb0, -- f (2)
            0x00, -- b (3)
            0x13, -- c (4)
            0x00, -- d (5)
            0xd8, -- e (6)
            0x01, -- h (7)
            0x4d -- l (8)
        }
        stopped = false
        noInterrupts = false
        halted = false
        autoHaltExit = false
        nextInterrupt = nil
        currentInstruction = nil
        cpu.setGBMode(gbMode)
    end
    return cpu
end
