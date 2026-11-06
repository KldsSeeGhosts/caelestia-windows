"""Public arithmetic fixture for runner controls, never a shell benchmark."""
import argparse
import json
import time

parser = argparse.ArgumentParser(__doc__)
parser.add_argument("--added-percent", type=int, default=0, choices=(0, 100))
args = parser.parse_args()
nominal = 150000
actual = nominal * (100 + args.added_percent) // 100
checksum = 0
start = time.perf_counter_ns()
for index in range(actual):
    checksum = (checksum * 33 + index) & 0xFFFFFFFF
elapsed = time.perf_counter_ns() - start
print(json.dumps({"elapsedNs": elapsed, "operations": nominal, "actualOperations": actual,
                  "checksum": checksum, "addedPercent": args.added_percent}))
