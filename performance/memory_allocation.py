import random

def create_array(size):
    arr = [0] * size
    for i in range(size):
        arr[i] = i
    return arr

def main():
    random.seed(42)
    total_length = 0

    # Memory allocation and array creation benchmark
    for i in range(1000):
        size = random.randint(10, 50)
        arr = create_array(size)

        bounded_len = total_length
        bounded_arr_len = len(arr)
        total_length = (bounded_len + bounded_arr_len)

        # Create some temporary arrays
        temp1 = [1, 2, 3, 4, 5]
        temp2 = temp1 + arr[0:5]
        bounded_len2 = total_length
        bounded_temp_len = len(temp2)
        total_length = (bounded_len2 + bounded_temp_len)

    print(total_length)

main()