#!/usr/bin/env python3
"""Clean up files from the old /terrillo/ S3 prefix."""

import argparse
import boto3
from dotenv import load_dotenv
import os

def main():
    parser = argparse.ArgumentParser(description="Clean up old S3 prefix files")
    parser.add_argument("--delete", action="store_true", help="Actually delete files (default: dry-run)")
    parser.add_argument("--prefix", default="terrillo/", help="Prefix to clean up (default: terrillo/)")
    args = parser.parse_args()

    load_dotenv()

    region = os.getenv("DO_SPACES_REGION", "sfo3")
    # Use regional endpoint (not bucket-specific)
    endpoint_url = f"https://{region}.digitaloceanspaces.com"

    client = boto3.client(
        "s3",
        region_name=region,
        endpoint_url=endpoint_url,
        aws_access_key_id=os.getenv("DO_SPACES_KEY"),
        aws_secret_access_key=os.getenv("DO_SPACES_SECRET"),
    )

    bucket = os.getenv("DO_SPACES_BUCKET")
    prefix = args.prefix

    print(f"Scanning s3://{bucket}/{prefix}...")

    paginator = client.get_paginator("list_objects_v2")
    total_files = 0
    total_size = 0

    objects_to_delete = []

    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            size = obj["Size"]
            total_files += 1
            total_size += size
            objects_to_delete.append({"Key": key})
            print(f"  {key} ({size:,} bytes)")

    print(f"\nFound {total_files} files ({total_size:,} bytes / {total_size / 1024 / 1024:.2f} MB)")

    if not objects_to_delete:
        print("Nothing to delete.")
        return

    if args.delete:
        print(f"\nDeleting {len(objects_to_delete)} files...")
        # Delete in batches of 1000 (S3 limit)
        for i in range(0, len(objects_to_delete), 1000):
            batch = objects_to_delete[i:i+1000]
            client.delete_objects(Bucket=bucket, Delete={"Objects": batch})
            print(f"  Deleted batch {i//1000 + 1}")
        print("Done!")
    else:
        print("\nDry run - no files deleted. Use --delete to actually delete.")

if __name__ == "__main__":
    main()
