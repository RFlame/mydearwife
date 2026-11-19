#!/usr/bin/env python3
"""从 EdgeOne CLI 混合日志中提取最终成功部署的 HTTPS 地址。"""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit


def deployment_url(log_path):
    result = None
    for line in Path(log_path).read_text(encoding="utf-8").splitlines():
        try:
            payload = json.loads(line.strip())
        except (json.JSONDecodeError, UnicodeError):
            continue
        if isinstance(payload, dict) and "status" in payload:
            result = payload
    if not result or result.get("status") != "success":
        raise RuntimeError("EdgeOne CLI did not return a successful deployment result")
    url = result.get("url", "")
    parts = urlsplit(url)
    if (parts.scheme != "https" or not parts.netloc or parts.query or parts.fragment
            or any(char in url for char in "\r\n")):
        raise RuntimeError("EdgeOne CLI returned an invalid public site URL")
    return url.rstrip("/") + "/"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="edgeone makers deploy --json 的完整输出日志")
    parser.add_argument("--github-output", help="可选的 GITHUB_OUTPUT 文件路径")
    args = parser.parse_args()
    url = deployment_url(args.log)
    print("EdgeOne Pages URL: %s" % url)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write("site_url=%s\n" % url)


if __name__ == "__main__":
    main()
