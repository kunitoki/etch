-- Define a Counter type (object-like)
local Counter = {}
Counter.__index = Counter

function Counter.new(value)
    return setmetatable({value = value}, Counter)
end

-- Increment function (modifies counter by reference)
local function increment(counter)
    counter.value = counter.value + 1
end

local total = 0

-- Benchmark loop
for i = 1, 10000 do
    -- Create a new counter object (like `new[Counter]`)
    local counter = Counter.new(0)

    -- Perform multiple increments
    for j = 1, 10 do
        increment(counter)
    end

    total = total + counter.value
end

print(total)