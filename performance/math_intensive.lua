local function is_prime(n)
  if n <= 1 then
    return 0
  end
  if n <= 3 then
    return 1
  end
  if n % 2 == 0 or n % 3 == 0 then
    return 0
  end

  local i = 5
  while i * i <= n do
    if n % i == 0 or n % (i + 2) == 0 then
      return 0
    end
    i = i + 6
  end
  return 1
end

local function gcd(a, b)
  while b ~= 0 do
    local temp = b
    b = a % b
    a = temp
  end
  return a
end

math.randomseed(42)
local prime_count = 0
local gcd_sum = 0

for i = 1, 4999 do
  if is_prime(i) == 1 then
    prime_count = prime_count + 1
  end

  local a = math.random(1, 1000)
  local b = math.random(1, 1000)
  gcd_sum = gcd_sum + gcd(a, b)

  local mod_result = (i * i + a * b) % 1000
  gcd_sum = gcd_sum + mod_result
end

print(prime_count)
print(gcd_sum)
