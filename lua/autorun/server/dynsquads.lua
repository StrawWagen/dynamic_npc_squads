local blacklistedClasses = { -- one of these crashed my session during testing so they wont be involved 
    ["npc_manhack"] = true,
    ["npc_sniper"] = true,
    ["npc_rollermine"] = true
}

local COND_NEW_ENEMY = 26
local COND_SEE_ENEMY = 10
local COND_SEE_FEAR = 8
local COND_ENEMY_DEAD = 30
local COND_LIGHT_DAMAGE = 17
local COND_HEAVY_DAMAGE = 18
local COND_HEAR_DANGER = 50

local showprints = CreateConVar( "npc_dynsquads_showprints", 0, FCVAR_ARCHIVE, "Show dynsquad system prints in console, Debug.", 0, 1 )
local dosquads = CreateConVar( "npc_dynsquads_dosquads", 1, FCVAR_ARCHIVE, "Enable/disable dynsquad system.", 0, 1 )
CreateConVar( "npc_dynsquads_dowandering", 1, FCVAR_ARCHIVE, "Should dynsquads wander around the map?" )
CreateConVar( "npc_dynsquads_doassaults", 1, FCVAR_ARCHIVE, "Should dynsquads call for backup?" )

local dowanderingBool = nil
cvars.AddChangeCallback( "npc_dynsquads_dowandering", function( _, _, new )
    dowanderingBool = tobool( new )

end, "dynsquads_detectchange" )

local doassaultingBool = nil
cvars.AddChangeCallback( "npc_dynsquads_doassaults", function( _, _, new )
    doassaultingBool = tobool( new )

end, "dynsquads_detectchange" )

local interruptConditions = {
    COND_NEW_ENEMY,
    COND_SEE_ENEMY,
    COND_SEE_FEAR,
    COND_ENEMY_DEAD,
    COND_LIGHT_DAMAGE,
    COND_HEAVY_DAMAGE,
    COND_HEAR_DANGER
}

local soundCategories = {
    ["acquireassault"] = {
        ["backup"] = IdleSound,
        ["models/police.mdl"] = "sent_METROPOLICE_HEARD_SOMETHING",
        ["models/hunter.mdl"] = "NPC_Hunter.Scan",
        ["models/combine_so"] = "sent_COMBINE_FLANK"
    },
    ["movingtoassault"] = {
        ["backup"] = FoundEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_ANSWER_CR",
        ["models/hunter.mdl"] = "NPC_Hunter.Alert",
        ["models/combine_so"] = "sent_COMBINE_ANSWER"
    },
    ["reachedassault"] = {
        ["backup"] = LostEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_CLEAR",
        ["models/hunter.mdl"] = "NPC_Hunter.Idle",
        ["models/combine_so"] = "sent_COMBINE_CLEAR"
    },
    ["reachedhotassault"] = {
        ["backup"] = FoundEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_GO_ALERT",
        ["models/hunter.mdl"] = "NPC_Hunter.FoundEnemy",
        ["models/combine_so"] = "sent_COMBINE_ALERT"
    },
    ["joinednewleader"] = {
        ["backup"] = IdleSound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_ANSWER",
        ["models/hunter.mdl"] = "npc/ministrider/hunter_idle2.wav",
        ["models/combine_so"] = "sent_COMBINE_ANSWER"
    },
    ["inventedsquadcalm"] = {
        ["backup"] = IdleSound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE",
        ["models/hunter.mdl"] = "npc/ministrider/hunter_idle3.wav",
        ["models/combine_so"] = "sent_COMBINE_CLEAR"
    },
    ["beganwandering"] = {
        ["backup"] = LostEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_CLEAR_CR",
        ["models/hunter.mdl"] = "npc/ministrider/hunter_idle1.wav",
        ["models/combine_so"] = "sent_COMBINE_LOST_LONG"
    }
}

local dynSquadCounts = dynSquadCounts or {}
local dynSquadLeaders = dynSquadLeaders or {}
local allNpcs = allNpcs or {}
local cachedNpcs = cachedNpcs or {}
local transferCounts = transferCounts or {}
local teamFlankPoints = teamFlankPoints or {}
local teamReinforcePoints = teamReinforcePoints or {}

local dynSquadTeamIndex = 0
local dynSquadMinAssembleTime = 3
local maxSquadSize = 6
local minDistBetweenAssaults = 500 -- dont spam new assaults unless they're at least this far a part

