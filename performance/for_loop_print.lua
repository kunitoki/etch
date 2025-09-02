math.randomseed(42)
local x = math.random(1, 1000000) % 10000

for i = 0, 99999 do
  print(x + i)
end
