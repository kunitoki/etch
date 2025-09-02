math.randomseed(42)
local arr = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
local sum_val = 0

for i = 0, 49999 do
  local idx = math.random(1, #arr)
  local arr_val = arr[idx]
  sum_val = sum_val + arr_val

  local bounded_sum = sum_val % 100000
  local bounded_arr = arr_val % 100000
  local new_val = (bounded_sum + bounded_arr) % 100000
  arr[idx] = new_val

  if i % 1000 == 0 then
    local bounded = sum_val % 100000
    sum_val = (bounded + 10) % 100000
  end
end

print(sum_val)
for i = 1, #arr do
  print(arr[i])
end
