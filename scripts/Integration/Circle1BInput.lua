-- Pending-catch cabin pauses simulation. Reuse the existing public viewport
-- conversion to select a drop point without unpausing or moving the ship.
local Input = {}

function Input.HandlePendingPointer(bridge, ocean, event, ui)
    -- Unpaused sea clicks are handled only by Ocean's callback; processing them
    -- here as well could turn the completed throw into a navigation click.
    if not bridge.loop.clock:IsPaused() then return false end
    if not bridge.loop:GetThrowSelection()
        and (not bridge.loop:HasPendingCatch() or not bridge.loop.inventoryOpen) then return false end
    if type(event.IsPrimaryButton) == "function" and not event:IsPrimaryButton() then return false end
    if not ocean:SyncViewport() then return false end
    local scale = ui.GetScale()
    local x, y = event.x * scale, event.y * scale
    if x < 0 or x > ocean.physicalWidth or y < 0 or y > ocean.physicalHeight then return false end
    if y / ocean.physicalHeight < ocean.pointerMinY then return false end
    if ui.FindWidgetAt(event.x, event.y) then return false end
    local position = bridge.runtime.movement:ScreenToWorld(x / ocean.dpr, y / ocean.dpr)
    -- The shared inverse rejects sky, the horizon and clipped water. Never
    -- consume the paused throw selection or clear navigation for such a click.
    if type(position) ~= "table" then return false end
    if bridge.loop:GetThrowSelection() then
        local ok, reason = bridge:HandleThrowPointer(position)
        bridge.runtime:ClearMovementTarget()
        bridge:Sync()
        if not ok then bridge.loop:SetMessage(tostring(reason)) end
        return ok, reason
    end
    local ok, reason = bridge:SetDropTarget(position)
    bridge.runtime:ClearMovementTarget()
    bridge:Sync()
    bridge.loop:SetMessage(ok and "投放点已选定，可在船舱中丢弃普通物品腾格。" or tostring(reason))
    return ok, reason
end

return Input
