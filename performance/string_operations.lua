math.randomseed(42)
local res = ""
local count = 0

for i = 0, 4999 do
  local num = math.random(0, 9)
  local str_num = tostring(num)

  res = res .. str_num .. ","
  count = count + #res
end

print(count)
print(res)
print(#res)
