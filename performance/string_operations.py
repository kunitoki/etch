import random

def main():
    res = ""
    count = 0

    # String operations benchmark
    for i in range(5000):
        num = random.randint(0, 9)
        str_num = str(num)

        # String concatenation
        res = res + str_num + ","

        # String length operations
        count = count + len(res)

    print(count)
    print(res)
    print(len(res))

main()