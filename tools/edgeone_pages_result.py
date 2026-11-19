#!/usr/bin/env python3
"""提取 EdgeOne 部署地址，并安全诊断后端部署失败原因。"""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


API_ENDPOINTS = (
    "https://pages-api.cloud.tencent.com/v1",
    "https://pages-api.edgeone.ai/v1",
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


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


def redact(message):
    message = ANSI_ESCAPE.sub("", str(message))
    token = os.environ.get("EDGEONE_API_TOKEN", "")
    if token:
        message = message.replace(token, "[redacted]")
    message = re.sub(r"(Bearer\s+)[^\s]+", r"\1[redacted]", message, flags=re.IGNORECASE)
    message = re.sub(
        r"([?&][^=\s&]*(?:token|signature|sign|secret|key|credential|q-ak)[^=\s&]*=)[^&\s]+",
        r"\1[redacted]", message, flags=re.IGNORECASE)
    message = re.sub(
        r"\b((?:Tmp)?Secret(?:Id|Key)|SecurityToken)\s*[:=]\s*[^\s,;]+",
        r"\1=[redacted]", message, flags=re.IGNORECASE)
    return message


def annotation(message, limit=600):
    message = redact(message)[:limit]
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def api_post(endpoint, data, token):
    request = Request(
        endpoint,
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
        method="POST",
    )
    try:
        with urlopen(request, timeout=20) as response:
            body = response.read(2000001)
    except HTTPError as error:
        return None, "HTTP %s" % error.code
    except (URLError, TimeoutError, OSError):
        return None, "network request failed"
    if len(body) > 2000000:
        return None, "response too large"
    try:
        payload = json.loads(body.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeError):
        return None, "invalid JSON response"
    if not isinstance(payload, dict):
        return None, "unexpected JSON response"
    return payload, None


def backend_failure(log_path):
    """用 CLI 日志里的 ID 查询后端失败详情；绝不输出响应全文。"""
    token = os.environ.get("EDGEONE_API_TOKEN", "")
    log = ANSI_ESCAPE.sub("", Path(log_path).read_text(encoding="utf-8"))
    project = re.search(r"Using Project ID:\s*([A-Za-z0-9_-]+)", log)
    deployment = re.search(r"Created deployment with Deployment ID:\s*([A-Za-z0-9_-]+)", log)
    if not token or not project or not deployment:
        return None
    project_id = project.group(1)
    deployment_id = deployment.group(1)
    request_data = {
        "Action": "DescribePagesDeployments",
        "ProjectId": project_id,
        "Offset": 0,
        "Limit": 50,
        "OrderBy": "CreatedOn",
        "Order": "Desc",
    }
    errors = []
    for endpoint in API_ENDPOINTS:
        payload, query_error = api_post(endpoint, request_data, token)
        host = urlsplit(endpoint).netloc
        if query_error:
            errors.append("%s: %s" % (host, query_error))
            continue
        data = payload.get("Data") if isinstance(payload.get("Data"), dict) else {}
        response = data.get("Response")
        if not isinstance(response, dict):
            response = payload.get("Response") if isinstance(payload.get("Response"), dict) else {}
        if payload.get("Code") != 0:
            error = response.get("Error") if isinstance(response.get("Error"), dict) else {}
            code = error.get("Code") or payload.get("Code") or "unknown"
            message = error.get("Message") or payload.get("Message") or "no API error message"
            errors.append("%s: API code=%s; %s" % (host, code, message))
            continue
        deployments = response.get("Deployments")
        if not isinstance(deployments, list):
            errors.append("%s: deployment list missing" % host)
            continue
        current = next((item for item in deployments if isinstance(item, dict)
                        and item.get("DeploymentId") == deployment_id), None)
        if current is None:
            errors.append("%s: deployment not found" % host)
            continue
        error = current.get("Error") if isinstance(current.get("Error"), dict) else {}
        status = current.get("Status") or "unknown"
        code = current.get("Code") or error.get("Code") or "unavailable"
        message = current.get("Message") or error.get("Message") or "no backend error message"
        return "status=%s; code=%s; message=%s" % (status, code, message)
    return "status query failed: " + " | ".join(errors)


def backend_build_log(log_path):
    """读取官方构建日志的脱敏末尾；签名 URL 仅用于请求，绝不返回或打印。"""
    token = os.environ.get("EDGEONE_API_TOKEN", "")
    log = ANSI_ESCAPE.sub("", Path(log_path).read_text(encoding="utf-8"))
    project = re.search(r"Using Project ID:\s*([A-Za-z0-9_-]+)", log)
    deployment = re.search(r"Created deployment with Deployment ID:\s*([A-Za-z0-9_-]+)", log)
    if not token or not project or not deployment:
        return None
    request_data = {
        "Action": "DescribePagesDeploymentLog",
        "ProjectId": project.group(1),
        "DeploymentId": deployment.group(1),
    }
    for endpoint in API_ENDPOINTS:
        payload, query_error = api_post(endpoint, request_data, token)
        if query_error or payload.get("Code") != 0:
            continue
        data = payload.get("Data") if isinstance(payload.get("Data"), dict) else {}
        response = data.get("Response")
        if not isinstance(response, dict):
            response = payload.get("Response") if isinstance(payload.get("Response"), dict) else {}
        log_url = response.get("LogUrl", "")
        if not isinstance(log_url, str):
            continue
        parts = urlsplit(log_url)
        if parts.scheme != "https" or not parts.netloc or any(char in log_url for char in "\r\n"):
            continue
        try:
            with urlopen(Request(log_url, method="GET"), timeout=20) as log_response:
                body = log_response.read(2000001)
        except (HTTPError, URLError, TimeoutError, OSError):
            continue
        if len(body) > 2000000:
            return "build log exceeded the 2 MB diagnostic limit"
        lines = [line.strip() for line in body.decode("utf-8", errors="replace").splitlines()
                 if line.strip()]
        return redact("\n".join(lines[-16:])[-2400:]) or "build log is empty"
    return None


def diagnose(log_path, query_api=False):
    if query_api:
        detail = backend_failure(log_path)
        if detail:
            print("::error::EdgeOne backend deployment detail: %s" % annotation(detail))
        build_log = backend_build_log(log_path)
        if build_log:
            print("::error::EdgeOne backend build log tail: %s" % annotation(build_log, limit=2400))
    result = deployment_result(log_path)
    if result and result.get("status") == "error":
        message = str(result.get("error") or "unknown CLI error")
    else:
        message = "CLI exited without a structured error result"
    print("::error::EdgeOne Pages deployment failed: %s" % annotation(message))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="edgeone makers deploy --json 的完整输出日志")
    parser.add_argument("--github-output", help="可选的 GITHUB_OUTPUT 文件路径")
    parser.add_argument("--diagnose", action="store_true", help="把结构化错误输出为脱敏的 GitHub 注解")
    parser.add_argument("--query-api", action="store_true", help="失败时只读查询本次部署的后端错误详情")
    args = parser.parse_args()
    if args.diagnose:
        diagnose(args.log, query_api=args.query_api)
        return
    url = deployment_url(args.log)
    print("EdgeOne Pages URL: %s" % url)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write("site_url=%s\n" % url)


if __name__ == "__main__":
    main()
