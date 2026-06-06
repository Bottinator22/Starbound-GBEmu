require "/scripts/gb/utils.lua"

local function sign8(n)
    return (n & 0x7f)-(n & 0x80)
end

local renderer = {}

local w=1
local h=6
local parts = w*h
local iw = (160/w)
local ih = (144/h)

local subThreads = {}
local subThreadFramePromises = {}

-- GBC doesn't need to render every frame as long as game logic runs in background
-- note: if just sending the entirety of VRAM is more efficient than sending the data to render, and processing at the other end is more efficient, do so

-- I use M-cycles here
local drawables = {}
local it = 0
local frames = 0
local fps = 0
function init()
    for y=1,h do
        for x=1,w do
            local n = string.format("r%d%d",x,y)
            table.insert(subThreads, threads.create({
                name="gameboyRenderer_"..n,
                scripts={
                    main={"/scripts/gb/rendererFragmentThread.lua"}
                },
                tickRate=120,
                instructionLimit=100000000,
                gbRenderName=n,
                xIndex=x,
                yIndex=y
            }))
        end
    end
    -- 1,
    -- 2,
    -- 3,
    -- 4,
    -- 5,
    -- 6
    message.setHandler("setGBMode",function(_,_,t)
        for k,v in next, subThreads do
            threads.sendMessage(v,"setGBMode",t)
        end
    end)
    message.setHandler("writes",function(_,_,writes,isFrameskip)
        if isFrameskip then
            for k,v in next, subThreads do
                threads.sendMessage(v,"frameskipWrites",writes)
            end
        else
            local p = {}
            for k,v in next, subThreads do
                table.insert(p,threads.sendMessage(v,"doFrame",writes))
            end
            while not (p[1]:finished() and p[2]:finished() and p[3]:finished() and p[4]:finished() and p[5]:finished() and p[6]:finished()) do
            end
            if p[1]:succeeded() and p[2]:succeeded() and p[3]:succeeded() and p[4]:succeeded() and p[5]:succeeded() and p[6]:succeeded() then
                drawables[1] = p[1]:result()
                drawables[2] = p[2]:result()
                drawables[3] = p[3]:result()
                drawables[4] = p[4]:result()
                drawables[5] = p[5]:result()
                drawables[6] = p[6]:result()
                frames = frames + 1
            end
            if drawables[1] and drawables[2] and drawables[3] and drawables[4] and drawables[5] and drawables[6] then
                return drawables
            end
        end
    end)
    script.setUpdateDelta(1)
end
function update(dt)
    it = it + dt
    local nSubThreadFramePromises = {}
    --sb.setLogMap("gbppu_dist_waitingFrames",string.format("%d",#subThreadFramePromises))
    if it >= 1 then
        it = 0
        fps = frames
        frames = 0
    end
    sb.setLogMap("gbppu_dist_fps",string.format("%d",fps))
    subThreadFramePromises = nSubThreadFramePromises
end
