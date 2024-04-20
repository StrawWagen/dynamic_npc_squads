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