local dynSquadCounts2 = {}
local dynSquadLeaders2 = {}
local allNpcs2 = {}

local buildIndex = 0
local newBuildTime = 0
local newBuildReady = true
local doingBuild = false

local aiDisabled = GetConVar( "ai_disabled" )

local function enabledAi()
    return aiDisabled:GetInt() == 0
end

local function dirToPos( startPos, endPos )
    if not startPos then return end
    if not endPos then return end

    return ( endPos - startPos ):GetNormalized()

end

local function sqrDistGreaterThan( Dist1, Dist2 )
    Dist2 = Dist2 ^ 2
    return Dist1 > Dist2
end

local function sqrDistLessThan( Dist1, Dist2 )
    Dist2 = Dist2 ^ 2
    return Dist1 < Dist2
end


local function npcHasConditions( npc, conditions )
    if not IsValid( npc ) then return false end
    if not istable( conditions ) then return false end
    local has = false
    for _, currentCondition in ipairs( conditions ) do
        if npc:HasCondition( currentCondition ) then
            has = true
            break
        end
    end
    return has
end

local function npcIsAlert( npc )
    if not IsValid( npc ) then return end
    local myState = npc:GetNPCState()
    local alert = npcHasConditions( npc, interruptConditions ) or IsValid( npc:GetEnemy() ) or myState == NPC_STATE_ALERT or myState == NPC_STATE_COMBAT
    return alert
end

local function npcCancelGo( npc )
    if not npc.wasDoingConfirmedDynsquadsGo then return end -- long name so no conflicts
    local sched = SCHED_FORCED_GO_RUN
    local isSched = npc:IsCurrentSchedule( sched )
    if isSched then
        npc.wasDoingConfirmedDynsquadsGo = nil
        npc:SetSchedule( SCHED_ALERT_FACE )
    end
end

local function npcSquad( npc )
    if not IsValid( npc ) then return nil end
    local vals = npc:GetKeyValues()
    local squad = vals["squadname"]
    if not squad then return nil end
    if not isstring( squad ) then return nil end
    return squad
end

local function npcPlaySound( npc, soundKey )
    if not IsValid( npc ) then return end
    local model = npc:GetModel()
    model = string.lower( model )
    local soundCategory = soundCategories[soundKey]

    local toPlay = soundCategory["backup"]
    for modelKey, playedAtModel in pairs( soundCategory ) do
        if string.find( model, modelKey ) then
            toPlay = playedAtModel
            break

        end
    end
    -- print( npc, model )
    if isfunction( toPlay ) then
        npc:toPlay()

    elseif isstring( toPlay ) then
        if string.StartWith( toPlay, "sent_" ) then
            toPlay = string.Replace( toPlay, "sent_", "" )
            npc:PlaySentence( toPlay, 0, 1 )

        else
            npc:EmitSound( toPlay, 80, 100 )

        end
    end
    debugoverlay.Text( npc:GetPos(), tostring( soundKey ), 2, true )
end


local function npcSetDynSquad( npc, squad )
    if not IsValid( npc ) then return end

    local oldSquad = npc:GetSquad() or ""
    if oldSquad ~= "" then
        local oldCount = dynSquadCounts[ oldSquad ] or 0
        dynSquadCounts[ oldSquad ] = math.Clamp( oldCount + -1, 0, math.huge )
    end

    npc.dynamicSquad = squad
    npc:SetSquad( squad )
    local count = dynSquadCounts[ squad ] or 0
    dynSquadCounts[ squad ] = count + 1

    local dupeData = { ["squadname"] = squad, ["isleader"] = false }
    duplicator.StoreEntityModifier( npc, "dynsquads_squadinfo", dupeData )

    local leader = ai.GetSquadLeader( squad )
    if not IsValid( leader ) then return end
    dupeData = { ["squadname"] = squad, ["isleader"] = true }
    duplicator.StoreEntityModifier( leader, "dynsquads_squadinfo", dupeData )
end

local function sortEntsByDistanceTo( toSort, checkPos )
    local toReturn = toSort
    table.sort( toReturn, function( a, b )
        if not IsValid( a ) then return false end
        if not IsValid( b ) then return true end
        local ADist = a:GetPos():DistToSqr( checkPos )
        local BDist = b:GetPos():DistToSqr( checkPos )
        return ADist < BDist
    end )
    return toReturn
