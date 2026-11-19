#!/usr/bin/env python3
"""从 EdgeOne CLI 混合日志中提取最终成功部署的 HTTPS 地址。"""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.parse import urlsplit


def deployment_result(log_path):
    result = None
    for line in Path(log_path).read_text(encoding="utf-8").splitlines():
        try:
            payload = json.loads(line.strip())
        except (json.JSONDecodeError, UnicodeError):
            continue
        if isinstance(payload, dict) and "status" in payload:
            result = payload
    return result


def deployment_url(log_path):
    result = deployment_result(log_path)
    if not result or result.get("status") != "success":
        raise RuntimeError("EdgeOne CLI did not return a successful deployment result")
    url = result.get("url", "")
    parts = urlsplit(url)
    if (parts.scheme != "https" or not parts.netloc or parts.query or parts.fragment
            or any(char in url for char in "\r\n")):
        raise RuntimeError("EdgeOne CLI returned an invalid public site URL")
    return url.rstrip("/") + "/"


def diagnose(log_path):
    result = deployment_result(log_path)
    if result and result.get("status") == "error":
        message = str(result.get("error") or "unknown CLI error")
    else:
        message = "CLI exited without a structured error result"
    token = os.environ.get("EDGEONE_API_TOKEN", "")
    if token:
        message = message.replace(token, "[redacted]")
    message = re.sub(r"(Bearer\s+)[^\s]+", r"\1[redacted]", message, flags=re.IGNORECASE)
    message = re.sub(
        r"([?&][^=\s&]*(?:token|signature|sign|secret|key)[^=\s&]*=)[^&\s]+",
        r"\1[redacted]", message, flags=re.IGNORECASE)
    message = message[:600].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::error::EdgeOne Pages deployment failed: %s" % message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="edgeone makers deploy --json 的完整输出日志")
    parser.add_argument("--github-output", help="可选的 GITHUB_OUTPUT 文件路径")
    parser.add_argument("--diagnose", action="store_true", help="把结构化错误输出为脱敏的 GitHub 注解")
    args = parser.parse_args()
    if args.diagnose:
        diagnose(args.log)
        return
    url = deployment_url(args.log)
    print("EdgeOne Pages URL: %s" % url)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write("site_url=%s\n" % url)


if __name__ == "__main__":
    main()
