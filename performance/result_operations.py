import random

def divide(a, b):
    if b == 0:
        return ("error", "Division by zero")
    return ("ok", a // b)

def main():
    random.seed(42)
    success_sum = 0
    error_count = 0

    # Result operations benchmark
    for _ in range(50000):
        a = random.randint(1, 100)
        b = random.randint(0, 10)

        result = divide(a, b)

        if result[0] == "ok":
            success_sum = success_sum + result[1]
        else:
            error_count = error_count + 1

    print(success_sum)
    print(error_count)

main()
