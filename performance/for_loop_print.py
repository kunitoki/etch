import random

def main():
    random.seed(42)
    x = random.randint(1, 1000000) % 10000
    for i in range(100000):
        print(x + i)

main()
