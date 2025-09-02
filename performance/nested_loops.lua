local sum_val = 0

for i = 0, 999 do
  for j = 0, 499 do
    sum_val = sum_val + i * j
    if sum_val > 1000000 then
      sum_val = sum_val % 1000000
    end
  end
end

print(sum_val)
