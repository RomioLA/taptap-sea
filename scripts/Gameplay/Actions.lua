-- Gameplay owns tokens and receipts; Runtime alone owns fish and capture locks.
local Items = require('data.items')
local Config = require('config.gameplay')
---@class GameplayActionPoint
---@field x number
---@field y number

---@class GameplayFishingToken

---@class GameplayFishingRecord
---@field token GameplayFishingToken
---@field runtime table
---@field center GameplayActionPoint
---@field targetId string?
---@field itemId string?
---@field generation number
---@field seaGeneration number
---@field state string
---@field elapsed number
---@field reason string?
---@field result table?
---@field rollback table?

---@class GameplayActions
---@field loop GameplayLoop
---@field runtime table?
---@field dropTarget GameplayActionPoint?
---@field selection table?
---@field _fishingTokens table<GameplayFishingToken, GameplayFishingRecord>
---@field _pendingFishing GameplayFishingRecord?
---@field _lastFishing GameplayFishingRecord?
---@field _pendingCatch table?
local Actions = {}
Actions.__index = Actions
local function point(v)
    return type(v)=='table' and type(v.x)=='number' and type(v.y)=='number'
        and v.x==v.x and v.y==v.y and math.abs(v.x)<math.huge and math.abs(v.y)<math.huge
end
local function copyPoint(v) return {x=v.x,y=v.y} end
local function call(runtime, name, ...)
    if type(runtime)~='table' or type(runtime[name])~='function' then
        return false, 'fishing_runtime_interface_unavailable'
    end
    return pcall(runtime[name], runtime, ...)
end
function Actions.New(loop)
    local self=setmetatable({},Actions)
    self:Init(loop)
    return self
end
function Actions:Init(loop)
    self.loop=loop
    self._fishingTokens=setmetatable({}, {__mode='k'})
end
function Actions:BindRuntime(runtime) self.runtime=runtime end
function Actions:IsBusy() return self.selection~=nil or self._pendingFishing~=nil end
function Actions:HasPendingCatch() return self._pendingCatch~=nil end
function Actions:IsClaimBlocked()
    local pending=self._pendingCatch
    return pending~=nil and (pending.claiming or pending.rollbackItems~=nil)
end
function Actions:SetDropTarget(v) self.dropTarget=v and copyPoint(v) or nil end
function Actions:GetDropTarget() return self.dropTarget and copyPoint(self.dropTarget) or nil end
-- Failed cleanup stays owned until Runtime acknowledges it; never silently discard a lock.
function Actions:FinishAbort(record)
    local rollback=record.rollback
    if rollback then
        if self.loop.generation==record.generation then
            local ok, restored=pcall(self.loop.RestoreActionResources,self.loop,rollback.items,rollback.stamina)
            if not ok or restored==false then return false,'fishing_rollback_pending' end
        end
        local generationOk,generation=call(record.runtime,'GetFishingGeneration')
        if not generationOk then return false,'fishing_rollback_pending' end
        -- Never restore an old entity into a reset world, even if its ID was reused.
        if generation==record.seaGeneration then
            local seaOk, seaRestored=call(record.runtime,'RestoreFishingTarget',rollback.target,rollback.snapshot)
            if not seaOk or seaRestored==false then return false,'fishing_rollback_pending' end
        end
        record.rollback=nil
    end
    if record.targetId then
        local ok, unlocked, reason=call(record.runtime,'UnlockFishingTarget',record.targetId,record.token)
        -- Another owner includes a reused ID: this old transaction owns no such lock.
        if not ok or (unlocked~=true and reason~='capture_owner_mismatch') then
            return false,'fishing_cleanup_pending'
        end
    end
    local interrupted = record.reason=='cancelled' or record.reason=='night_interrupted'
        or record.reason=='reset_interrupted' or record.reason=='scene_stopped'
    record.state=interrupted and 'cancelled' or 'failed'
    record.result=table.pack(false,record.reason or 'fishing_failed')
    if self._pendingFishing==record then self._pendingFishing=nil end
    self._lastFishing=record
    return true
