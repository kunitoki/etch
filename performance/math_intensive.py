import random
import math

def is_prime(n):
    if n <= 1:
        return 0
    if n <= 3:
        return 1
    if n % 2 == 0 or n % 3 == 0:
        return 0

    i = 5
    while i * i <= n:
        if n % i == 0 or n % (i + 2) == 0:
            return 0
        i = i + 6
    return 1

def gcd(a, b):
    while b != 0:
        temp = b
        b = a % b
        a = temp
    return a

def main():
    random.seed(42)
    prime_count = 0
    gcd_sum = 0

    # Mathematical computation benchmark
    for i in range(1, 5000):
        # Prime checking
        if is_prime(i) == 1:
            prime_count = prime_count + 1

        # GCD computation
        a = random.randint(1, 1000)
        b = random.randint(1, 1000)
        gcd_sum = gcd_sum + gcd(a, b)

        # Some modular arithmetic
        mod_result = (i * i + a * b) % 1000
        gcd_sum = gcd_sum + mod_result

    print(prime_count)
    print(gcd_sum)

main()