end

-- are npcs friendly?
local function npcsAreChummy( chummer, chummee )
    if not IsValid( chummer ) then return end
    if not IsValid( chummee ) then return end
    local chummersType = type( chummer )
    local chummeesType = type( chummee )
    local dispToChummee = chummer:Disposition( chummee )
    local sameTypeAndNeutral = chummeesType == chummersType and dispToChummee == D_NU
    local likesOrIndifferent = dispToChummee == D_LI or sameTypeAndNeutral
    return likesOrIndifferent
end

-- get oot me way mate!
local function tellToMove( teller, telee )
    if not IsValid( teller ) or not IsValid( telee ) then return end
    if not teller:IsNPC() or not telee:IsNPC() then return end
    if not npcsAreChummy( teller, telee ) then return end
    telee:SetSaveValue( "vLastKnownLocation", teller:GetPos() )
    telee:SetSchedule( SCHED_TAKE_COVER_FROM_ORIGIN )
end

-- heavy function that finds a leader
local function dynSquadFindAcceptingLeader( me )
    local sortedLeaders = sortEntsByDistanceTo( dynSquadLeaders, me:GetPos() )
    local success = false

    for _, currentLeader in ipairs( sortedLeaders ) do
        if IsValid( currentLeader ) then

            local radius = 1500
            local failures = me.findLeaderFailures or 0

            if failures >= 4 then
                radius = 30000
            end

            local isTooFar = sqrDistGreaterThan( me:GetPos():DistToSqr( currentLeader:GetPos() ), radius )
            if isTooFar then me.findLeaderFailures = failures + 1 break end

            local chummyToLeader = npcsAreChummy( me, currentLeader )
            local currSquad = npcSquad( currentLeader )
            local currCount = dynSquadCounts[ currSquad ] or 0
            local isMe = currentLeader == me

            if currCount ~= nil and currSquad and not isMe and chummyToLeader then
                local atCapacity = currCount >= maxSquadSize

                if not atCapacity then
                    if math.random( 0, 100 ) > 70 then
                        npcPlaySound( me, "joinednewleader" )
                    end
                    npcSetDynSquad( me, currSquad )
                    -- debugoverlay.Line( me:GetPos(), currentLeader:GetPos(), 4, Color( 255, 255, 255 ) )
                    success = true
                    break
                end
            end
        end
    end
    return success
end

-- make a new squad 
local function dynSquadNpcBranchOff( me )
    npcSetDynSquad( me, "dyn_" .. me:GetCreationID() ) -- invent new squads
    table.insert( dynSquadLeaders, me )
    me.LeaderPromotionTime = CurTime()
    if showprints:GetBool() then
        print( "newsquad " .. "dyn_" .. me:GetCreationID() )
    end
end

-- find a squad leader that takes us on, else just make a new squad
local function dynSquadAutoTransfer( me, currentSquad )
    local success = nil
    local myCount = dynSquadCounts[currentSquad] or 0
    local inOnboardSquad = currentSquad == "" and me.dynSquadInBacklog
    if inOnboardSquad then
        success = dynSquadFindAcceptingLeader( me )
        if success then return end
        if me.dupedAsFollower then
            me.blockedJoins = ( me.blockedJoins or 0 ) - 1
            if me.blockedJoins > -0 then return end
            me.blockedJoins = nil
            me.dupedAsFollower = nil
        else
            dynSquadNpcBranchOff( me )
            me.dynSquadInBacklog = nil
            if npcIsAlert( me ) then return end
            npcPlaySound( me, "inventedsquadcalm" )
        end
    else
        if myCount <= 1 or myCount > maxSquadSize then
            success = dynSquadFindAcceptingLeader( me )
        end

        if success then return end
        if myCount > 1 and myCount < maxSquadSize then return end
        dynSquadNpcBranchOff( me )
        if npcIsAlert( me ) then return end
        npcPlaySound( me, "inventedsquadcalm" )
    end
end

local function dynSquadValid( me, squad )
    if not me.dynamicSquad then return true end
    if me.dynamicSquad == squad then return true end
    return false
end

--[[
local function npcWanderTowardsPos( npc, pos )
    if me:GetPathDistanceToGoal() > 25 then return end
    local dirToPos = ( pos - npc:GetPos() ):GetNormalized()
    me:SetSchedule( SCHED_IDLE_WALK )
    me:NavSetRandomGoal( 412, dirToPos )

    -- debugoverlay.Line( me:GetPos(), me:GetPos() + ( refent:GetAimVector() * 100 ), 2, Color( 255, 255, 255 ) )

end
]]--

