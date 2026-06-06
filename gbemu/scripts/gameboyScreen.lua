
local screens = {"screen00","screen01","screen02","screen03","screen04","screen05"}
function init()
    local defaultFrame = root.assetJson("/scripts/gb/sixthscreen2white.json").drawable
    for k,v in next, screens do
        animator.resetTransformationGroup(v)
        animator.scaleTransformationGroup(v,{1,-1},animator.partPoint(v,"center"))
        animator.setGlobalTag(v,defaultFrame)
    end
    ownerId = config.getParameter("ownerId")
    script.setUpdateDelta(1)
    monster.setInteractive(false)
    
    mcontroller.setAutoClearControls(false)
    
    mcontroller.controlFace(1)
    monster.setDamageBar("None")
    monster.setDamageOnTouch(false)
    
    monster.setName("Gameboy Screen")
    
    animator.setFlipped(false)
end
function update()
    mcontroller.setVelocity({0,0})
    
    local wWidth = 20
    local wHeight = 18
    local subdivisionsX = 1
    local subdivisionsY = 6
    local subdivWidth = wWidth/subdivisionsX
    local subdivHeight = wHeight/subdivisionsY
    local startX = mcontroller.xPosition()-wWidth/2
    local startY = mcontroller.yPosition()-wHeight/2
    for x=1,subdivisionsX do
        for y=1,subdivisionsY do
            local mix = startX + subdivWidth *(x-1)
            local max = startX + subdivWidth *x
            local miy = startY + subdivHeight*(y-1)
            local may = startY + subdivHeight*y
            world.debugLine({mix,miy},{mix,may},"red")
            world.debugLine({mix,may},{max,may},"red")
            world.debugLine({max,may},{max,miy},"red")
            world.debugLine({max,miy},{mix,miy},"red")
        end
    end
end
function setFrame(frame)
    animator.setGlobalTag("screen00",frame[6])
    animator.setGlobalTag("screen01",frame[5])
    animator.setGlobalTag("screen02",frame[4])
    animator.setGlobalTag("screen03",frame[3])
    animator.setGlobalTag("screen04",frame[2])
    animator.setGlobalTag("screen05",frame[1])
end
function shouldDie()
    return not world.entityExists(ownerId)
end

function interact(args)
end

function die()
end
