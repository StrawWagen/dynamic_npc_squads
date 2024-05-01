local aiDisabled = GetConVar( "ai_disabled" )
local function enabledAi()
    return aiDisabled:GetInt() == 0

end

DYN_NPC_SQUADS = DYN_NPC_SQUADS or {}

local doyapping = CreateConVar( "npc_dynsquads_yapping", 1, FCVAR_ARCHIVE, "Should dynsquads make npcs yap?" )
local developer = GetConVar( "npc_dynsquads_developer" )

local developerBool = developer:GetBool()
cvars.AddChangeCallback( "npc_dynsquads_developer", function( _, _, new )
    developerBool = tobool( new )

end, "dynsquads_detectchange2" )

-- most of these are not raw soundpaths
-- they have additional info embedded into them that's processed by DYN_NPC_SQUADS.NpcPlaySound
-- eg _gender is processed into male01/female01 for human npcs
-- sent_ specifies that the path is a "sentence"
-- _variants is replaced with a random string set by the variants key, eg 01, 10

-- don't modify this table, modify DYN_NPC_SQUADS.soundCategories instead!
local defaultSoundCategories = {
    ["replytovort"] = {
        ["models/humans/"] = { line = "human_vo/npc/_gender/vanswer_variants.wav", variants = 14, followerNoTalkChance = 0 },
        ["models/vort"] = { lines = {
            { line = "human_vo/npc/vortigaunt/vanswer_variants.wav", variants = 18 },
            { line = "human_vo/npc/vortigaunt/vortigese_variants.wav", variants = 12 },
        }, followerNoTalkChance = 0 }
    },
    ["replytohuman"] = {
        ["models/humans/"] = { line = "human_vo/npc/_gender/answer_variants.wav", variants = 40, followerNoTalkChance = 0 },
        ["models/vort"] = { line = "human_vo/npc/vortigaunt/vanswer_variants.wav", variants = 18, followerNoTalkChance = 0 }
    },
    ["acquireassault"] = {
        ["backup"] = IdleSound,
        ["models/police.mdl"] = "sent_METROPOLICE_HEARD_SOMETHING",
        ["models/hunter.mdl"] = "NPC_Hunter.Scan",
        ["models/combine_so"] = "sent_COMBINE_FLANK",
        ["models/humans/"] = { line = "human_vo/npc/_gender/squad_away_variants.wav", variants = 3, globalDelay = 5 },
    },
    ["movingtoassault"] = {
        ["backup"] = FoundEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_ANSWER_CR",
        ["models/hunter.mdl"] = "NPC_Hunter.Alert",
        ["models/combine_so"] = "sent_COMBINE_ANSWER",
        ["models/humans/"] = { lines = {
            { line = "human_vo/npc/_gender/letsgo_variants.wav", variants = 2 },
            { line = "human_vo/npc/_gender/ok_variants.wav", variants = 2 },
        }, globalDelay = 1, followerNoTalkChance = 80 },
    },
    ["reachedassault"] = {
        ["backup"] = LostEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_CLEAR",
        ["models/hunter.mdl"] = "NPC_Hunter.Idle",
        ["models/combine_so"] = "sent_COMBINE_CLEAR",
        ["models/humans/"] = { line = "human_vo/npc/_gender/question_variants.wav", variants = 31, skipChance = 50, globalDelay = 5 },
    },
    ["reachedhotassault"] = {
        ["backup"] = FoundEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_GO_ALERT",
        ["models/hunter.mdl"] = "NPC_Hunter.FoundEnemy",
        ["models/combine_so"] = "sent_COMBINE_ALERT",
        ["models/humans/"] = { lines = {
            "human_vo/npc/_gender/incoming02.wav",
            "human_vo/npc/_gender/goodgod.wav",
            "human_vo/npc/_gender/ohno.wav",
            "human_vo/npc/_gender/okimready03.wav",
            "human_vo/npc/_gender/overthere02.wav",
            "human_vo/npc/_gender/takecover02.wav",
            "human_vo/npc/_gender/uhoh.wav",
            "human_vo/npc/_gender/yeah02.wav",
            "human_vo/npc/_gender/question26.wav",
            "human_vo/npc/_gender/squad_affirm05.wav",
            "human_vo/npc/_gender/squad_affirm06.wav",
            "human_vo/npc/_gender/headsup01.wav",
            "human_vo/npc/_gender/headsup02.wav",
            "human_vo/trainyard/_gender/cit_window_use01.wav",
        }, globalDelay = 15 },
    },
    ["joinednewleader"] = {
        ["backup"] = IdleSound,
        ["models/police.mdl"] = { line = "sent_METROPOLICE_IDLE_ANSWER", globalDelay = 5 },
        ["models/hunter.mdl"] = { line = "npc/ministrider/hunter_idle2.wav", globalDelay = 5 },
        ["models/combine_so"] = { line = "sent_COMBINE_ANSWER", globalDelay = 5 },
        ["models/humans/"] = { line = "human_vo/npc/_gender/question_variants.wav", variants = 31, skipChance = 80, globalDelay = 5 },
    },
    ["inventedsquadcalm"] = {
        ["backup"] = IdleSound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE",
        ["models/hunter.mdl"] = "npc/ministrider/hunter_idle3.wav",
        ["models/combine_so"] = "sent_COMBINE_CLEAR",
        ["models/humans/"] = { line = "human_vo/npc/_gender/squad_away_variants.wav", variants = 3, skipChance = 50, globalDelay = 5 },
    },
    ["beganwandering"] = {
        ["backup"] = LostEnemySound,
        ["models/police.mdl"] = "sent_METROPOLICE_IDLE_CLEAR_CR",
        ["models/hunter.mdl"] = "npc/ministrider/hunter_idle1.wav",
        ["models/combine_so"] = "sent_COMBINE_LOST_LONG",
        ["models/humans/"] = { lines = {
            "human_vo/npc/_gender/finally.wav",
            "human_vo/npc/_gender/gordead_ans01.wav",
            "human_vo/npc/_gender/gordead_ans03.wav",
            "human_vo/npc/_gender/gordead_ans04.wav",
            "human_vo/npc/_gender/gordead_ans07.wav",
            "human_vo/npc/_gender/gordead_ans15.wav",
            "human_vo/npc/_gender/gordead_ans19.wav",
            "human_vo/npc/_gender/gordead_ques02.wav",
            "human_vo/npc/_gender/gordead_ques09.wav",
            "human_vo/npc/_gender/gordead_ques11.wav",
            "human_vo/npc/_gender/gordead_ques16.wav",
            "human_vo/npc/_gender/gordead_ques19.wav",
            "human_vo/npc/_gender/gordead_ques23.wav",
            "human_vo/npc/_gender/gordead_ques25.wav",
            "human_vo/npc/_gender/gordead_ques26.wav",
            "human_vo/npc/_gender/gordead_ques30.wav",
            "human_vo/npc/_gender/question02.wav",
            "human_vo/npc/_gender/question09.wav",
            "human_vo/npc/_gender/okimready01.wav",
        }, variants = 2, skipChance = 50, globalDelay = 15 },
    },
    ["ambientwander"] = {
        ["backup"] = LostEnemySound,
        ["models/police.mdl"] = { line = "sent_METROPOLICE_IDLE_CR", globalDelay = 5 },
        ["models/hunter.mdl"] = { line = "npc/ministrider/hunter_idle1.wav", globalDelay = 5 },
        ["models/combine_so"] = { line = "sent_COMBINE_IDLE", globalDelay = 5 },
        ["models/humans/"] = { lines = {
            { line = "human_vo/npc/_gender/question_variants.wav", variants = 31 },
            { line = "human_vo/npc/_gender/doingsomething.wav" },
        }, skipChance = 60, globalDelay = 20 },
        ["models/vort"] = { line = "human_vo/npc/vortigaunt/vques_variants.wav", variants = 10, skipChance = 65, globalDelay = 15 }
    },
}

