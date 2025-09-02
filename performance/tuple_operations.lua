local function slice(pyTbl, pyStart, pyStop)
  local result = {}
  local startIndex = (pyStart or 0) + 1
  if startIndex < 1 then
    startIndex = 1
  end
  local endIndex = pyStop and math.min(pyStop, #pyTbl) or #pyTbl

  for i = startIndex, endIndex do
    result[#result + 1] = pyTbl[i]
  end
  return result
end

local function concatTables(a, b)
  local result = {}
  for _, value in ipairs(a) do
    result[#result + 1] = value
  end
  for _, value in ipairs(b) do
    result[#result + 1] = value
  end
  return result
end

local iterations = 10000

-- Test 1: Tuple creation
local sum1 = 0
for _ = 1, iterations do
  local t = {1, 2, 3, 4, 5}
  sum1 = sum1 + t[1]
end
print(sum1)

-- Test 2: Tuple access
local base = {10, 20, 30, 40, 50, 60, 70, 80, 90, 100}
local sum2 = 0
for _ = 1, iterations do
  local a = base[1]
  local b = base[4]
  local c = base[8]
  local d = base[10]
  sum2 = sum2 + a + b + c + d
end
print(sum2)

-- Test 3: Tuple slicing
local source = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
local sum3 = 0
for _ = 1, iterations do
  local s1 = slice(source, 2, 5)
  local s2 = slice(source, 0, 3)
  local s3 = slice(source, 7, nil)
  local a = s1[1]
  local b = s2[1]
  local c = s3[1]
  sum3 = sum3 + a + b + c
end
print(sum3)

-- Test 4: Tuple concatenation
local left = {1, 2, 3, 4, 5}
local right = {6, 7, 8, 9, 10}
local sum4 = 0
for _ = 1, iterations do
  local combined = concatTables(left, right)
  local a = combined[1]
  local b = combined[10]
  sum4 = sum4 + a + b
end
print(sum4)

-- Test 5: Complex operations (mixed)
local t1 = {1, 2, 3}
local t2 = {4, 5, 6}
local sum5 = 0
for _ = 1, iterations do
  local joined = concatTables(t1, t2)
  local slice_result = slice(joined, 1, 5)
  local a = slice_result[1]
  local b = slice_result[4]
  sum5 = sum5 + a + b
end
print(sum5)

-- Final checksum
local total = sum1 + sum2 + sum3 + sum4 + sum5
print("Total checksum: " .. total)
