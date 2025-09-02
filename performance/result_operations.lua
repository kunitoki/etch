local function divide(a, b)
  if b == 0 then
    return {"error", "Division by zero"}
  end
  return {"ok", math.floor(a / b)}
end

math.randomseed(42)
local success_sum = 0
local error_count = 0

for i = 1, 50000 do
  local a = math.random(1, 100)
  local b = math.random(0, 10)
  local result = divide(a, b)

  if result[1] == "ok" then
    success_sum = success_sum + result[2]
  else
    error_count = error_count + 1
  end
end

print(success_sum)
print(error_count)