end
function Actions:Abort(record,reason)
    record.reason=reason
    record.state=record.rollback and 'rollback_pending' or 'cleanup_pending'
    self.loop:SetMessage('捕鱼未完成，不扣体力：'..tostring(reason))
    return self:FinishAbort(record)
end
function Actions:CancelActiveFishing(reason)
    self.selection=nil
    local record=self._pendingFishing
    if not record then return true end
    if record.state=='committing' then return false,'fishing_committing' end
    return self:Abort(record,reason or 'cancelled')
end
function Actions:Reset(clearDropTarget)
    if self:HasPendingCatch() then return false,'pending_catch_required' end
    local ok,reason=self:CancelActiveFishing('reset_interrupted')
    if not ok then return false,reason end
    self._fishingTokens=setmetatable({}, {__mode='k'})
    self._lastFishing=nil
    if clearDropTarget then self.dropTarget=nil end
    return true
end
function Actions:ValidateGeneration()
    local record=self._pendingFishing
    if not record then return true end
    if record.state=='cleanup_pending' or record.state=='rollback_pending' then return self:FinishAbort(record) end
    local ok,generation=call(record.runtime,'GetFishingGeneration')
    if not ok or generation~=record.seaGeneration or self.loop.generation~=record.generation then
        return self:Abort(record,'stale_fishing_token')
    end
    return true
end
function Actions:BeginSelection()
    local ok,reason=self.loop:CanStartAction('fishing')
    if not ok then return false,reason end
    if not self.runtime then return false,'fishing_runtime_interface_unavailable' end
    self._lastFishing=nil
    self.selection={}
    call(self.runtime,'ClearMovementTarget')
    self.loop:SetMessage('点击海面选择网心，再确认抛网。')
    return true
end
function Actions:SetFishingCenter(center)
    if not self.selection then return false,'fishing_selection_required' end
    self.selection.center=nil
    if not point(center) then return false,'invalid_cast_position' end
    local ok,valid=call(self.runtime,'canCastNet',center)
    if not ok or valid~=true then return false,'cast_out_of_range_or_invalid' end
    self.selection.center=copyPoint(center)
    self.loop:SetMessage('网心已选定，请确认抛网。')
    return true
end
function Actions:ConfirmFishing()
    local selection=self.selection
    if not selection or not selection.center then return false,'fishing_center_required' end
    self.selection=nil
    local token,reason=self:BeginFishing(selection.center,self.runtime)
    if not token then self.loop:SetMessage(tostring(reason));return false,reason end
    return true
end
---@return GameplayFishingToken?,string?
function Actions:BeginFishing(center,runtime)
    self:ValidateGeneration()
    if self:IsBusy() then return nil,'fishing_already_pending' end
    if self:HasPendingCatch() then return nil,'pending_catch_required' end
    local ok,reason=self.loop:CanStartAction('fishing')
    if not ok then return nil,reason end
    if not point(center) then return nil,'invalid_cast_position' end
    for _,name in ipairs({'canCastNet','GetFishingGeneration','selectFishingTarget','LockFishingTarget',
        'UnlockFishingTarget','GetFishingTarget','SnapshotFishingTarget','RestoreFishingTarget',
        'RemoveFishingTarget','ForgetFishingBehavior','ClearMovementTarget'}) do
        if type(runtime)~='table' or type(runtime[name])~='function' then return nil,'fishing_runtime_interface_unavailable' end
    end
    local validCall,valid=call(runtime,'canCastNet',center)
    if not validCall or valid~=true then return nil,'cast_out_of_range_or_invalid' end
    local generationCall,generation=call(runtime,'GetFishingGeneration')
    if not generationCall then return nil,'fishing_generation_failed' end
    if not call(runtime,'ClearMovementTarget') then return nil,'fishing_movement_clear_failed' end
    ---@type GameplayFishingToken
    local token={}
    ---@type GameplayFishingRecord
    local record={token=token,runtime=runtime,center=copyPoint(center),generation=self.loop.generation,
        seaGeneration=generation,state='casting',elapsed=0}
    self._pendingFishing,self._lastFishing=record,record
    self._fishingTokens[token]=record
    self.loop:SetMessage('抛网中，可取消；捕鱼期间船只停止移动。')
    return token
