import random

def main():
    random.seed(42)
    success_count = 0
    none_count = 0

    # Option operations benchmark (simulated with None)
    for _ in range(50000):
        val = random.randint(0, 100)

        # Create option based on value
        opt = val if val > 50 else None

        # Pattern match and process
        if opt is not None:
            success_count = success_count + opt
        else:
            none_count = none_count + 1

    print(success_count)
    print(none_count)

main()
