-- Retained project skeleton: named states with enter/update/exit callbacks.
local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.New(states, initialState, owner)
    local self = setmetatable({}, StateMachine)
    self:Init(states, initialState, owner)
    return self
end

function StateMachine:Init(states, initialState, owner)
    assert(type(states) == "table", "FSM states must be a table")
    assert(states[initialState] ~= nil, "FSM initial state is not defined")
    self.states, self.current, self.owner = states, initialState, owner
    local state = states[initialState]
    if state.enter then state.enter(owner) end
end

function StateMachine:Change(nextState)
    assert(self.states[nextState] ~= nil, "FSM state is not defined: " .. tostring(nextState))
    if nextState == self.current then return false end
    local current = self.states[self.current]
    if current.exit then current.exit(self.owner) end
    local previousState = self.current
    self.current = nextState
    local nextDefinition = self.states[nextState]
    if nextDefinition.enter then nextDefinition.enter(self.owner, previousState) end
    return true
end

function StateMachine:Update(dt)
    local state = self.states[self.current]
    if state.update then state.update(self.owner, dt) end
end

return StateMachine
