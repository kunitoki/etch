import random

def main():
    result = ""
    count = 0

    # String operations benchmark
    for i in range(5000):
        num = 0
        str_num = str(num)

        # String concatenation
        result = result + str_num + ","

        # String length operations
        count = count + len(result)

    print(count)
    print(result)
    print(len(result))

main()