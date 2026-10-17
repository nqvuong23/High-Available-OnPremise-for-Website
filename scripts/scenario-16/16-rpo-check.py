#!/usr/bin/env python3
"""Scenario 16: reconcile the confirmed orders against what a database holds now.

Usage: python3 16-rpo-check.py [--csv PATH] [--node HOST]
Without --node it asks through the VIP, so it checks whichever node serves writes now.
Every confirmed order missing from that node is a lost order: that count is the RPO.
"""
import argparse
import csv
import importlib.util
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# reuse the connection helpers of the writer instead of keeping a second copy
_spec = importlib.util.spec_from_file_location("order_writer", HERE / "16-order-writer.py")
writer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(writer)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--csv", type=Path, help="confirmed orders, default: the latest run")
    parser.add_argument("--node", help="ask one db node directly as the operator, e.g. db02")
    args = parser.parse_args()

    env = writer.load_env(os.environ.get("LAB_ENV_FILE", "/etc/lab/lab.env"))
    database = env.get("LAB_WP_DB", "wordpress")
    if args.node:
        ip = env.get(f"LAB_IP_{args.node}")
        if not ip:
            sys.exit(f"[ERROR] unknown node {args.node}")
        cfg = writer.client_config(env["LAB_MYSQL_OPS_CNF"], host=ip)
    else:
        cfg = writer.client_config(env["LAB_MYSQL_WP_CNF"])

    csv_path = args.csv or Path(writer.LATEST.read_text().strip())
    with open(csv_path, newline="", encoding="utf-8") as handle:
        confirmed = [row["order_ref"] for row in csv.DictReader(handle)]
    if not confirmed:
        sys.exit(f"[ERROR] no confirmed orders in {csv_path}")

    conn = writer.connect(cfg, database)
    present = set()
    with conn.cursor() as cur:
        cur.execute("SELECT @@hostname")
        source = cur.fetchone()[0]
        for i in range(0, len(confirmed), 500):
            chunk = confirmed[i:i + 500]
            marks = ",".join(["%s"] * len(chunk))
            cur.execute(f"SELECT order_ref FROM lab_orders WHERE order_ref IN ({marks})", chunk)
            present.update(row[0] for row in cur.fetchall())
    conn.close()

    missing = [ref for ref in confirmed if ref not in present]
    print(f"rpo_missing={len(missing)} confirmed={len(confirmed)} present={len(present)} "
          f"source={source} csv={csv_path}")
    if missing:
        print(f"[ERROR] {len(missing)} confirmed orders are not on {source}; first ones:")
        for ref in missing[:10]:
            print(f"  {ref}")
        sys.exit(1)
    print(f"[OK] every confirmed order is on {source}: RPO = 0")


if __name__ == "__main__":
    main()
