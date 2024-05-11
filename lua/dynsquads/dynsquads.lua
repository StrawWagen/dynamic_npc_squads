local IsValid = IsValid
local CurTime = CurTime
local isstring = isstring
local math = math

-- dont use the global vector_origin, some addon is bound to have messed it up 
local vec_zero = Vector( 0, 0, 0 )

local developer = CreateConVar( "npc_dynsquads_developer", 0, FCVAR_ARCHIVE, "Enable/disable 'developer 1' info?" )
local doenable = CreateConVar( "npc_dynsquads_enabled", 1, FCVAR_ARCHIVE, "Enable/disable the entire 'dynamic npc squads' addon,", 0, 1 )
local dowandering = CreateConVar( "npc_dynsquads_dowandering", 1, FCVAR_ARCHIVE, "Should dynsquads wander around the map?" )
local doassaulting = CreateConVar( "npc_dynsquads_doassaults", 1, FCVAR_ARCHIVE, "Should dynsquads call for backup?" )

local enabledBool = doenable:GetBool()
cvars.AddChangeCallback( "npc_dynsquads_enabled", function( _, _, new )
    enabledBool = tobool( new )

end, "dynsquads_detectchange" )

-- use local bools instead of command:GetBool
local developerBool = developer:GetBool()
cvars.AddChangeCallback( "npc_dynsquads_developer", function( _, _, new )
    developerBool = tobool( new )

end, "dynsquads_detectchange" )

local dowanderingBool = dowandering:GetBool()
cvars.AddChangeCallback( "npc_dynsquads_dowandering", function( _, _, new )
    dowanderingBool = tobool( new )

end, "dynsquads_detectchange" )

local doassaultingBool = doassaulting:GetBool()
cvars.AddChangeCallback( "npc_dynsquads_doassaults", function( _, _, new )
    doassaultingBool = tobool( new )

end, "dynsquads_detectchange" )

local COND_NEW_ENEMY = 26
local COND_SEE_ENEMY = 10
local COND_SEE_FEAR = 8
local COND_ENEMY_DEAD = 30
local COND_LIGHT_DAMAGE = 17
local COND_HEAVY_DAMAGE = 18
local COND_HEAR_DANGER = 50

-- stuff that we check to "interrupt" SCHED_FORCED_GO_RUN 
local interruptConditions = {
    COND_NEW_ENEMY,
    COND_SEE_ENEMY,
    COND_SEE_FEAR,
    COND_ENEMY_DEAD,
    COND_LIGHT_DAMAGE,
    COND_HEAVY_DAMAGE,
    COND_HEAR_DANGER
}


local dynSquadLeaders = dynSquadLeaders or {}
DYN_NPC_SQUADS.allNpcs = DYN_NPC_SQUADS.allNpcs or {}

local cachedNpcs = cachedNpcs or {}
local transferCounts = transferCounts or {}

DYN_NPC_SQUADS.dynSquadCounts = DYN_NPC_SQUADS.dynSquadCounts or {}
DYN_NPC_SQUADS.teamFlankPoints = DYN_NPC_SQUADS.teamFlankPoints or {}
DYN_NPC_SQUADS.teamReinforcePoints = DYN_NPC_SQUADS.teamReinforcePoints or {}
DYN_NPC_SQUADS.dynSquadTeamIndex = DYN_NPC_SQUADS.dynSquadTeamIndex or 0

local dynSquadCounts2 = {}
local dynSquadLeaders2 = {}
local allNpcs2 = {}

local timerInterval = 1.25
local minAssembleTime = 3
local maxSquadSize = 6

local buildIndex = 0
local newBuildTime = 0
local newBuildReady = true
local doingBuild = false

local aiDisabled = GetConVar( "ai_disabled" )

local function enabledAi()
    return aiDisabled:GetInt() == 0

end

local function dirToPosFlat( startPos, endPos )
    if not startPos then return end
    if not endPos then return end

    local subtractionResult = ( endPos - startPos )
    subtractionResult.z = 0

    return subtractionResult:GetNormalized()

end

local function shootPosOrFallback( ent )
    if ent.GetShootPos then
        return ent:GetShootPos()

    else
        return ent:WorldSpaceCenter()

    end
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

local function npcSquad( npc )
    if not IsValid( npc ) then return nil end

    local vals = npc:GetKeyValues()
    local squad = vals["squadname"]
    if not squad and npc.GetSquad then
        squad = npc:GetSquad()

    end

    if not squad then return nil end
    if not isstring( squad ) then return nil end

    return squad

end

