-- 小型 FSM：命名状态及可选 enter/update/exit 回调。
local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.New(states, initialState, owner)
    assert(type(states) == "table", "FSM states must be a table")
    assert(states[initialState] ~= nil, "FSM initial state is not defined")

    local self = setmetatable({
        states = states,
        current = initialState,
        owner = owner,
    }, StateMachine)

    local state = self.states[self.current]
    if state.enter then state.enter(self.owner) end
    return self
end

function StateMachine:Change(nextState)
    assert(self.states[nextState] ~= nil, "FSM state is not defined: " .. tostring(nextState))
    if nextState == self.current then return false end

    local current = self.states[self.current]
    if current.exit then current.exit(self.owner) end

    local previousState = self.current
    self.current = nextState

    local nextDefinition = self.states[self.current]
    if nextDefinition.enter then nextDefinition.enter(self.owner, previousState) end
    return true
end

function StateMachine:Update(dt)
    local state = self.states[self.current]
    if state.update then state.update(self.owner, dt) end
end

return StateMachine
