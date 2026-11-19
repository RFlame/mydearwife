#!/usr/bin/env python3
"""把 Godot Web 产物同步到专用腾讯云 COS 静态网站桶。

凭据只从环境变量读取。先上传全部文件，再删除桶内已经不在本地产物中的旧键；
任何上传失败都会在清理前终止，避免把一次失败发布扩大成整站删除。
"""
import argparse
import mimetypes
import os
from pathlib import Path
import sys
import time


REQUIRED_FILES = ("index.html", "index.js", "index.wasm", "index.pck")
SECRET_ENV = ("TENCENT_SECRET_ID", "TENCENT_SECRET_KEY")

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("application/octet-stream", ".pck")
mimetypes.add_type("image/svg+xml", ".svg")
mimetypes.add_type("font/woff2", ".woff2")


def content_type(key):
    if key.endswith(".html"):
        return "text/html; charset=utf-8"
    return mimetypes.guess_type(key)[0] or "application/octet-stream"


def collect_files(source):
    return {
        path.relative_to(source).as_posix(): path
        for path in source.rglob("*")
        if path.is_file()
    }


def list_remote_keys(client, bucket):
    keys = set()
    marker = ""
    while True:
        response = client.list_objects(Bucket=bucket, Prefix="", Marker=marker, MaxKeys=1000)
        contents = response.get("Contents", [])
        keys.update(item["Key"] for item in contents)
        truncated = response.get("IsTruncated", False)
        if not (truncated is True or str(truncated).lower() == "true"):
            return keys
        marker = response.get("NextMarker", "")
        if not marker:
            raise RuntimeError("COS returned a truncated listing without NextMarker")


def upload_with_retry(client, bucket, key, path):
    """当前 Web 文件远小于 COS 单 PUT 的 5GB 上限，不依赖 UploadPart 权限。"""
    for attempt in range(1, 4):
        try:
            client.put_object_from_local_file(
                Bucket=bucket,
                Key=key,
                LocalFilePath=str(path),
                EnableMD5=True,
                CacheControl="no-cache",
                ContentType=content_type(key),
            )
            return
        except Exception as exc:
            if attempt == 3:
                raise
            print("upload %s attempt %d failed: %s; retrying" % (key, attempt, exc), flush=True)
            time.sleep(attempt * 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="build/web", help="Godot Web 导出目录")
    parser.add_argument("--bucket", help="完整 COS 桶名，包含 -APPID")
    parser.add_argument("--region", help="COS 地域，例如 ap-guangzhou")
    parser.add_argument("--dry-run", action="store_true", help="只检查本地文件和 MIME，不连接腾讯云")
    args = parser.parse_args()

    source = Path(args.source).resolve()
    if not source.is_dir():
        parser.error("Web export directory does not exist: %s" % source)
    files = collect_files(source)
    missing = [name for name in REQUIRED_FILES if name not in files or files[name].stat().st_size == 0]
    if missing:
        parser.error("Missing or empty required Web files: %s" % ", ".join(missing))

    for key in sorted(files):
        print("prepared %s (%s)" % (key, content_type(key)))
    print("Prepared %d files from %s" % (len(files), source))
    if args.dry_run:
        print("Dry run only: no credentials read and no network requests made")
        return 0
    if not args.bucket or not args.region:
        parser.error("--bucket and --region are required unless --dry-run is used")
    missing_env = [name for name in SECRET_ENV if not os.environ.get(name)]
    if missing_env:
        parser.error("Missing environment variables: %s" % ", ".join(missing_env))

    try:
        from qcloud_cos import CosConfig, CosS3Client
    except ImportError:
        parser.error("Install cos-python-sdk-v5 before deploying")

    config = CosConfig(
        Region=args.region,
        SecretId=os.environ["TENCENT_SECRET_ID"],
        SecretKey=os.environ["TENCENT_SECRET_KEY"],
        Scheme="https",
        Timeout=300,
    )
    client = CosS3Client(config)
    for key, path in sorted(files.items()):
        print("uploading %s" % key, flush=True)
        upload_with_retry(client, args.bucket, key, path)

    # 只有全部文件上传成功才清理旧键；本脚本只能用于专用游戏桶。
    stale = sorted(list_remote_keys(client, args.bucket) - set(files))
    for key in stale:
        print("deleting stale %s" % key, flush=True)
        client.delete_object(Bucket=args.bucket, Key=key)
    print("COS deployment complete: %d uploaded, %d stale deleted" % (len(files), len(stale)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