local function npcSetDynSquad( npc, squad )
    if not IsValid( npc ) then return end

    local oldSquad = npc:GetSquad() or ""
    if oldSquad ~= "" then
        local oldCount = DYN_NPC_SQUADS.dynSquadCounts[ oldSquad ] or 0
        DYN_NPC_SQUADS.dynSquadCounts[ oldSquad ] = math.Clamp( oldCount + -1, 0, math.huge )

    end

    npc.dynamicSquad = squad
    local vals = npc:GetKeyValues()

    if npc.SetSquad then
        npc:SetSquad( squad )

    end
    if vals["squadname"] then
        npc:SetKeyValue( "squadname", squad )

    end

    local count = DYN_NPC_SQUADS.dynSquadCounts[ squad ] or 0
    DYN_NPC_SQUADS.dynSquadCounts[ squad ] = count + 1

    dupeData = { ["squadname"] = squad }
    duplicator.StoreEntityModifier( npc, "dynsquads_squadinfo", dupeData )

    if developerBool then
        local leader = ai.GetSquadLeader( squad )
        if not IsValid( leader ) then return end

        debugoverlay.Text( npc:GetPos(), "joined", 4, true )
        debugoverlay.Line( npc:GetPos(), leader:GetPos(), 4 )

    end
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
function DYN_NPC_SQUADS.NpcsAreChummy( chummer, chummee )
    if not IsValid( chummer ) then return end
    if not IsValid( chummee ) then return end
    local chummersType = type( chummer )
    local chummeesType = type( chummee )
    local dispToChummee = chummer:Disposition( chummee )
    local dispToChummer = chummee:Disposition( chummer )

    local likedBothWays = dispToChummer == D_LI and dispToChummee == dispToChummer
    local neutralBothWays = dispToChummer == D_NU and dispToChummee == dispToChummer

    local sameTypeAndNeutral = chummeesType == chummersType and neutralBothWays
    local likesOrIndifferent = likedBothWays or sameTypeAndNeutral

    return likesOrIndifferent

end

-- get oot me way mate!
local function tellToMove( teller, telee )
    if not IsValid( teller ) or not IsValid( telee ) then return end
    if not teller:IsNPC() or not telee:IsNPC() then return end
    if not DYN_NPC_SQUADS.NpcsAreChummy( teller, telee ) then return end
    if hook.Run( "dynsquads_blockmovement", telee ) == true then return end
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

            local chummyToLeader = DYN_NPC_SQUADS.NpcsAreChummy( me, currentLeader )
            local currSquad = npcSquad( currentLeader )
            local currCount = DYN_NPC_SQUADS.dynSquadCounts[ currSquad ] or 0
            local isMe = currentLeader == me

            if currCount ~= nil and currSquad and not isMe and chummyToLeader then
                local atCapacity = currCount >= maxSquadSize

                if not atCapacity then
                    DYN_NPC_SQUADS.NpcPlaySound( me, "joinednewleader" )
                    npcSetDynSquad( me, currSquad )
                    success = true
                    me.findLeaderFailures = nil
                    break

                end
            end
        end
    end
    return success

end

local function dynSquadCanBranchOff( me )
    local newName = "dyn_" .. me:GetCreationID()
    if me.dynamicSquad == newName then return false, newName end
    return true, newName

end


-- make a new squad 
local function dynSquadNpcBranchOff( me )
    local canBranch, newName = dynSquadCanBranchOff( me )
    if not canBranch then return end

    if me.dynamicSquad then
        local oldSquad = npcSquad( me )
        local oldCount = DYN_NPC_SQUADS.dynSquadCounts[oldSquad]
        if oldCount then
            DYN_NPC_SQUADS.dynSquadCounts[oldSquad] = oldCount + -1

        end
    end

    npcSetDynSquad( me, newName ) -- invent new squads
    table.insert( dynSquadLeaders, me )
    me.LeaderPromotionTime = CurTime()

    return true

end

-- find a squad leader that takes us on, else just make a new squad
local function dynSquadAutoTransfer( me, currentSquad )
    local success = nil
    local myCount = DYN_NPC_SQUADS.dynSquadCounts[currentSquad] or 0
    local inOnboardSquad = currentSquad == "" and me.dynSquadInBacklog
    if inOnboardSquad then
        success = dynSquadFindAcceptingLeader( me )
        if success then me.dynSquadInBacklog = nil return end

        local didBranch = dynSquadNpcBranchOff( me )
        if not didBranch then return end
        me.dynSquadInBacklog = nil

        if npcIsAlert( me ) then return end
        DYN_NPC_SQUADS.NpcPlaySound( me, "inventedsquadcalm" )

    else
        if myCount <= 1 or myCount > maxSquadSize then
            success = dynSquadFindAcceptingLeader( me )
        end

        if success then me.dynSquadInBacklog = nil return end
        if myCount > 1 and myCount < maxSquadSize then return end
        local didBranch = dynSquadNpcBranchOff( me )
        if not didBranch then return end
        me.dynSquadInBacklog = nil

        if npcIsAlert( me ) then return end
        DYN_NPC_SQUADS.NpcPlaySound( me, "inventedsquadcalm" )

    end
end

local function dynSquadValid( me, squad )
    if not me.dynamicSquad then return true end
    if me.dynamicSquad == squad then return true end
    return false

end


local function canDynSquadsMove( me, state )
    state = state or me:GetNPCState()
    if state == NPC_STATE_SCRIPT then return end
    -- asleep check
    if me:IsCurrentSchedule( -1 ) then return end
    if me.dynSquads_DontMove and me.dynSquads_DontMove > CurTime() then return end
    if hook.Run( "dynsquads_blockmovement", me ) == true then return end

    return true

