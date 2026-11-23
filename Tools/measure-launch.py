"""Measure process start to the first displayed, saveable tile in a KAKA_BENCHMARK build."""
import argparse
import math
import re
import selectors
import signal
import statistics
import subprocess
import time
import uuid
from pathlib import Path


def record(line, stages):
    if match := re.fullmatch(r"KAKA_STAGE (.+) ([\d.]+)", line):
        name, elapsed = match.groups()
        stages[name] = stages.get(name, 0) + float(elapsed)
    if match := re.fullmatch(r"KAKA_FIRST_TILE_MS ([\d.]+)", line):
        return float(match[1])
    if "locked" in line.lower() and "unlocked" not in line.lower():
        raise RuntimeError("Unlock the test iPhone before launching the benchmark.")
    return None


def device_trial(command):
    stages = {}
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 20
            pending = b""
            while (remaining := deadline - time.monotonic()) > 0 and selector.select(remaining):
                chunk = process.stdout.read(4096)
                if not chunk:
                    break
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    line = line.decode(errors="replace").strip()
                    if (elapsed := record(line, stages)) is not None:
                        return elapsed, stages
            raise RuntimeError("No result tile appeared within 20 seconds. Check the test build, Photos access and sample.")
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()


def simulator_trial(command, directory):
    identifier = str(uuid.uuid4()).upper()
    path = directory / (identifier + ".log")
    try:
        subprocess.run([*command, "-measure-sim-log", identifier], check=True, stdout=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if path.exists():
                stages = {}
                for line in path.read_text().splitlines():
                    if (elapsed := record(line, stages)) is not None:
                        return elapsed, stages
            time.sleep(0.04)
        raise RuntimeError("No result tile appeared within 20 seconds. Check the test build, Photos access and sample.")
    finally:
        path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["sim", "device"])
    parser.add_argument("udid")
    parser.add_argument("--bundle", default="com.example.kaka", help="Bundle identifier of the installed test build.")
    parser.add_argument("--fixture", action="store_true", help="Use four bundled images in place of Photos.")
    parser.add_argument("--runs", type=int, default=20)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.platform == "sim":
        container = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.udid, args.bundle, "data"], text=True)
        directory = Path(container.strip()) / "tmp"
        command = ["xcrun", "simctl", "launch", "--terminate-running-process", args.udid, args.bundle]
    else:
        command = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.udid,
                   "--terminate-existing", "--console", args.bundle, "--"]
    command.append("-measure-launch")
    if args.fixture:
        command.append("-demo-mixed")
    times, stages = [], {}
    for index in range(args.runs):
        elapsed, totals = simulator_trial(command, directory) if args.platform == "sim" else device_trial(command)
        times.append(elapsed)
        if "Process to app init" in totals:
            totals["App init to displayed tile"] = elapsed - totals["Process to app init"]
        for name, value in totals.items():
            stages.setdefault(name, []).append(value)
        print(f"{index + 1:2}/{args.runs}  {elapsed:.1f} ms", flush=True)
    p95 = sorted(times)[math.ceil(0.95 * len(times)) - 1]
    print(f"First visible and saveable  median {statistics.median(times):.1f} ms  P95 {p95:.1f} ms")
    for name, values in stages.items():
        print(f"{name}  median {statistics.median(values):.2f} ms")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error))