end
function Actions:SecondsToBoundary()
    local record=self._pendingFishing
    if not record then return math.huge end
    if record.state=='casting' then return math.max(0,Config.fishing.landingSec-record.elapsed) end
    if record.state=='landed' then return math.max(0,Config.fishing.durationSec-record.elapsed) end
    return math.huge
end
function Actions:AdvanceFishing(seconds)
    local record=self._pendingFishing
    if record and (record.state=='casting' or record.state=='landed') then
        record.elapsed=math.min(Config.fishing.durationSec,record.elapsed+seconds)
    end
end
-- Resolve after the matching sea slice; selection and lock are one synchronous boundary.
function Actions:ResolveBoundary()
    self:ValidateGeneration()
    local record=self._pendingFishing
    if not record then return end
    if record.state=='casting' and record.elapsed+1e-9>=Config.fishing.landingSec then
        local ok,target,reason=call(record.runtime,'selectFishingTarget',record.center)
        if not ok or (not target and reason) then self:Abort(record,ok and reason or 'fishing_selection_failed');return end
        if target then
            local definition=Items.GetDefinition(target.species)
            if not definition or definition.category~='fish' then self:Abort(record,'unsupported_fish_item');return end
            record.targetId,record.itemId=target.id,definition.id
            -- Save the selected ID before Lock, including mutation-then-throw cleanup.
            local lockOk,locked,lockReason=call(record.runtime,'LockFishingTarget',target.id,record.token)
            if not lockOk or locked~=true then
                self:Abort(record,lockOk and (lockReason or 'fishing_lock_failed') or 'fishing_lock_failed');return
            end
        end
        record.state='landed'
    end
    if record.state=='landed' and record.elapsed+1e-9>=Config.fishing.durationSec then
        self:CompleteFishing(record.runtime,record.token)
    end
end
---@return boolean,string,string?
function Actions:CompleteFishing(runtime,token,...)
    if select('#',...)~=0 then return false,'unexpected_argument' end
    local record=self._fishingTokens[token]
    if not record or runtime~=record.runtime then return false,'stale_fishing_token' end
    self:ValidateGeneration()
    if record.result then return record.result[1],record.result[2],record.result[3] end
    if self._pendingFishing~=record then return false,'stale_fishing_token' end
    if record.state~='landed' or record.elapsed+1e-9<Config.fishing.durationSec then return false,'fishing_not_finished' end
    if self.loop.clock.exhausted then self:Abort(record,'night_interrupted');return false,'night_interrupted' end
    if self.loop.clock:IsPaused() then return false,'action_blocked' end
    if not record.targetId then
        record.state,record.result='complete',table.pack(true,'empty')
        self._pendingFishing=nil
        self.loop:SetMessage('空网，本次不扣体力。')
        return true,'empty'
    end
    local targetCall,target=call(runtime,'GetFishingTarget',record.targetId)
    if not targetCall or not target or target.removed or target.species~=record.itemId then
        self:Abort(record,'fishing_target_expired');return false,'fishing_target_expired'
    end
    local snapshotOk,snapshot=call(runtime,'SnapshotFishingTarget',target)
    if not snapshotOk or type(snapshot)~='table' then self:Abort(record,'fishing_snapshot_failed');return false,'fishing_snapshot_failed' end
    local inventory=self.loop.player.inventory
    local prepared,previousItems,hasSpace=pcall(function()
        return inventory:GetItems(),inventory:HasSpace(1)
    end)
    if not prepared or type(previousItems)~='table' or type(hasSpace)~='boolean' then
        self:Abort(record,'fishing_inventory_snapshot_failed')
        return false,'fishing_inventory_snapshot_failed'
    end
    local oldStamina=self.loop.player.stamina
    record.state='committing'
    ---@return boolean,string?
    local function commit()
        local charged,chargeError=self.loop.player:ConsumeStamina(Config.stamina.fishingCost)
        if charged~=true then return false,chargeError or 'fishing_charge_rejected' end
        if hasSpace then
            local added,addError=inventory:Add(record.itemId)
            if added~=true then return false,addError or 'inventory_add_failed' end
        end
        local removed,removeError=runtime:RemoveFishingTarget(record.targetId,record.token)
        if removed~=true then return false,removeError or 'world_remove_failed' end
        runtime:ForgetFishingBehavior(record.targetId)
        return true,nil
    end
    local commitCall,committed,reason=pcall(commit)
    if not commitCall or committed~=true then
        record.rollback={items=previousItems,stamina=oldStamina,target=target,snapshot=snapshot}
        self:Abort(record,commitCall and (reason or 'fishing_commit_failed') or 'fishing_commit_failed')
        return false,record.reason
    end
    record.state='complete'
    self._pendingFishing=nil
    record.result=table.pack(true,hasSpace and 'caught' or 'pending_catch',record.itemId)
    if not hasSpace then
        self._pendingCatch={itemIds={record.itemId},token=record.token,claiming=false}
        -- Receipt is authoritative before observer/UI callbacks run or throw.
        pcall(self.loop.SetInventoryOpen,self.loop,true)
        pcall(self.loop.SetMessage,self.loop,'船舱空间不足，收获已保留；请腾格后领取，不能关闭船舱。')
    else self.loop:SetMessage('成功捕获，扣除40体力。') end
    return record.result[1],record.result[2],record.result[3]