end

local function npcWanderForward( me, refent, dist )
    if me:GetPathDistanceToGoal() > 25 then return end
    if not canDynSquadsMove( me ) then return end

    dist = dist or 512
    me:SetSchedule( SCHED_IDLE_WALK )
    me:NavSetRandomGoal( dist, refent:GetAimVector() )

end

local function npcWanderAwayFrom( me, pos )
    if me:GetPathDistanceToGoal() > 25 then return end
    if not canDynSquadsMove( me ) then return end

    me:SetSchedule( SCHED_IDLE_WALK )
    me:NavSetRandomGoal( 512, dirToPosFlat( pos, me:GetPos() ) )

end

local standScheds = {
    [NPC_STATE_ALERT] = SCHED_ALERT_STAND,
    [NPC_STATE_IDLE] = SCHED_IDLE_STAND,

}

local goRunSched = SCHED_FORCED_GO_RUN
local failSched = SCHED_FAIL

-- cancel long distance go_run assaults
-- go_run lacks interrupt conditions, so this has to be called if the npc takes damage, etc
local function npcCancelGo( me )
    if not me.wasDoingConfirmedDynsquadsGo then return end
    if not canDynSquadsMove( me ) then return end
    me.wasDoingConfirmedDynsquadsGo = nil

    local isSched = me:IsCurrentSchedule( goRunSched )
    if isSched then
        me:SetSchedule( SCHED_COMBAT_FACE )

    end
end

hook.Add( "EntityTakeDamage", "dynsquads_breaktrances", function( damaged )
    if not damaged.wasDoingConfirmedDynsquadsGo then return end
    if not damaged:IsCurrentSchedule( goRunSched ) then damaged.wasDoingConfirmedDynsquadsGo = nil return end

    npcCancelGo( damaged )

    local squad = npcSquad( damaged )
    if not squad then return end

    for _, squadmate in ipairs( ai.GetSquadMembers( squad ) ) do
        if squadmate.wasDoingConfirmedDynsquadsGo then
            if not squadmate:IsCurrentSchedule( goRunSched ) then
                squadmate.wasDoingConfirmedDynsquadsGo = nil

            else
                npcCancelGo( squadmate )

            end
        end
    end
end )

local function npcPathRunToPos( me, pos )
    if not canDynSquadsMove( me ) then return end

    if me:IsCurrentSchedule( failSched ) then return end

    local didNewPath
    local myGoal = me:GetGoalPos() or vec_zero
    local goodMoving = me:IsCurrentSchedule( goRunSched ) and sqrDistLessThan( myGoal:DistToSqr( pos ), 250 )
    local isCondition = npcHasConditions( me, interruptConditions )

    if isCondition then
        npcCancelGo( me )

    elseif not goodMoving then
        me:SetSaveValue( "m_vecLastPosition", pos )
        didNewPath = true

        me:SetSchedule( goRunSched )
        me.wasDoingConfirmedDynsquadsGo = true

    end

    return didNewPath

end

local function npcStandWatch( me, myLeader )
    if not canDynSquadsMove( me ) then return end

    local targetSched = standScheds[me:GetNPCState()] or SCHED_ALERT_STAND

    if me:IsCurrentSchedule( targetSched ) then return end
    me:SetSchedule( targetSched )

    local myShoot = shootPosOrFallback( me )
    local leadersShoot = shootPosOrFallback( myLeader )

    local awayFromLeader = dirToPosFlat( leadersShoot, myShoot )
    -- flatten
    awayFromLeader.z = 0
    awayFromLeader:Normalize()

    local dir = 11.25
    if math.random( 1, 100 ) > 50 then
        dir = -dir

    end
    local rotator = Angle( 0, dir, 0 )
    local dist = 500

    -- dont look directly at walls
    for _ = 1, 16 do
        local offset = awayFromLeader * dist
        local offsetted = myShoot + offset
        if me:VisibleVec( offsetted ) then
            local asAngle = awayFromLeader:Angle()
            me:SetIdealYawAndUpdate( asAngle.yaw, 1 )

            -- final check, is this a "perfect" direction?
            local distLong = dist * 4
            if me:VisibleVec( myShoot + ( awayFromLeader * distLong ) ) then
                return true

            else
                return

            end

        else
            awayFromLeader:Rotate( rotator )

        end
    end
    -- nowhere good to look, fallback
    local asAngle = awayFromLeader:Angle()
    me:SetIdealYawAndUpdate( asAngle.yaw, 1 )

end


local function newDynTeam( npc )
    DYN_NPC_SQUADS.dynSquadTeamIndex = DYN_NPC_SQUADS.dynSquadTeamIndex + 1
    npc.dynSquadTeam = DYN_NPC_SQUADS.dynSquadTeamIndex
    DYN_NPC_SQUADS.teamFlankPoints[npc.dynSquadTeam] = {}
    DYN_NPC_SQUADS.teamReinforcePoints[npc.dynSquadTeam] = {}

end

