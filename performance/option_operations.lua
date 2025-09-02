math.randomseed(42)
local success_count = 0
local none_count = 0

for i = 1, 50000 do
  local val = math.random(0, 100)
  local opt = val > 50 and val or nil

  if opt then
    success_count = success_count + opt
  else
    none_count = none_count + 1
  end
end

print(success_count)
print(none_count)