local function npcWanderForward( me, refent )
    if me:GetPathDistanceToGoal() > 25 then return end
    me:SetSchedule( SCHED_IDLE_WALK )
    me:NavSetRandomGoal( 412, refent:GetAimVector() )

    -- debugoverlay.Line( me:GetPos(), me:GetPos() + ( refent:GetAimVector() * 100 ), 2, Color( 255, 255, 255 ) )

end

local function npcPathRunToPos( me, pos )
    local fail = SCHED_FAIL
    local sched = SCHED_FORCED_GO_RUN
    local lastGoPos = me.dynLastGoRunPosition or Vector()
    local goodMoving = me:IsCurrentSchedule( sched ) and sqrDistLessThan( lastGoPos:DistToSqr( pos ), 250 )
    local isCondition = npcHasConditions( me, interruptConditions )

    if me:IsCurrentSchedule( fail ) then return false end

    if not goodMoving and not isCondition then
        me:SetSaveValue( "m_vecLastPosition", pos )
        me:SetSchedule( sched )
        me.dynLastGoRunPosition = pos
        me.wasDoingConfirmedDynsquadsGo = true
    else
        if not isCondition then return true end
        me:SetSchedule( SCHED_ALERT_FACE )
    end

    return true
end

local function npcStandWatch( me, myLeader )
    local sched = SCHED_ALERT_STAND
    if me:IsCurrentSchedule( sched ) then return end
    me:SetSchedule( sched )
    local angle = dirToPos( myLeader:GetPos(), me:GetPos() ):Angle()
    me:SetIdealYawAndUpdate( angle.yaw, 1 )

end


local function newDynTeam( npc )
    dynSquadTeamIndex = dynSquadTeamIndex + 1
    npc.dynSquadTeam = dynSquadTeamIndex
    teamFlankPoints[npc.dynSquadTeam] = {}
    teamReinforcePoints[npc.dynSquadTeam] = {}
end

local function teamCheck2( npc1, npc2 )
    if not IsValid( npc1 ) then return false end
    if not IsValid( npc2 ) then return false end
    if not npc2.dynSquadTeam then return false end
    if not npcsAreChummy( npc1, npc2 ) then return false end
    npc1.dynSquadTeam = npc2.dynSquadTeam
    return true

end

local function teamCheck( npc )
    if npc.dynSquadTeam then return end
    local done = false
    for _, currentNpc in ipairs( allNpcs ) do
        done = teamCheck2( npc, currentNpc )
        if done then break end
    end
    if done then return end
    newDynTeam( npc )

end


-- "flank" point
local function saveFlankPoint( npc, pos )
    local dynTeam = npc.dynSquadTeam
    local identifier = math.Round( CurTime(), 2 )
    local currentTable = teamFlankPoints[dynTeam]
    if not istable( currentTable ) then return end
    currentTable[identifier] = pos
    teamFlankPoints[dynTeam] = currentTable
    --PrintTable( currentTable ) 
end

local function saveReinforcePoint( npc, pos )
    local dynTeam = npc.dynSquadTeam
    local identifier = math.Round( CurTime(), 2 )
    local currentTable = teamReinforcePoints[dynTeam]
    if not istable( currentTable ) then return end
    currentTable[identifier] = pos
    teamReinforcePoints[dynTeam] = currentTable
end

local function npcFillPointCache( npc, pointType )
    local currentTable = nil
    local dynTeam = npc.dynSquadTeam

    if pointType == "flank" then
        currentTable = teamFlankPoints[dynTeam]
    elseif pointType == "reinforce" then
        currentTable = teamReinforcePoints[dynTeam]
    end

    if not istable( currentTable ) then return false end
    local highestKey = table.maxn( currentTable )
    local point = currentTable[highestKey]
    if not isvector( point ) then return false end
    currentTable[highestKey] = nil

    if pointType == "flank" then
        teamFlankPoints[dynTeam] = currentTable
    elseif pointType == "reinforce" then
        teamReinforcePoints[dynTeam] = currentTable
    end

    local old = npc.oldCachedPoint or Vector()
    local myPos2 = Vector()  local point2 = Vector()
    point2:SetUnpacked( point.x, point.y, 0 )
    myPos2:SetUnpacked( old.x, old.y, 0 )
    local distBetweenPoints = point2:DistToSqr( myPos2 )
    if sqrDistLessThan( distBetweenPoints, 800 ) then return false end

    npc.cachedPoint = point
    npc.oldCachedPoint = point

    return true