local nextFix = 0
local function fixSoundCategories()
    -- dont spam
    if nextFix > CurTime() then return end
    nextFix = CurTime() + 2
    DYN_NPC_SQUADS.soundCategories = table.Copy( defaultSoundCategories )

end

-- add to/edit THIS table please
DYN_NPC_SQUADS.soundCategories = {}
fixSoundCategories()

local function errorCatchingMitt( errMessage )
    ErrorNoHaltWithStack( errMessage )

end

local nextHumanProcessedLines = {}
local globalNextPlay = {}

local function playSound( npc, soundKey )
    if not doyapping:GetBool() then return end
    if not enabledAi() then return end
    if not IsValid( npc ) then return end
    if npc:GetMaxHealth() > 0 and npc:Health() <= 0 then return end

    local model = npc:GetModel()
    if not model then return end
    model = string.lower( model )
    local soundCategory = DYN_NPC_SQUADS.soundCategories[soundKey]

    local playData = soundCategory["backup"]
    for modelKey, playedAtModel in pairs( soundCategory ) do
        if string.find( model, modelKey ) then
            playData = playedAtModel
            break

        end
    end

    local toPlay
    local followerNoTalkChance = 50

    -- parse playdata tables
    if istable( playData ) then
        local skipChance = playData.skipChance
        if skipChance and math.random( 1, 100 ) < skipChance then return end

        if playData.followerNoTalkChance then
            followerNoTalkChance = playData.followerNoTalkChance

        end

        local variants
        local line
        if playData.line then
            line = playData.line
            variants = playData.variants

        elseif playData.lines then
            local linesData = table.Random( playData.lines )
            if istable( linesData ) then
                line = linesData.line
                variants = linesData.variants

            else
                line = linesData

            end
        end

        local globalDelay = playData.globalDelay

        playData = line

        if istable( variants ) then
            playData = string.Replace( playData, "_variants", table.Random( variants ) )

        elseif isnumber( variants ) then
            local variantAsStrNum = math.random( 1, variants )
            if variantAsStrNum < 10 then
                variantAsStrNum = "0" .. tostring( variantAsStrNum )

            else
                variantAsStrNum = tostring( variantAsStrNum )

            end
            playData = string.Replace( playData, "_variants", variantAsStrNum )

        end

        if globalDelay then
            nextPlay = globalNextPlay[playData] or 0
            if nextPlay > CurTime() then return end

            globalNextPlay[playData] = CurTime() + globalDelay

        end

        --print( playData )

    end

    -- squad followers are quieter than leaders
    if not npc:IsSquadLeader() and math.random( 1, 100 ) < followerNoTalkChance then return end

    if isfunction( playData ) then
        npc:playData()

    elseif isstring( playData ) then
        toPlay = playData
        -- sentence
        if string.StartWith( toPlay, "sent_" ) then
            toPlay = string.Replace( toPlay, "sent_", "" )
            npc:PlaySentence( toPlay, 0, 1 )

        -- spaghetti rebel lines
        elseif string.StartWith( toPlay, "human_" ) then
            local nextLine = nextHumanProcessedLines[toPlay] or 0
            if nextLine > CurTime() then return end
            nextHumanProcessedLines[toPlay] = CurTime() + 10

            toPlay = string.Replace( toPlay, "human_", "" )
            DYN_NPC_SQUADS.HumanPlayLine( npc, toPlay )

        else
            npc:EmitSound( toPlay, 80, 100 )

        end
    end
    if developerBool then
        debugoverlay.Text( npc:GetPos(), "speak " .. tostring( soundKey ), 2, true )

    end
