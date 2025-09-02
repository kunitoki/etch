local function fibonacci(n)
  if n <= 1 then
    return n
  end
  if n > 46 then
    return 0
  end
  local fib1 = fibonacci(n - 1)
  local fib2 = fibonacci(n - 2)
  return (fib1 % 1000000) + (fib2 % 1000000)
end

local function simple_math(a, b)
  return a * b + a - b
end

local function array_sum(arr)
  local sum_val = 0
  for _, value in ipairs(arr) do
    sum_val = sum_val + value
  end
  return sum_val
end

math.randomseed(42)
local res = 0

for i = 0, 9999 do
  local a = math.random(1, 100)
  local b = math.random(1, 100)

  res = res + simple_math(a, b)

  local arr = {a, b, a + b, a - b, a * 2}
  res = res + (array_sum(arr) % 10)

  if i % 1000 == 0 then
    res = res + fibonacci(a % 10)
  end
end

print(res)
