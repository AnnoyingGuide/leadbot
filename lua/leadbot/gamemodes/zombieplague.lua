LeadBot.RespawnAllowed = false
LeadBot.SetModel = false
LeadBot.Gamemode = "zombieplague"
LeadBot.TeamPlay = true
LeadBot.LerpAim = true

local DEBUG = false
local HidingSpots = {}

function LeadBot.AddBotOverride(bot)
    RoundManager:AddPlayerToPlay(bot)
end

local function addSpots()
    local areas = navmesh.GetAllNavAreas()
    local hidingspots = {}
    local spotsReset = {}

    for _, area in pairs(areas) do
        local spots = area:GetHidingSpots(1)
        local spots2 = area:GetHidingSpots(8)
        local spotsReset2 = {}

        for _, spot in pairs(spots) do
            if !util.QuickTrace(spot, Vector(0, 0, 72)).Hit and !util.QuickTrace(spot, Vector(0, 0, 72)).Hit and !util.TraceHull({start = spot, endpos = spot + Vector(0, 0, 72), mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 72)}).HitWorld then
                table.Add(hidingspots, spots)
                table.insert(spotsReset2, spot)
            end
        end

        table.insert(spotsReset, {area, spotsReset2})

        -- table.Add(hidingspots, spots2)

        -- the reason why we don't use spots2 is because these are barely hidden
        -- we should only use it when there are not enough normal hiding spots to diversify hiding places
    end

    MsgN("Found " .. #hidingspots .. " default hiding spots!")
    if #hidingspots < 1 then return end
    --[[MsgN("Teleporting to one...")
    ply:SetPos(table.Random(hidingspots))]]

    HidingSpots = spotsReset
end

function LeadBot.PlayerMove(bot, cmd, mv)
    if #HidingSpots < 1 then
        addSpots()
    end

    local controller = bot.ControllerBot

    if !IsValid(controller) then
        bot.ControllerBot = ents.Create("leadbot_navigator")
        bot.ControllerBot:Spawn()
        bot.ControllerBot:SetOwner(bot)
        controller = bot.ControllerBot
    end

    -- force a recompute
    if controller.PosGen and controller.P and controller.TPos ~= controller.PosGen then
        controller.TPos = controller.PosGen
        controller.P:Compute(controller, controller.PosGen)
    end

    if controller:GetPos() ~= bot:GetPos() then
        controller:SetPos(bot:GetPos())
    end

    mv:SetForwardSpeed(1200)
    -- main thing that's keeping the bots from being lag free is seeking targets
    -- losing about 4-25 fps with this
    -- for now, using player.GetAll() rather than ents.GetAll()
    -- having no npc support is bad, but I think most people will use this for dm
    if (bot.NextSpawnTime and bot.NextSpawnTime + 1 > CurTime()) or !IsValid(controller.Target) or controller.ForgetTarget < CurTime() or controller.Target:Health() < 1 then
        controller.Target = nil
    end

    if !IsValid(controller.Target) then
        for _, ply in ipairs(ents.GetAll()) do
            if ply ~= bot and ((ply:IsPlayer() and (ply:Team() ~= bot:Team())) or ply:IsNPC()) and ply:GetPos():DistToSqr(bot:GetPos()) < 2250000 then
                local targetpos = ply:EyePos() - Vector(0, 0, 10)
                local trace = util.TraceLine({
                    start = bot:GetShootPos(),
                    endpos = targetpos,
                    filter = function(ent) return ent == ply end
                })

                if trace.Entity == ply then
                    controller.Target = ply
                    controller.ForgetTarget = CurTime() + 2
                end
            end
        end
    end

    local dt = util.QuickTrace(bot:EyePos(), bot:GetForward() * 45, bot)

    if IsValid(dt.Entity) and dt.Entity:GetClass() == "prop_door_rotating" then
        dt.Entity:Fire("Open","",0)
    end

    if bot:Team() ~= TEAM_HUMANS and bot.hidingspot then
        bot.hidingspot = nil
    end

    if DEBUG then
        debugoverlay.Text(bot:EyePos(), bot:Nick(), 0.03, false)
        local min, max = bot:GetHull()
        debugoverlay.Box(bot:GetPos(), min, max, 0.03, Color(255, 255, 255, 0))

        if bot.hidingspot then
            debugoverlay.Text(bot.hidingspot, bot:Nick() .. "'s hiding spot!", 0.1, false)
        end
    end

    if !IsValid(controller.Target) and ((bot:Team() ~= TEAM_HUMANS and (!controller.PosGen or (controller.PosGen and bot:GetPos():DistToSqr(controller.PosGen) < 5000))) or bot:Team() == TEAM_HUMANS or controller.LastSegmented < CurTime()) then
        if bot:Team() == TEAM_HUMANS then
            -- hiding ai
            if !bot.hidingspot then
                local area = table.Random(HidingSpots)

                if #area[2] > 0 and controller.loco:IsAreaTraversable(area[1]) then
                    local spot = table.Random(area[2])
                    bot.hidingspot = spot
                end
            else
                local dist = bot:GetPos():DistToSqr(bot.hidingspot)
                if dist < 1200 then -- we're here
                    controller.PosGen = nil
                else -- we need to run...
                    controller.PosGen = bot.hidingspot
                end
            end

            controller.LastSegmented = CurTime() + 3
        else
            -- search all hiding spots we know of...
            local area = table.Random(HidingSpots)

            if #area[2] > 0 and controller.loco:IsAreaTraversable(area[1]) then
                local spot = table.Random(area[2])
                controller.PosGen =  spot
            end

            controller.LastSegmented = CurTime() + 10
        end
    elseif IsValid(controller.Target) then
        -- move to our target
        local distance = controller.Target:GetPos():DistToSqr(bot:GetPos())
        controller.PosGen = controller.Target:GetPos()

        -- back up if the target is really close
        -- TODO: find a random spot rather than trying to back up into what could just be a wall
        -- something like controller.PosGen = controller:FindSpot("random", {pos = bot:GetPos() - bot:GetForward() * 350, radius = 1000})?
        if bot:Team() ~= TEAM_ZOMBIES and distance <= 160000 then
            mv:SetForwardSpeed(-1200)
        end
    end

    -- movement also has a similar issue, but it's more severe...
    if !controller.P then
        return
    end

    local segments = controller.P:GetAllSegments()

    if !segments then return end

    local cur_segment = controller.cur_segment
    local curgoal = (controller.PosGen and segments[cur_segment])

    -- eyesight
    local lerp = FrameTime() * math.random(8, 10)
    local lerpc = FrameTime() * 8
    local mva

    if !LeadBot.LerpAim then
        lerp = 1
        lerpc = 1
    end

    -- got nowhere to go, why keep moving?
    if curgoal then
        -- think every step of the way!
        -- TODO: corner turning like nextbot npcs
        if segments[cur_segment + 1] and Vector(bot:GetPos().x, bot:GetPos().y, 0):DistToSqr(Vector(curgoal.pos.x, curgoal.pos.y)) < 100 then
            controller.cur_segment = controller.cur_segment + 1
            curgoal = segments[controller.cur_segment]
        end

        -- jump
        if controller.NextJump ~= 0 and curgoal.pos.z > (bot:GetPos().z + 16) and controller.NextJump < CurTime() then
            controller.NextJump = 0
        end

        if DEBUG then
            controller.P:Draw()
        end

        mva = ((curgoal.pos + bot:GetViewOffset()) - bot:GetShootPos()):Angle()

        mv:SetMoveAngles(mva)
    else
        mv:SetForwardSpeed(0)
    end

    if IsValid(controller.Target) then
        bot:SetEyeAngles(LerpAngle(lerp, bot:EyeAngles(), (controller.Target:EyePos() - bot:GetShootPos()):Angle()))
        return
    elseif curgoal then
        local ang = LerpAngle(lerpc, bot:EyeAngles(), mva)
        bot:SetEyeAngles(Angle(ang.p, ang.y, 0))
    elseif bot.hidingspot then
        bot.NextSearch = bot.NextSearch or CurTime()
        bot.SearchAngle = bot.SearchAngle or Angle(0, 0, 0)

        if bot.NextSearch < CurTime() then
            bot.NextSearch = CurTime() + math.random(2, 3)
            bot.SearchAngle = Angle(math.random(-40, 40), math.random(-180, 180), 0)
        end

        bot:SetEyeAngles(LerpAngle(lerp, bot:EyeAngles(), bot.SearchAngle))
    end
end

function LeadBot.PostPlayerDeath(bot)
    bot.hidingspot = nil
end

if !DEBUG then return end

concommand.Add("hidingSpot", function(ply, _, args)
    addSpots()
end)