end

function DYN_NPC_SQUADS.NpcPlaySound( npc, soundKey )
    local noErrors = xpcall( playSound, errorCatchingMitt, npc, soundKey )
    if noErrors == false then
        fixSoundCategories()

    end
end

-- humans/vorts begin
local function makeAnotherReplyToMe( npc )
    if not IsValid( npc ) then return end
    local bestHuman
    local bestDist = math.huge
    local ourPos = npc:WorldSpaceCenter()
    local cur = CurTime()
    for _, thing in ipairs( ents.FindInSphere( ourPos, 500 ) ) do
        local thingsModel = thing:GetModel()
        if thingsModel then
            local human = string.find( thingsModel, "models/humans/" )
            local vort = string.find( thingsModel, "models/vort" )
            local answeringModel = human or vort
            if answeringModel and thing:IsNPC() and thing ~= npc and DYN_NPC_SQUADS.NpcsAreChummy( npc, thing ) then
                local dist = ourPos:DistToSqr( thing:GetPos() )
                local nextReply = thing.nextReply or 0

                if dist < bestDist and nextReply < cur then
                    bestHuman = thing
                    bestDist = dist

                end
                -- block the next one from going too early
                thing.nextReply = cur + 4

            end
        end
    end
    if not IsValid( bestHuman ) then return end
    bestHuman.nextReply = cur + 20

    if IsValid( bestHuman:GetEnemy() ) then return end

    local speakerVort = string.find( npc:GetModel(), "models/vort" )
    local played = "replytohuman"
    if speakerVort then
        played = "replytovort"

    end

    DYN_NPC_SQUADS.NpcPlaySound( bestHuman, played )
    return bestHuman

end

function DYN_NPC_SQUADS.HumanPlayLine( npc, line )
    local model = npc:GetModel()
    local replace = nil
    if string.find( model, "female" ) then
        replace = "female01"

    elseif string.find( model, "male" ) then
        replace = "male01"

    end
    if not replace and string.find( line, "_gender" ) then print( "AAAAAAAAAAAAA", line ) return end

    line = string.Replace( line, "_gender", replace )

    npc:EmitSound( line, 72, math.Rand( 99, 101 ), 1, CHAN_VOICE )
    npc.nextReply = CurTime() + 5

    local isQuestion = string.find( line, "_ques" ) or string.find( line, "/vques" ) or string.find( line, "vortigese" ) or string.find( line, "question" ) or string.find( line, "doingsomething" )
    local isAnswer = string.find( line, "answer" )
    if isQuestion then
        timer.Simple( math.Rand( 4, 6 ), function()
            makeAnotherReplyToMe( npc )
        end )
    elseif isAnswer and math.random( 1, 100 ) > 83 then
        timer.Simple( math.Rand( 4, 6 ), function()
            makeAnotherReplyToMe( npc )
        end )
    end
end