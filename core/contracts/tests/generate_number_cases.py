"""Generate deterministic decimal-policy cases using Python's independent Decimal."""
import json
import math
import random
from decimal import Decimal
from pathlib import Path

randomizer = random.Random(8785)
limit = Decimal(9007199254740991)
cases = []
for _ in range(300):
    coefficient = randomizer.randrange(-1000000000000000000, 1000000000000000001)
    exponent = randomizer.randrange(-20, 10)
    token = f"{coefficient}e{exponent}"
    exact = Decimal(token)
    binary = float(token)
    accepted = math.isfinite(binary) and (binary != 0 or exact == 0) and (exact != exact.to_integral_value() or abs(exact) <= limit)
    cases.append({"token": token, "accepted": accepted})
output = Path(__file__).resolve().parents[2] / "Tests/OchesCoreTests/Fixtures/envelopes/numeric-cases.json"
output.write_text(json.dumps(cases, indent=2) + "\n")