local function establishTeamIfChummy( npc1, npc2 )
    if not IsValid( npc1 ) then return false end
    if not IsValid( npc2 ) then return false end
    if not npc2.dynSquadTeam then return false end
    if not DYN_NPC_SQUADS.NpcsAreChummy( npc1, npc2 ) then return false end

    npc1.dynSquadTeam = npc2.dynSquadTeam
    return true

end

local function teamCheck( npc )
    if npc.dynSquadTeam then return end
    local joinedSomeone
    for _, currentNpc in ipairs( DYN_NPC_SQUADS.allNpcs ) do
        joinedSomeone = establishTeamIfChummy( npc, currentNpc )
        if joinedSomeone then break end

    end
    if joinedSomeone then return end
    newDynTeam( npc )

end

local function findOtherLeaderNearby( me, pos )
    local nearest
    local nearestDist = math.huge
    local myTeam = me.dynSquadTeam

    for _, currLeader in ipairs( dynSquadLeaders ) do
        if
            IsValid( currLeader )
            and currLeader == me
            and myTeam ~= currLeader.dynSquadTeam

        then
            local dist = currLeader:GetPos():DistToSqr( pos )
            if dist < nearestDist then
                nearest = currLeader
                nearestDist = dist

            end
        end
    end
    return nearest, nearestDist

end

local closeEnoughToWipe = 300^2
local maxDuplicates = 8

local function addPoint( points, theTeam, time, pos )
    time = math.Round( time )
    local currReinforcePoints = points[theTeam]
    if not currReinforcePoints then
        points[theTeam] = {}
        currReinforcePoints = points[theTeam]

    end

    -- remove duplicates if there's too many
    -- only if there's too many, so that there's enough points for multiple squads to eat up, at all times
    local duplicateCount = 0
    for currTime, currPos in pairs( currReinforcePoints ) do
        if currPos:DistToSqr( pos ) < closeEnoughToWipe then
            duplicateCount = duplicateCount + 1

            if duplicateCount >= maxDuplicates then
                currReinforcePoints[currTime] = nil

            end
        else
            duplicateCount = 0

        end
    end

    currReinforcePoints[time] = pos

end


-- priority here is inverse sorta
-- 0 priority is highest priority
-- can do negative but itll probably break stuff
local function saveFlankPoint( npc, pos, priority )
    local dynTeam = npc.dynSquadTeam
    if not dynTeam then return end
    priority = priority or 0

    addPoint( DYN_NPC_SQUADS.teamFlankPoints, dynTeam, CurTime() - priority, pos )

end

local function saveReinforcePoint( npc, pos, priority )
    local dynTeam = npc.dynSquadTeam
    if not dynTeam then return end
    priority = priority or 0

    addPoint( DYN_NPC_SQUADS.teamReinforcePoints, dynTeam, CurTime() - priority, pos )

end

function DYN_NPC_SQUADS.SaveReinforcePointAllNpcTeams( pos, filter, priority )
    priority = priority or 0

    local time = CurTime() - priority
    local points = DYN_NPC_SQUADS.teamReinforcePoints
    for teamsId, _ in pairs( points ) do
        local filterBlocks = filter and not filter( teamsId )
        if not filterBlocks then
            addPoint( points, teamsId, time, pos )

        end
    end
end

-- make an npc tell all other npcs on it's "team" to assault a pos
function DYN_NPC_SQUADS.SaveReinforcePointFor( npc, pos, priority )
    saveReinforcePoint( npc, pos, priority )

end

local vecFor2dChecks = Vector()
local vecFor2dChecks2 = Vector()
local aboveAssaultOffset = Vector( 0, 0, 40 )
local earlyClearIfVisible = 2500

local function shouldEarlyClearAssaultpoint( me, myPos, theAssault )
    vecFor2dChecks:SetUnpacked( theAssault.x, theAssault.y, 0 )
    vecFor2dChecks2:SetUnpacked( myPos.x, myPos.y, 0 )
    local distToPoint = vecFor2dChecks:DistToSqr( vecFor2dChecks2 )
    local reallyClose = sqrDistLessThan( distToPoint, 300 )
    local closeAndSee = sqrDistLessThan( distToPoint, earlyClearIfVisible ) and me:VisibleVec( theAssault + aboveAssaultOffset )
    local clearThePos = reallyClose or closeAndSee or me:IsCurrentSchedule( SCHED_FAIL )

    return clearThePos

end

local function shouldClearAssaultpoint( me, myPos, theAssault )
    vecFor2dChecks:SetUnpacked( theAssault.x, theAssault.y, 0 )
    vecFor2dChecks2:SetUnpacked( myPos.x, myPos.y, 0 )
    local distToPoint = vecFor2dChecks:DistToSqr( vecFor2dChecks2 )
    local reallyClose = sqrDistLessThan( distToPoint, 300 )
    local clearThePos = reallyClose or me:IsCurrentSchedule( SCHED_FAIL )

    return clearThePos

end