end

local function saveEnemyContact( me, enemy )
    local enemyPos = enemy:GetPos()
    saveReinforcePoint( me, me:GetPos() )
    saveFlankPoint( me, enemyPos )
    me.lastSavedAssaultPos = enemyPos
    me.lastAssaultPosSaveTime = CurTime()
end

local function npcCanSavePoint( me, checkPos )
    local lastTime = me.lastAssaultPosSaveTime or 0
    if ( lastTime + 5 ) > CurTime() then return false end
    local pos1 = me.lastSavedAssaultPos or Vector()
    local goodDist = sqrDistGreaterThan( pos1:DistToSqr( checkPos ), minDistBetweenAssaults )
    if not goodDist then return false end
    return true
end

local function dynLeaderContact( me, enemy )
    if not IsValid( enemy ) then return end
    local enemyPos = enemy:GetPos()
    local canSavePoint = npcCanSavePoint( me, enemyPos )
    if not canSavePoint then return end
    saveEnemyContact( me, enemy )
end

local function npcAlertThink( npc )
    npcCancelGo( npc )
    npc.dynLastAlertTime = CurTime()

end


-- main function that loops on every npc with a valid squad, everything above is for this
local function npcDoSquadThink( me )
    if not IsValid( me ) then return end
    if not dosquads:GetBool() then return true end
    local squad = npcSquad( me )
    if not squad then return end
    if not dynSquadValid( me, squad ) then return end

    local ableToAct = enabledAi() and not me:IsCurrentSchedule( -1 )
    local count = dynSquadCounts[squad] or 0
    local myLeader = ai.GetSquadLeader( squad )
    local amLeader = me:IsSquadLeader()
    local blocker = me:GetBlockingEntity()
    local soloSquad = count <= 1
    local aboveCapacity = count > maxSquadSize

    local myState = me:GetNPCState()
    local myPos = me:GetPos()
    local myEnemy = me:GetEnemy()
    local alert = npcIsAlert( me )
    local idle = ( me.dynLastAlertTime or 0 ) + 10 < CurTime() and ( myState == NPC_STATE_IDLE or myState == NPC_STATE_ALERT ) -- ""idle""

    local old = ( me.LeaderPromotionTime or 0 ) + dynSquadMinAssembleTime < CurTime()
    local smallAndOld = count <= 1 and old
    local caps = me:CapabilitiesGet()
    local canUseWeapon = bit.band( caps, CAP_USE_WEAPONS ) > 0
    local isArmed = #me:GetWeapons() > 0
    local canSquad = bit.band( caps, CAP_SQUAD ) > 0

    if not canSquad then return
    elseif canUseWeapon and not isArmed then
        if alert then
            npcAlertThink( me )
        end
        if not alert and ableToAct and dowanderingBool and me:IsCurrentSchedule( SCHED_IDLE_STAND ) then
            npcWanderForward( me, me )
        end
    elseif soloSquad then
        dynSquadFindAcceptingLeader( me )
    elseif amLeader then
        if smallAndOld then
            local blocks = me.blockedDissolves or 0
            if blocks > 0 then
                me.blockedDissolves = blocks - 1
            else
                me.blockedDissolves = nil
                dynSquadFindAcceptingLeader( me )
            end
        end
        if ableToAct then
            if alert then
                npcAlertThink( me )
                if me.wasTraversingToAssault then
                    me.wasTraversingToAssault = nil
                    me.isWandering = nil
                    npcPlaySound( me, "reachedhotassault" )
                end
                dynLeaderContact( me, myEnemy or nil )
            elseif idle then
                local point
                if doassaultingBool then
                    point = me.cachedPoint
                end
                if point then
                    local point2 = Vector()
                    local myPos2 = Vector()
                    point2:SetUnpacked( point.x, point.y, 0 )
                    myPos2:SetUnpacked( myPos.x, myPos.y, 0 )
                    local distToPoint = point2:DistToSqr( myPos2 )
                    local reallyClose = sqrDistLessThan( distToPoint, 300 )
                    local closeAndSee = sqrDistLessThan( distToPoint, 1500 ) and me:VisibleVec( point + Vector( 0,0,40 ) )
                    local clearThePos = reallyClose or closeAndSee or me:IsCurrentSchedule( SCHED_FAIL )
                    if clearThePos then
                        me.cachedPoint = nil
                        me.wasTraversingToAssault = nil
                        npcPlaySound( me, "reachedassault" )
                    else
                        me.wasTraversingToAssault = true
                        npcPathRunToPos( me, point )
                    end
                elseif not point and me.wasTraversingToAssault then
                    npcCancelGo( me )
                elseif not point and ( me.nextCacheAttempt or 0 ) < CurTime() then
                    local choices = { [0] = "flank", [1] = "reinforce" }
                    local choice = choices[ math.random( 0, 1 ) ]
                    local success = npcFillPointCache( me, choice )
                    if success and me.cachedPoint and not me.wasTraversingToAssault then
                        npcPlaySound( me, "acquireassault" )
                    else
                        me.nextCacheAttempt = CurTime() + math.random( 1, 3 )
                    end
                end
                if dowanderingBool and not me.cachedPoint and ( me.dynLastAlertTime or 0 ) < CurTime() then
                    if me.dynLastAlertTime and ( me.playedBeginWanderSound or 0 ) ~= me.dynLastAlertTime then
                        npcPlaySound( me, "beganwandering" )
                        me.playedBeginWanderSound = me.dynLastAlertTime
                    end
                    me.isWandering = true
                    npcWanderForward( me, me )
                end
            else
                me.isWandering = nil
            end
        end

    elseif IsValid( myLeader ) and not aboveCapacity then
        local leadersPoint
        if doassaultingBool then
            leadersPoint = myLeader.cachedPoint
        end
        if ableToAct then
            local leaderPos = myLeader:GetPos()
            local sqrDistToLeader = myPos:DistToSqr( leaderPos )
            if alert then
                npcAlertThink( me )
            elseif leadersPoint then
                local nextNotify = me.nextPointNotify or 0
                if leadersPoint ~= me.notifedPoint and nextNotify < CurTime() then
                    me.nextPointNotify = CurTime() + 12
                    me.notifedPoint = leadersPoint
                    npcPlaySound( me, "movingtoassault" )
                end
                local reachedPoint = ( me.reachedPoint or Vector() )
                if reachedPoint ~= leadersPoint then
                    if sqrDistLessThan( myPos:DistToSqr( leadersPoint ), 400 ) then
                        me.reachedPoint = leadersPoint
                    end
                    local leaderDirToMe = dirToPos( leaderPos, myPos )
                    local pos1 = leadersPoint + ( leaderDirToMe * math.random( 50, 150 ) )
                    npcPathRunToPos( me, pos1 )
                elseif dowanderingBool then
                    npcWanderForward( me, me )
                end
            elseif sqrDistGreaterThan( sqrDistToLeader, 500 ) and not alert and ( me.nextReturnBackToLeader or 0 ) < CurTime() and idle then
                local leaderDirToMe = dirToPos( leaderPos, myPos )
                local pos1 = leaderPos + ( leaderDirToMe * 100 )
                local pos = myLeader:GetCurWaypointPos()
                if pos == Vector( 0 ) then
                    pos = pos1
                end
                npcPathRunToPos( me, pos )
            elseif not alert and myLeader.isWandering and idle then
                if ( me.standWatchLine or math.huge ) < CurTime() then
                    me:LostEnemySound()
                    me.standWatchLine = math.huge
                end
                if sqrDistGreaterThan( sqrDistToLeader, 600 ) then
                    npcStandWatch( me, myLeader )
                elseif dowanderingBool then
                    local time = math.random( 3, 18 )
                    me.nextReturnBackToLeader = CurTime() + time
                    me.standWatchLine = CurTime() + math.Clamp( time - 5, 2, math.huge )
                    npcWanderForward( me, myLeader )
                end
            elseif not alert and not myLeader.isWandering and idle then -- edge case
                if ( me.standWatchLine or math.huge ) < CurTime() then
                    me:LostEnemySound()
                    me.standWatchLine = math.huge
                end
                if sqrDistGreaterThan( sqrDistToLeader, 600 ) then
                    npcStandWatch( me, myLeader )
                elseif dowanderingBool then
                    local time = math.random( 20, 40 )
                    if math.random( 0, 100 ) > 90 then
                        time = time * math.Rand( 3, 6 )

                    end
                    me.nextReturnBackToLeader = CurTime() + time
                    me.standWatchLine = CurTime() + math.Clamp( time - 10, 2, math.huge )
                    npcWanderForward( me, myLeader )
                end
            end
        end
    else
        if me.dupedAsLeader then
            dynSquadNpcBranchOff( me )
            me.dupedAsLeader = nil
        else
            dynSquadAutoTransfer( me, squad )
        end
    end
    if IsValid( blocker ) then
        tellToMove( me, blocker )
    end
    return true
