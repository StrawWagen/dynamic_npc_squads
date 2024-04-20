AddCSLuaFile()

ENT.Type = "anim"
if WireLib then
    ENT.Base = "base_wire_entity"

else
    ENT.Base = "base_gmodentity" -- :(

end

ENT.Category    = "Other"
ENT.PrintName   = "Dynsquads Goal"
ENT.Author      = "straw"
ENT.Purpose     = "attracts all Dynamic Npc Squads"
ENT.Spawnable   = true
ENT.AdminOnly   = true

ENT.DefaultModel = "models/props_junk/sawblade001a.mdl"
ENT.Material = "models/shadertest/shader5"

function ENT:SetupDataTables()
    self:NetworkVar( "Bool",    1, "On",    { KeyName = "on",   Edit = { readonly = true } } ) -- wire inputs internal
    if SERVER then
        self:SetOn( true )
    end
end

function ENT:CanAutoCopyThe( the )
    return IsValid( the ), false

end

function ENT:Initialize()
    if not SERVER then return end
    self:SetModel( self.DefaultModel )
    self:SetMaterial( self.Material )
    self:DrawShadow( false )

    self:PhysicsInit( SOLID_VPHYSICS )
    self:SetMoveType( MOVETYPE_FLY )
    self:SetCollisionGroup( COLLISION_GROUP_WORLD )

    timer.Simple( 0, function()
        if not IsValid( self ) then return end
        local obj = self:GetPhysicsObject()
        obj:EnableMotion( false )

    end )

    if not WireLib then return end

    self.Inputs = WireLib.CreateSpecialInputs( self, { "On" }, { "NORMAL" } )

end

function ENT:TriggerInput( iname, value )
    if iname == "On" then
        if value >= 1 then
            self:SetOn( true )
            self:NextThink( CurTime() + 0.01 )

        else
            self:SetOn( false )
            self:NextThink( CurTime() + 0.01 )

        end
    end
end

local radius = 750

function ENT:Think()
    if not SERVER then return end
    if not self:GetOn() then return end

    local ownedTeam
    local myPos = self:GetPos()
    local nearby = ents.FindInSphere( myPos, radius )
    for _, curr in ipairs( nearby ) do
        local currTeam = curr.dynSquadTeam
        if currTeam and curr:GetNPCState() == NPC_STATE_IDLE then
            ownedTeam = currTeam
            -- make one squad stay here
            local squad = curr:GetSquad()
            if squad then
                local leader = ai.GetSquadLeader( squad )
                if IsValid( leader ) and leader:GetPos():Distance( myPos ) < radius then
                    leader.dynSquads_DontMove = CurTime() + 5

                end

                break

            end
        end
    end
    DYN_NPC_SQUADS.SaveReinforcePointAllNpcTeams( self:GetPos(), function( teamId )
        if ownedTeam and ownedTeam == teamId then return false end
        return true

    end )
    self:NextThink( CurTime() + 1 )
    return true

end

if CLIENT then
    -- copied from campaign entities...
    local cachedIsEditing = nil
    local nextCache = 0
    local CurTime = CurTime
    local LocalPlayer = LocalPlayer

    local function dynsquads_CanBeUgly()
        local ply = LocalPlayer()
        if IsValid( ply:GetActiveWeapon() ) and string.find( LocalPlayer():GetActiveWeapon():GetClass(), "camera" ) then return false end
        return true

    end

    local function dynsquads_IsEditing()
        if nextCache > CurTime() then return cachedIsEditing end
        nextCache = CurTime() + 0.01

        local ply = LocalPlayer()
        local moveType = ply:GetMoveType()
        if moveType ~= MOVETYPE_NOCLIP then     cachedIsEditing = nil return end
        if ply:InVehicle() then                 cachedIsEditing = nil return end
        if not dynsquads_CanBeUgly() then        cachedIsEditing = nil return end

        cachedIsEditing = true
        return true

    end

    function ENT:Draw()
        if dynsquads_IsEditing() then
            self:DrawModel()

        end
    end
end