-- fill assault point cache
local function npcFillPointCache( npc, pointType )
    local currentTable = nil
    local dynTeam = npc.dynSquadTeam

    if pointType == "flank" then
        currentTable = DYN_NPC_SQUADS.teamFlankPoints[dynTeam]

    elseif pointType == "reinforce" then
        currentTable = DYN_NPC_SQUADS.teamReinforcePoints[dynTeam]

    end

    if not istable( currentTable ) then return false end

    local npcsPos = npc:GetPos()
    local bestTime = 0
    local reallyCloseDistSqr = earlyClearIfVisible^2
    local neverReallyClose = true
    local point
    -- go thru, newest to oldest
    for placedTime, pos in SortedPairs( currentTable, true ) do
        local age = CurTime() - placedTime
        -- we found a good point already, and this one's really old, just delete it
        if age > 240 and point then
            currentTable[placedTime] = nil
            if developerBool then
                debugoverlay.Text( npcsPos, "staleassaultpurge", 10, true )
                debugoverlay.Line( npcsPos, pos, 10 )

            end
        -- too close to me and i can see it
        elseif shouldEarlyClearAssaultpoint( npc, npcsPos, pos ) then
            if developerBool then
                debugoverlay.Text( npcsPos, "earlyassaultclear", 5, true )
                debugoverlay.Line( npcsPos, pos, 5 )

            end
            currentTable[placedTime] = nil

        else
            -- pick either newest, or closest if one is right next to us
            -- makes squads stick around one area for a little bit longer
            local currDistSqr = pos:DistToSqr( npcsPos )
            local reallyClose = currDistSqr < reallyCloseDistSqr
            if reallyClose then
                reallyCloseDistSqr = currDistSqr
                neverReallyClose = nil

            end
            -- update best
            if placedTime > bestTime and ( neverReallyClose or reallyClose ) then
                bestTime = placedTime
                point = pos

            end
        end
    end

    if not point then return false end
    if point and not isvector( point ) then return false end

    currentTable[bestTime] = nil

    npc.cachedPoint = point
    return true, point

end

-- call for backup!
local function saveEnemyContact( me, enemy )
    if not me:Visible( enemy ) then return end

    local enemyPos = enemy:GetPos()
    saveFlankPoint( me, enemyPos, 0 )

    if me:GetPos():DistToSqr( enemyPos ) < 3000^2 then
        saveReinforcePoint( me, me:GetPos(), 0 )

    end
    me.lastAssaultPosSaveTime = CurTime()

end

local function npcCanSavePoint( me )
    if not doassaultingBool then return false end

    local lastSaved = me.lastAssaultPosSaveTime or 0
    if ( lastSaved + 2.5 ) > CurTime() then return false end

    local squad = npcSquad( me )
    if not squad then return false end

    local currHealth = 0
    local members = ai.GetSquadMembers( squad )
    for _, member in ipairs( members ) do
        if member.Health then
            currHealth = currHealth + member:Health()

        end
    end
    local oldHealth = me.oldSquadMemberHealth or 0
    me.oldSquadMemberHealth = currHealth
    local losingHealth = currHealth < oldHealth
    if losingHealth then return true end

    local currCount = #members
    local oldCount = me.oldSquadMemberCount or 0
    me.oldSquadMemberCount = currCount
    local losingMembers = currCount < oldCount
    if losingMembers then return true end

    return false

end

-- cancel any dynsquad created SCHED_GO_RUNs
local function npcAlertThink( npc )
    npcCancelGo( npc )

    if IsValid( npc:GetEnemy() ) then
        npc.dynLastAlertTime = CurTime()

    end
end