end


-- store a npc in the correct tables
local function dynSquadThinkProcessNpc( npc )
    if not IsValid( npc ) then return end
    local squad = npcSquad( npc )
    if not squad then return end
    table.insert( allNpcs2, npc )

    if npc.dynHasBeenProcessed then
        teamCheck( npc )
    else
        npc.dynHasBeenProcessed = true
    end

    local currCount = dynSquadCounts2[squad] or 0
    dynSquadCounts2[squad] = currCount + 1

    local leader = npc:IsSquadLeader()
    local small = not IsValid( npc:GetNearestSquadMember() )
    local leaderOrSmall = leader or small

    if not leaderOrSmall then return end
    table.insert( dynSquadLeaders2, npc )
end

-- on tick incrimental function that slowly chips away at big tasks
local function dynSquadThink()
    if not dosquads:GetBool() then return end

    if newBuildReady and newBuildTime < CurTime() then
        newBuildReady = false
        newBuildTime = CurTime() + dynSquadMinAssembleTime
        doingBuild = true

        dynSquadCounts2 = {}
        dynSquadLeaders2 = {}
        allNpcs2 = {}
        cachedNpcs = allNpcs
        buildIndex = 0

    elseif doingBuild then
        local max = #cachedNpcs
        if buildIndex <= max then
            dynSquadThinkProcessNpc( cachedNpcs[ buildIndex ] )
            buildIndex = buildIndex + 1
        elseif buildIndex > max then
            doingBuild = false
            newBuildReady = true

            dynSquadLeaders = dynSquadLeaders2
            dynSquadCounts = dynSquadCounts2
            allNpcs = allNpcs2

            transferCounts = {}

            if showprints:GetBool() then
                PrintTable( dynSquadCounts )
            end
        end
    end
