#!/usr/bin/env python3
"""
FiatLux Backend Runner

Usage:
    python run.py                     # API only (no trigger)
    python run.py --trigger webhook   # API + /trigger endpoint
    python run.py --trigger polling   # API + background polling
    python run.py --trigger polling --interval 30  # Poll every 30s

Options:
    --trigger, -t    Trigger mode: none, webhook, polling (default: none)
    --interval, -i   Polling interval in seconds (default: 60)
    --port, -p       Port to run on (default: 8000)
    --reload, -r     Enable auto-reload for development
"""

import argparse
import asyncio
import os
import sys


def parse_args():
    parser = argparse.ArgumentParser(
        description="FiatLux Backend Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python run.py                          # Just the API
    python run.py -t webhook               # API + webhook trigger endpoint
    python run.py -t polling -i 30         # API + poll storage every 30s
    python run.py -t webhook -r            # Webhook mode with auto-reload
        """
    )

    parser.add_argument(
        "-t", "--trigger",
        choices=["none", "webhook", "polling"],
        default="none",
        help="Trigger mode (default: none)"
    )

    parser.add_argument(
        "-i", "--interval",
        type=int,
        default=60,
        help="Polling interval in seconds (default: 60)"
    )

    parser.add_argument(
        "-p", "--port",
        type=int,
        default=8000,
        help="Port to run on (default: 8000)"
    )

    parser.add_argument(
        "-r", "--reload",
        action="store_true",
        help="Enable auto-reload for development"
    )

    return parser.parse_args()


def main():
    args = parse_args()

    # Set environment variables for main.py to read
    os.environ["TRIGGER_MODE"] = args.trigger
    os.environ["POLLING_INTERVAL"] = str(args.interval)

    print(f"""
╔══════════════════════════════════════════╗
║         FiatLux Backend                  ║
╠══════════════════════════════════════════╣
║  Trigger Mode: {args.trigger:<25} ║
║  Port:         {args.port:<25} ║
║  Auto-reload:  {str(args.reload):<25} ║
╚══════════════════════════════════════════╝
    """)

    if args.trigger == "webhook":
        print("→ Webhook endpoint available at POST /trigger")
    elif args.trigger == "polling":
        print(f"→ Polling storage every {args.interval}s")
    else:
        print("→ No trigger active. Submit jobs via POST /jobs")

    print()

    # Run uvicorn
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=args.port,
        reload=args.reload,
    )


if __name__ == "__main__":
    main()