-- main function that loops on every npc with a valid squad, everything above/below is for this
-- return nil to treat it as a halting error, and teardown the timer for this npc.
-- return true to keep the timer running
-- second var is for debugging
function DYN_NPC_SQUADS.npcDoSquadThink( me )
    if not IsValid( me ) then return nil, "invalid npc" end
    if not enabledBool then return true, "not enabled" end


    local squad = npcSquad( me )
    -- stop here if npc doesnt have "squadname" keyvalue or GetSquad function 
    if not squad then return nil, "cant squad, lua" end

    -- just makes the system wait
    if me.DynamicNpcSquadsIgnore then return true, "ignore" end
    if hook.Run( "dynsquads_blocksquadthinking", me ) == true then return true, "ignore, hook" end

    -- stop this if some other system set the squad of the npc
    -- also detects when they die?
    if not dynSquadValid( me, squad ) then return nil, "squad was overriden" end

    local caps = me:CapabilitiesGet()
    local myState = me:GetNPCState()
    local ableToAct = enabledAi() and canDynSquadsMove( me )
    local count = DYN_NPC_SQUADS.dynSquadCounts[squad] or 0
    local myLeader = ai.GetSquadLeader( squad )
    local amLeader = me:IsSquadLeader()
    local blocker = me:GetBlockingEntity()
    local soloSquad = count <= 1
    local aboveCapacity = count > maxSquadSize

    local myPos = me:GetPos()
    local myEnemy = me:GetEnemy()
    local validEnemy = IsValid( myEnemy )

    local old = ( me.LeaderPromotionTime or 0 ) + minAssembleTime < CurTime()
    local smallAndOld = count <= 1 and old

    local canUseWeapon = bit.band( caps, CAP_USE_WEAPONS ) >= 1
    local hasWep = #me:GetWeapons() > 0
    local isArmed = hasWep or bit.band( caps, CAP_INNATE_RANGE_ATTACK1 ) >= 1 or bit.band( caps, CAP_INNATE_RANGE_ATTACK2 ) >= 1 or bit.band( caps, CAP_INNATE_MELEE_ATTACK1 ) >= 1 or bit.band( caps, CAP_INNATE_MELEE_ATTACK2 ) >= 1

    local distMul = 1
    local imAFlier = bit.band( caps, CAP_MOVE_FLY )
    -- flying npcs can go far from their leaders
    if imAFlier >= 1 then
        distMul = 4

    end

    local lastAlertTime = me.dynLastAlertTime or 0

    local myModel = me:GetModel()
    local fearfulness = 0
    -- combine are basically machines, if we force them to go idle, they all go IDLE at the same time 
    if myModel and string.find( myModel, "models/combine_so" ) then
        fearfulness = 2

    -- human person, go idle at a big spread of times
    elseif myModel and ( string.find( myModel, "human" ) or string.find( myModel, "metro" ) ) then
        fearfulness = me:GetCreationID() % 10
        fearfulness = fearfulness + 5

    -- fallback/generic case
    else
        fearfulness = math.Clamp( 100 - me:Health(), 0, 100 ) + me:GetCreationID() % 4
        fearfulness = fearfulness / 10

    end

    local alert = npcIsAlert( me )
    local idle = myState == NPC_STATE_IDLE
    local fighting = validEnemy
    local needsToForceIdle = ( lastAlertTime + fearfulness ) < CurTime() and not fighting and not idle

    -- eg, npc_citizen no weapons
    if canUseWeapon and not isArmed then
        if alert then
            npcAlertThink( me )

        end
        if ableToAct and not alert and dowanderingBool and me:IsCurrentSchedule( SCHED_IDLE_STAND ) then
            npcWanderForward( me, me )
            if math.random( 1, 100 ) < 5 then
                DYN_NPC_SQUADS.NpcPlaySound( me, "ambientwander" )

            end
        end
    elseif amLeader then
        -- can i plz be lead by someone
        if soloSquad then
            dynSquadAutoTransfer( me, squad )

        end
        if smallAndOld then
            dynSquadFindAcceptingLeader( me )

        end
        if alert and fighting then
            npcAlertThink( me )
            if IsValid( myEnemy ) and npcCanSavePoint( me ) then
                saveEnemyContact( me, myEnemy )

            end
            if me.wasTraversingToAssault then
                me.squadMemberClearedAssault = nil
                me.cachedPoint = nil
                me.assaultAttempts = nil
                me.wasTraversingToAssault = nil
                DYN_NPC_SQUADS.NpcPlaySound( me, "reachedhotassault" )

            end
        end
        if ableToAct then
            if needsToForceIdle then
                -- dont be shellshocked for too long
                me:SetNPCState( NPC_STATE_IDLE )
                DYN_NPC_SQUADS.NpcPlaySound( me, "beganwandering" )

            end
            if not fighting then
                local point = me.cachedPoint
                if doassaultingBool and point then
                    if shouldClearAssaultpoint( me, myPos, point ) or me.squadMemberClearedAssault then
                        me.squadMemberClearedAssault = nil
                        me.cachedPoint = nil
                        me.assaultAttempts = nil
                        me.wasTraversingToAssault = nil
                        DYN_NPC_SQUADS.NpcPlaySound( me, "reachedassault" )

                        npcCancelGo( me )

                        if developerBool then
                            debugoverlay.Text( myPos, "assaultclear", 5, true )
                            debugoverlay.Line( myPos, point, 5 )

                        end
                    -- goto the assault
                    else
                        -- this assault aint workin!
                        local attempts = me.assaultAttempts or 0
                        if attempts > 15 then
                            me.cachedPoint = nil
                            npcCancelGo( me )
                            if developerBool then
                                debugoverlay.Text( myPos, "assaultfail", 20, true )
                                debugoverlay.Line( myPos, point, 20, Color( 255, 0, 0 ), true )

                            end
                        end

                        local setTheSched = npcPathRunToPos( me, point )
                        if setTheSched and developerBool then
                            debugoverlay.Text( myPos, "assaulted", 10, true )
                            debugoverlay.Line( myPos, point, 10, color_white, true )

                        end

                        if setTheSched and me.wasTraversingToAssault then
                            me.assaultAttempts = attempts + 1

                        end
                        me.wasTraversingToAssault = true

                    end
                elseif doassaultingBool and not point and ( me.nextCacheAttempt or 0 ) < CurTime() then
                    local choices = { [0] = "flank", [1] = "reinforce" }
                    local choice = choices[ math.random( 0, 1 ) ]

                    local success, newPoint = npcFillPointCache( me, choice )
                    if success and newPoint then
                        point = newPoint

                    end

                    if success and point and not me.wasTraversingToAssault then
                        DYN_NPC_SQUADS.NpcPlaySound( me, "acquireassault" )

                    else
                        me.nextCacheAttempt = CurTime() + math.random( 1, 3 )

                    end

                elseif not alert and dowanderingBool and not point and ( me.dynLastAlertTime or 0 ) < CurTime() then
                    -- break up death blobs of squads please
                    local nearbyLeader, theirDist = findOtherLeaderNearby( me, myPos )
                    if nearbyLeader and sqrDistLessThan( theirDist, 1200 * distMul ) then
                        npcWanderAwayFrom( me, nearbyLeader:GetPos() )

                    else
                        -- wander with a bigger dist, forcing leader to actually leave enclosed spaces
                        npcWanderForward( me, me, 2048 )

                    end

                    if me.dynLastAlertTime and ( me.playedBeginWanderSound or 0 ) ~= me.dynLastAlertTime then
                        DYN_NPC_SQUADS.NpcPlaySound( me, "beganwandering" )
                        me.playedBeginWanderSound = me.dynLastAlertTime

                    elseif math.random( 1, 100 ) < 10 then
                        DYN_NPC_SQUADS.NpcPlaySound( me, "ambientwander" )

                    end
                end
            end
        end
    elseif IsValid( myLeader ) and not aboveCapacity then
        if alert then
            npcAlertThink( me )

        end
        if ableToAct then
            -- if im a grounder lead by a flier, dont try to get as close to my leader
            if not imAFlier then
                local leadersCaps = myLeader:CapabilitiesGet()
                if bit.band( leadersCaps, CAP_MOVE_FLY ) >= 1 then
                    distMul = 2

                end
            end

            local leadersPoint = myLeader.cachedPoint
            local leadersRealPos = myLeader:GetPos()
            local whereLeaderWantsUs

            local canReturnToLeader = ( me.nextReturnBackToLeader or 0 ) < CurTime()

            local leadersGoal = myLeader:GetGoalPos()
            if leadersGoal and leadersGoal ~= vec_zero then
                whereLeaderWantsUs = leadersGoal

            else
                whereLeaderWantsUs = leadersRealPos

            end
            local leaderDirToMe = dirToPosFlat( whereLeaderWantsUs, myPos )
            whereLeaderWantsUs = whereLeaderWantsUs + ( leaderDirToMe * math.random( 100, 200 ) * distMul )

            local compareToLeaderWants
            local whereIllEndUp = me:GetGoalPos()
            if whereIllEndUp and whereIllEndUp ~= vec_zero then
                compareToLeaderWants = whereIllEndUp

            else
                compareToLeaderWants = myPos

            end
            local distToWhereLeaderWants = compareToLeaderWants:DistToSqr( whereLeaderWantsUs )
            local sqrDistToLeader = myPos:DistToSqr( leadersRealPos )

            if needsToForceIdle then
                -- followers stop being shellshocked a bit after their leaders
                local fearfulnessStopHuddling = fearfulness + 8

                if ( lastAlertTime + fearfulnessStopHuddling ) < CurTime() then
                    me:SetNPCState( NPC_STATE_IDLE )
                    DYN_NPC_SQUADS.NpcPlaySound( me, "beganwandering" )

                end
            -- leader is assaulting
            elseif idle and doassaultingBool and leadersPoint and canDynSquadsMove( myLeader ) then
                -- handle "follow the leader!" sounds
                local nextNotify = me.nextPointNotify or 0
                if leadersPoint ~= me.notifedPoint and nextNotify < CurTime() then
                    me.nextPointNotify = CurTime() + 12
                    me.notifedPoint = leadersPoint
                    DYN_NPC_SQUADS.NpcPlaySound( me, "movingtoassault" )

                end

                if not myLeader.squadMemberClearedAssault and shouldClearAssaultpoint( me, myPos, leadersPoint ) then
                    myLeader.squadMemberClearedAssault = true

                end

                -- meet up with the leader at the assault pos
                if sqrDistGreaterThan( myPos:DistToSqr( leadersPoint ), 400 * distMul ) then
                    local goal = leadersPoint + ( leaderDirToMe * math.random( 100, 200 ) * distMul )
                    npcPathRunToPos( me, goal )

                -- we got there before the leader
                elseif dowanderingBool then
                    npcWanderForward( me, me )

                end
            -- im not doing anything, get close to my leader!
            elseif idle and canReturnToLeader and sqrDistGreaterThan( distToWhereLeaderWants, 500 * distMul ) then
                npcPathRunToPos( me, whereLeaderWantsUs )
                if math.random( 1, 100 ) < 10 then
                    DYN_NPC_SQUADS.NpcPlaySound( me, "ambientwander" )

                end

            -- walk with leader
            elseif idle then
                -- far from leader, unintentionally
                -- so we make the npc stand watch instead, to make it look smart
                if sqrDistGreaterThan( sqrDistToLeader, 700 * distMul ) then
                    -- only armed/range attacking npcs stand watch
                    if not me.wasStandingWatch and hasWep then
                        me.wasStandingWatch = true
                        local perfect = npcStandWatch( me, myLeader )
                        -- watch this big open area
                        if perfect and sqrDistLessThan( distToWhereLeaderWants, 1000 * distMul ) then
                            local time = math.random( 12, 22 )
                            me.nextReturnBackToLeader = CurTime() + time

                        end
                        -- play a sound, very funny when npc_citizen plays a line
                        if math.random( 1, 100 ) < 10 then
                            DYN_NPC_SQUADS.NpcPlaySound( me, "ambientwander" )

                        end
                    elseif idle and canReturnToLeader and sqrDistGreaterThan( distToWhereLeaderWants, 400 * distMul ) then
                        npcPathRunToPos( me, whereLeaderWantsUs )

                    end
                -- close to the leader, walk alongside them
                elseif dowanderingBool then
                    me.wasStandingWatch = nil
                    local time = math.random( 2, 8 )
                    me.nextReturnBackToLeader = CurTime() + time
                    npcWanderForward( me, myLeader )

                end
            end
        end
    else
        dynSquadAutoTransfer( me, squad )

    end
    if IsValid( blocker ) then
        tellToMove( me, blocker )

    end
    return true, "all good"

