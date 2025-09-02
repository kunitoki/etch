import random

def main():
    random.seed(42)
    arr = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    sum_val = 0

    # Array access and modification benchmark
    for i in range(50000):
        idx = random.randint(0, 9)
        arr_val = arr[idx];
        sum_val = sum_val + arr_val;
        bounded_sum = sum_val % 100000;
        bounded_arr = arr_val % 100000;
        new_val = (bounded_sum + bounded_arr) % 100000;
        arr[idx] = new_val;

        # Test array length operations
        if i % 1000 == 0:
            bounded = sum_val % 100000
            sum_val = (bounded + 10) % 100000

    # Print final sum and array state
    print(sum_val)
    for i in range(len(arr)):
        print(arr[i])

main()