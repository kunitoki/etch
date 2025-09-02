local function create_array(size)
  local arr = {}
  for i = 1, size do
    arr[i] = i - 1
  end
  return arr
end

math.randomseed(42)
local total_length = 0

for i = 0, 999 do
  local size = math.random(10, 50)
  local arr = create_array(size)

  local bounded_len = total_length
  local bounded_arr_len = #arr
  total_length = bounded_len + bounded_arr_len

  local temp1 = {1, 2, 3, 4, 5}
  local temp2 = {}
  for _, value in ipairs(temp1) do
    temp2[#temp2 + 1] = value
  end
  for j = 1, math.min(5, #arr) do
    temp2[#temp2 + 1] = arr[j]
  end

  local bounded_len2 = total_length
  local bounded_temp_len = #temp2
  total_length = bounded_len2 + bounded_temp_len
end

print(total_length)