end


-- store a npc in the correct tables
local function dynSquadThinkProcessNpc( npc )
    if not IsValid( npc ) then return end

    local squad = npcSquad( npc )
    if not squad then return end

    table.insert( allNpcs2, npc )

    local currCount = dynSquadCounts2[squad] or 0
    dynSquadCounts2[squad] = currCount + 1

    local leader = npc:IsSquadLeader()
    local small = not IsValid( npc:GetNearestSquadMember() )
    local leaderOrSmall = leader or small

    if not leaderOrSmall then return end
    table.insert( dynSquadLeaders2, npc )

end

-- on tick incrimental function that slowly chips away at big tasks
-- this predates my knowledge of coroutines....
local function dynSquadThink()
    if not enabledBool then return end

    -- do a new build every minAssembleTime ( 3 seconds )
    if newBuildReady and newBuildTime < CurTime() then
        newBuildReady = false
        newBuildTime = CurTime() + minAssembleTime
        doingBuild = true

        dynSquadCounts2 = {}
        dynSquadLeaders2 = {}
        allNpcs2 = {}
        cachedNpcs = DYN_NPC_SQUADS.allNpcs
        buildIndex = 0

    elseif doingBuild then
        -- chip away at the task one npc at a time
        local max = #cachedNpcs
        if buildIndex <= max then
            dynSquadThinkProcessNpc( cachedNpcs[ buildIndex ] )
            buildIndex = buildIndex + 1

        elseif buildIndex > max then
            doingBuild = false
            newBuildReady = true

            dynSquadLeaders = dynSquadLeaders2
            DYN_NPC_SQUADS.dynSquadCounts = dynSquadCounts2
            DYN_NPC_SQUADS.allNpcs = allNpcs2

            transferCounts = {}

            -- think slow when no npcs
            if #DYN_NPC_SQUADS.allNpcs <= 0 then
                newBuildTime = CurTime() + minAssembleTime * 15

            end
        end
    end
