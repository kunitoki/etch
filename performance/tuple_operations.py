#!/usr/bin/env python3
"""
Performance test for tuple operations in Python
Tests: creation, access, slicing, and concatenation
"""

def main():
    iterations = 10000

    # Test 1: Tuple creation
    sum1 = 0
    for i in range(iterations):
        t = (1, 2, 3, 4, 5)
        sum1 = sum1 + t[0]
    print(sum1)

    # Test 2: Tuple access
    base = (10, 20, 30, 40, 50, 60, 70, 80, 90, 100)
    sum2 = 0
    for i in range(iterations):
        a = base[0]
        b = base[3]
        c = base[7]
        d = base[9]
        sum2 = sum2 + a + b + c + d
    print(sum2)

    # Test 3: Tuple slicing
    source = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
    sum3 = 0
    for i in range(iterations):
        s1 = source[2:5]
        s2 = source[:3]
        s3 = source[7:]
        a = s1[0]
        b = s2[0]
        c = s3[0]
        sum3 = sum3 + a + b + c
    print(sum3)

    # Test 4: Tuple concatenation
    left = (1, 2, 3, 4, 5)
    right = (6, 7, 8, 9, 10)
    sum4 = 0
    for i in range(iterations):
        combined = left + right
        a = combined[0]
        b = combined[9]
        sum4 = sum4 + a + b
    print(sum4)

    # Test 5: Complex operations (mixed)
    t1 = (1, 2, 3)
    t2 = (4, 5, 6)
    sum5 = 0
    for i in range(iterations):
        joined = t1 + t2
        slice_result = joined[1:5]
        a = slice_result[0]
        b = slice_result[3]
        sum5 = sum5 + a + b
    print(sum5)

    # Final checksum to prevent optimization
    total = sum1 + sum2 + sum3 + sum4 + sum5
    print(f"Total checksum: {total}")


if __name__ == "__main__":
    main()