end

hook.Add( "Tick", "STRAW_brainsbase_dynsquadthink", dynSquadThink )

local function dynSquadInitializeNpc( me )
    if not IsValid( me ) then return end
    table.insert( allNpcs, me )
    me:SetSquad( "" )
    me.dynSquadInBacklog = true
end

local function timerSetup( me )
    if not IsValid( me ) then return end
    local identifier = me:GetCreationID() .. "STRAW_brainsbase_npcdynsquadthink"
    timer.Create( identifier, 1.5, math.huge, function()
        if not IsValid( me ) then timer.Remove( identifier ) return end
        local good = npcDoSquadThink( me )
        if not good then timer.Remove( identifier ) return end
    end )
end

-- introduces npcs to the system
local function dynSquadAcquire( entity )
    if not SERVER then return end
    if not IsValid( entity ) then return end
    timer.Simple( 0.1, function()
        if not IsValid( entity ) then return end
        local squad = npcSquad( entity )
        if not isstring( squad ) then return end
        if blacklistedClasses[entity:GetClass()] then return end

        local delay = entity.dynSquadDelay or 0
        local rand = math.random( 0, 1500 ) / 1000

        timer.Simple( rand + delay, function()
            dynSquadInitializeNpc( entity )
            timerSetup( entity )
        end )
    end )
end

hook.Add( "OnEntityCreated", "STRAW_brainsbase_dynsquadacquire", dynSquadAcquire )

-- sort of dupe support
local function dynSquadPasteSquad( _, Entity, Data )
    timer.Simple( 0.08, function()
        if not Entity then return end
        if not istable( Data ) then return end
        if Data["isleader"] then
            Entity.dupedAsLeader = true
            Entity.blockedDissolves = 10
        else
            Entity.dupedAsFollower = true
            Entity.blockedJoins = 10
        end
    end )
end
duplicator.RegisterEntityModifier( "dynsquads_squadinfo", dynSquadPasteSquad )