end

hook.Add( "Tick", "STRAW_dynamic_npc_squads_think", dynSquadThink )

local function dynSquadInitializeNpc( me )
    if not IsValid( me ) then return end

    table.insert( DYN_NPC_SQUADS.allNpcs, me )
    teamCheck( me )

    -- pasted in!
    if me.dynamicSquad then
        me:SetSquad( me.dynamicSquad )

    else
        me:SetSquad( "" )
        me.dynSquadInBacklog = true

    end

    local identifier = me:GetCreationID() .. "STRAW_dynamic_npc_squads_think"

    -- do one instant think.
    local goodInit = DYN_NPC_SQUADS.npcDoSquadThink( me )
    if not goodInit then return end

    -- then repeat
    timer.Create( identifier, timerInterval, math.huge, function()
        local good = DYN_NPC_SQUADS.npcDoSquadThink( me )
        if not good then timer.Remove( identifier ) return end

    end )
end

local blacklistedClasses = { -- crash fix
    ["npc_manhack"] = true,
    ["npc_sniper"] = true,
    ["npc_rollermine"] = true

}

-- introduces npcs to the system
hook.Add( "OnEntityCreated", "dynamic_npc_squads_acquirenpcs", function( entity )
    if not IsValid( entity ) then return end
    if not entity:IsNPC() then return end

    -- stop all npcs from thinking in sync
    local rand = math.random( 0, timerInterval )
    timer.Simple( 0.5 + rand, function()
        if not npcSquad( entity ) then return end
        if blacklistedClasses[entity:GetClass()] then return end

        dynSquadInitializeNpc( entity )

    end )
end )

-- sort of dupe support
local function dynSquadPasteSquad( _, pasted, data )
    timer.Simple( 0, function()
        if not IsValid( pasted ) then return end
        if not istable( data ) then return end

        if data["squadname"] then
            pasted.dynHasBeenProcessed = nil
            pasted.dynSquadTeam = nil
            npcSetDynSquad( pasted, data["squadname"] )

        end
    end )
end
duplicator.RegisterEntityModifier( "dynsquads_squadinfo", dynSquadPasteSquad )