end
function Actions:CancelFishing(token)
    local record=self._fishingTokens[token]
    if not record then return false,'stale_fishing_token' end
    if record.state=='cancelled' then return true end
    if record~=self._pendingFishing then return false,'stale_fishing_token' end
    if record.state=='committing' then return false,'fishing_committing' end
    return self:Abort(record,'cancelled')
end
function Actions:GetFishingState()
    if self.selection then return {state='selecting',center=self.selection.center and copyPoint(self.selection.center) or nil,
        elapsed=0,duration=Config.fishing.durationSec} end
    local record=self._pendingFishing or self._lastFishing
    if not record then return {state='idle',elapsed=0,duration=Config.fishing.durationSec} end
    return {state=record.state,center=copyPoint(record.center),elapsed=record.elapsed,duration=Config.fishing.durationSec,
        reason=record.reason,outcome=record.result and record.result[2] or nil}
end
function Actions:GetPendingCatch()
    local pending=self._pendingCatch
    if not pending then return nil end
    local items={}
    for i,id in ipairs(pending.itemIds) do items[i]=id end
    return {itemIds=items,requiredSlots=#items}
end
function Actions:ClaimPendingCatch()
    local pending=self._pendingCatch
    if not pending then return false,'no_pending_catch' end
    if pending.claiming or self.loop.busy or self.loop.loading or self.loop.dropInFlight
        or self.loop.inventoryRollback then return false,'busy' end
    local inventory=self.loop.player.inventory
    -- A failed restore remains a barrier; retry it before any further grant or cargo edit.
    if pending.rollbackItems then
        local restoredCall,restored=pcall(inventory.RestoreItems,inventory,pending.rollbackItems)
        if not restoredCall or restored~=true then return false,'fishing_rollback_pending' end
        pending.rollbackItems=nil
    end
    local prepared,hasSpace,previous=pcall(function()
        return inventory:HasSpace(#pending.itemIds),inventory:GetItems()
    end)
    if not prepared or type(previous)~='table' then return false,'fishing_inventory_snapshot_failed' end
    if hasSpace~=true then return false,'inventory_full' end
    pending.claiming=true
    ---@return boolean,string?
    local function grant()
        for _,id in ipairs(pending.itemIds) do
            local added,addError=inventory:Add(id)
            if added~=true then return false,addError or 'inventory_add_failed' end
        end
        return true,nil
    end
    local ok,accepted,reason=pcall(grant)
    if not ok or accepted~=true then
        pending.rollbackItems=previous
        local restoredCall,restored=pcall(inventory.RestoreItems,inventory,previous)
        pending.claiming=false
        if not restoredCall or restored~=true then return false,'fishing_rollback_pending' end
        pending.rollbackItems=nil
        return false,ok and reason or 'inventory_add_failed'
    end
    self._pendingCatch=nil
    pending.claiming=false
    pcall(self.loop.SetMessage,self.loop,'已领取保留的收获，不再扣体力。')
    return true
end
return Actions
