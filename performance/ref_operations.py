import random

class Counter:
    def __init__(self, value):
        self.value = value

def increment(counter):
    counter.value = counter.value + 1

def main():
    random.seed(42)
    total = 0

    # Reference operations benchmark
    for _ in range(10000):
        counter = Counter(0)

        # Multiple increments
        for _ in range(10):
            increment(counter)

        total = total + counter.value

    print(total)

main()
