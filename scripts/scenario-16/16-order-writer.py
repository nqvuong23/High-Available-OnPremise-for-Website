#!/usr/bin/env python3
"""Scenario 16: write orders through the VIP, logging an order only after its commit returns.

Usage: python3 16-order-writer.py [--interval SECONDS] [--csv PATH]
Ctrl-C prints the summary. The longest outage the writer saw is the RTO as the application
experiences it; the CSV of confirmed orders is the input of 16-rpo-check.py.
"""
import argparse
import configparser
import csv
import os
import signal
import ssl
import time
import uuid
from datetime import datetime
from pathlib import Path

import pymysql

HERE = Path(__file__).resolve().parent
LOG_DIR = HERE / "logs"
LATEST = LOG_DIR / "16-confirmed-latest.txt"

DDL = """CREATE TABLE IF NOT EXISTS lab_orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_ref CHAR(36) NOT NULL UNIQUE,
    created_at DATETIME(3) NOT NULL,
    writer VARCHAR(64) NOT NULL
)"""


def load_env(path):
    env = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key] = value.strip().strip('"')
    return env


def client_config(path, host=None):
    parser = configparser.ConfigParser()
    parser.read(path)
    section = parser["client"]
    return {
        "host": host or section.get("host"),
        "port": int(section.get("port", "3306")),
        "user": section["user"],
        "password": section["password"],
    }


def connect(cfg, database):
    # caching_sha2_password needs TLS over TCP; the server's own certificate is self-signed
    tls = ssl.create_default_context()
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE
    return pymysql.connect(
        database=database, ssl=tls, autocommit=False,
        connect_timeout=2, read_timeout=5, write_timeout=5, **cfg,
    )


def hms(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]


def short_error(exc):
    if isinstance(exc, pymysql.MySQLError) and exc.args:
        return f"{exc.args[0]} {str(exc.args[-1])[:50]}"
    return type(exc).__name__


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--interval", type=float, default=0.1, help="seconds between orders")
    parser.add_argument("--csv", type=Path, help="where confirmed orders are written")
    args = parser.parse_args()

    env = load_env(os.environ.get("LAB_ENV_FILE", "/etc/lab/lab.env"))
    cfg = client_config(env["LAB_MYSQL_WP_CNF"])
    database = env.get("LAB_WP_DB", "wordpress")
    writer = f"order-writer-{os.getpid()}"

    LOG_DIR.mkdir(exist_ok=True)
    csv_path = args.csv or LOG_DIR / f"16-confirmed-{datetime.now():%Y%m%d-%H%M%S}.csv"
    LATEST.write_text(f"{csv_path}\n")

    stop = False

    def on_signal(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    conn = connect(cfg, database)
    with conn.cursor() as cur:
        cur.execute(DDL)
    conn.commit()

    ok = failed = unknown = 0
    server = "?"
    last_ms = 0
    outage_start = None
    outage_attempts = 0
    outages = []
    last_error = ""
    next_status = time.time()
    print(f"[INFO] writing orders through {cfg['host']}:{cfg['port']} every {args.interval}s, "
          f"confirmed orders in {csv_path}")

    with open(csv_path, "a", newline="", encoding="utf-8") as handle:
        out = csv.writer(handle)
        if handle.tell() == 0:
            out.writerow(["order_ref", "confirmed_at", "epoch_ms", "server"])
        while not stop:
            started = time.time()
            ref = str(uuid.uuid4())
            committing = False
            try:
                if conn is None:
                    conn = connect(cfg, database)
                    with conn.cursor() as cur:
                        cur.execute("SELECT @@hostname")
                        server = cur.fetchone()[0]
                elif server == "?":
                    with conn.cursor() as cur:
                        cur.execute("SELECT @@hostname")
                        server = cur.fetchone()[0]
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO lab_orders (order_ref, created_at, writer) VALUES (%s, NOW(3), %s)",
                        (ref, writer),
                    )
                committing = True
                conn.commit()
            except (pymysql.MySQLError, OSError) as exc:
                # a commit that failed in flight may or may not have landed: never count it confirmed
                if committing:
                    unknown += 1
                failed += 1
                last_error = short_error(exc)
                if outage_start is None:
                    outage_start = started
                    outage_attempts = 0
                    print(f"[EVENT] {hms(started)} write failed on {server}: {last_error}")
                outage_attempts += 1
                try:
                    if conn is not None:
                        conn.close()
                except pymysql.MySQLError:
                    pass
                conn = None
                server = "?"
            else:
                done = time.time()
                last_ms = int((done - started) * 1000)
                out.writerow([ref, hms(done), int(done * 1000), server])
                handle.flush()
                os.fsync(handle.fileno())
                ok += 1
                if outage_start is not None:
                    duration = done - outage_start
                    outages.append((outage_start, done, duration, outage_attempts))
                    print(f"[EVENT] {hms(done)} write path restored after {duration:.2f}s "
                          f"({outage_attempts} failed attempts), now on {server}")
                    outage_start = None

            now = time.time()
            if now >= next_status:
                if outage_start is None:
                    print(f"{hms(now)} [OK]   ok={ok} fail={failed} unknown={unknown} "
                          f"server={server} last={last_ms}ms")
                else:
                    print(f"{hms(now)} [FAIL] ok={ok} fail={failed} unknown={unknown} "
                          f"outage={now - outage_start:.1f}s error={last_error}")
                next_status = now + 1
            time.sleep(max(0.0, args.interval - (time.time() - started)))

    if outage_start is not None:
        outages.append((outage_start, time.time(), time.time() - outage_start, outage_attempts))
    longest = max((o[2] for o in outages), default=0.0)
    print(f"\nrto_ms={int(longest * 1000)} confirmed={ok} failed={failed} unknown={unknown} "
          f"outages={len(outages)} csv={csv_path}")
    for start, end, duration, attempts in outages:
        print(f"  outage {hms(start)} -> {hms(end)}  {duration:.2f}s  {attempts} failed attempts")
    print("[INFO] next: python3 16-rpo-check.py")


if __name__ == "__main__":
    main()
