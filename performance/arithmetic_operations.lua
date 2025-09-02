math.randomseed(42)
local result = 0

for i = 0, 99999 do
  local a = math.random(1, 100)
  local b = math.random(1, 100)

  local sum = a + b
  local diff = a - b
  local prod = a * b
  local divisor = (b % 10) + 1
  local quotient = math.floor(a / divisor)

  result = result + sum
  result = result + diff
  result = result + prod
  result = result + quotient
end

print(result)
