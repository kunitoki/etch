def main():
    sum_val = 0

    # Nested loops to test loop overhead and variable access
    for i in range(1000):
        for j in range(500):
            sum_val = sum_val + i * j
            if sum_val > 1000000:
                sum_val = sum_val % 1000000

    print(sum_val)

main()