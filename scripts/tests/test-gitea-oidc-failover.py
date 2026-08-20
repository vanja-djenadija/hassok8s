#!/usr/bin/env python3

import argparse
import csv
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup
from requests.packages.urllib3.exceptions import InsecureRequestWarning


requests.packages.urllib3.disable_warnings(InsecureRequestWarning)


def now_ts():
    return datetime.now().isoformat(timespec="seconds")


def run_kubectl_delete(namespace: str, pod: str):
    subprocess.run(
        ["kubectl", "delete", "pod", "-n", namespace, pod, "--wait=false"],
        check=True,
        text=True,
    )


def find_keycloak_login_form(html: str, current_url: str):
    soup = BeautifulSoup(html, "html.parser")

    form = soup.find("form", id="kc-form-login")

    if form is None:
        for candidate in soup.find_all("form"):
            text = str(candidate).lower()
            if "username" in text and "password" in text:
                form = candidate
                break

    if form is None:
        raise RuntimeError("Keycloak login form was not found")

    action = form.get("action")

    if not action:
        raise RuntimeError("Keycloak login form action was not found")

    action_url = urljoin(current_url, action)

    payload = {}

    for inp in form.find_all("input"):
        name = inp.get("name")
        value = inp.get("value", "")
        if name:
            payload[name] = value

    return action_url, payload


def oidc_login_once(gitea_url: str, provider: str, username: str, password: str, timeout: int):
    session = requests.Session()

    start_url = f"{gitea_url.rstrip('/')}/user/oauth2/{provider}"

    first_response = session.get(
        start_url,
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    action_url, payload = find_keycloak_login_form(first_response.text, first_response.url)

    payload["username"] = username
    payload["password"] = password

    session.post(
        action_url,
        data=payload,
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    check_response = session.get(
        f"{gitea_url.rstrip('/')}/user/settings",
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    final_url = check_response.url
    body = check_response.text.lower()

    if check_response.status_code >= 400:
        raise RuntimeError(
            f"Gitea settings check failed with HTTP {check_response.status_code}"
        )

    if "/user/login" in final_url:
        raise RuntimeError(f"User is not logged in after OIDC flow; final_url={final_url}")

    if "registration is disabled" in body:
        raise RuntimeError("Gitea registration is disabled")

    return {
        "http_status": check_response.status_code,
        "final_url": final_url,
    }


def create_existing_session(
    gitea_url: str,
    provider: str,
    username: str,
    password: str,
    timeout: int,
):
    session = requests.Session()

    start_url = f"{gitea_url.rstrip('/')}/user/oauth2/{provider}"

    first_response = session.get(
        start_url,
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    action_url, payload = find_keycloak_login_form(first_response.text, first_response.url)

    payload["username"] = username
    payload["password"] = password

    session.post(
        action_url,
        data=payload,
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    check_response = session.get(
        f"{gitea_url.rstrip('/')}/user/settings",
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    if check_response.status_code >= 400:
        raise RuntimeError(
            f"Existing Gitea session check failed with HTTP {check_response.status_code}"
        )

    if "/user/login" in check_response.url:
        raise RuntimeError("Existing Gitea session could not be established")

    return session


def existing_session_check(session, gitea_url: str, timeout: int):
    response = session.get(
        f"{gitea_url.rstrip('/')}/user/settings",
        allow_redirects=True,
        timeout=timeout,
        verify=False,
    )

    if response.status_code >= 400:
        raise RuntimeError(f"Existing session check failed with HTTP {response.status_code}")

    if "/user/login" in response.url:
        raise RuntimeError("Existing session was redirected to login")

    return {
        "http_status": response.status_code,
        "final_url": response.url,
    }


def summarize(rows, interval):
    total = len(rows)
    success = sum(1 for r in rows if r["success"] == "1")
    failed = total - success

    availability = (success / total * 100) if total else 0

    post_rows = [r for r in rows if r["phase"] == "post_delete"]
    post_total = len(post_rows)
    post_success = sum(1 for r in post_rows if r["success"] == "1")
    post_failed = post_total - post_success

    post_availability = (post_success / post_total * 100) if post_total else 0

    longest_fail_run = 0
    current_fail_run = 0

    for r in post_rows:
        if r["success"] == "0":
            current_fail_run += 1
            longest_fail_run = max(longest_fail_run, current_fail_run)
        else:
            current_fail_run = 0

    successful_durations = [
        float(r["duration_s"])
        for r in rows
        if r["success"] == "1"
    ]

    durations_sorted = sorted(successful_durations)

    def percentile(p):
        if not durations_sorted:
            return 0.0

        index = int(round((p / 100) * (len(durations_sorted) - 1)))
        return durations_sorted[index]

    return {
        "total_requests": total,
        "successful_requests": success,
        "failed_requests": failed,
        "availability_percent": f"{availability:.3f}",
        "post_delete_requests": post_total,
        "post_delete_successful": post_success,
        "post_delete_failed": post_failed,
        "post_delete_availability_percent": f"{post_availability:.3f}",
        "estimated_interruption_s": f"{longest_fail_run * interval:.3f}",
        "min_response_time_s": f"{min(successful_durations) if successful_durations else 0:.6f}",
        "avg_response_time_s": f"{sum(successful_durations) / len(successful_durations) if successful_durations else 0:.6f}",
        "median_response_time_s": f"{percentile(50):.6f}",
        "p95_response_time_s": f"{percentile(95):.6f}",
        "max_response_time_s": f"{max(successful_durations) if successful_durations else 0:.6f}",
    }


def write_summary_file(
    output_dir: Path,
    check_type: str,
    summary: dict,
    args,
):
    summary_path = output_dir / f"summary-{check_type}.txt"

    with summary_path.open("w", encoding="utf-8") as f:
        f.write("test=gitea_oidc_failover\n")
        f.write(f"check_type={check_type}\n")
        f.write(f"gitea_url={args.gitea_url}\n")
        f.write(f"provider={args.provider}\n")
        f.write(f"namespace={args.namespace}\n")
        f.write(f"victim_pod={args.victim_pod}\n")
        f.write(f"pre_delete_iterations={args.pre}\n")
        f.write(f"post_delete_iterations={args.post}\n")
        f.write(f"interval_s={args.interval}\n")
        f.write(f"timeout_s={args.timeout}\n")

        for key, value in summary.items():
            f.write(f"{key}={value}\n")


def main():
    parser = argparse.ArgumentParser(
        description="Automated Gitea OIDC failover test through Keycloak."
    )

    parser.add_argument(
        "--gitea-url",
        default="http://gitea-ha.etfbl.net",
        help="Base URL of the Gitea instance.",
    )

    parser.add_argument(
        "--provider",
        default="keycloak",
        help="Gitea OAuth2 provider name. This must match the Gitea authentication source name.",
    )

    parser.add_argument(
        "--namespace",
        default="keycloak",
        help="Kubernetes namespace where Keycloak pods are running.",
    )

    parser.add_argument(
        "--victim-pod",
        required=True,
        help="Keycloak pod that will be deleted during the test.",
    )

    parser.add_argument(
        "--pre",
        type=int,
        default=10,
        help="Number of iterations before pod deletion.",
    )

    parser.add_argument(
        "--post",
        type=int,
        default=120,
        help="Number of iterations after pod deletion.",
    )

    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="Pause between iterations in seconds.",
    )

    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="HTTP request timeout in seconds.",
    )

    parser.add_argument(
        "--mode",
        choices=["new-login", "existing-session", "both"],
        default="both",
        help="Which scenario to test.",
    )

    parser.add_argument(
        "--no-delete",
        action="store_true",
        help="Do not delete the victim pod. Useful for smoke testing.",
    )

    parser.add_argument(
        "--output-dir",
        default=None,
        help="Directory where results will be stored.",
    )

    args = parser.parse_args()

    username = os.environ.get("KC_USERNAME")
    password = os.environ.get("KC_PASSWORD")

    if not username or not password:
        raise SystemExit(
            "KC_USERNAME and KC_PASSWORD environment variables are required."
        )

    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = Path(args.output_dir or f"logs/tests/gitea-oidc-failover-{run_id}")
    output_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    existing_session = None

    if args.mode in ("existing-session", "both"):
        print("[INFO] Establishing existing Gitea session before pod deletion...")

        existing_session = create_existing_session(
            args.gitea_url,
            args.provider,
            username,
            password,
            args.timeout,
        )

        print("[INFO] Existing Gitea session established.")

    total_iterations = args.pre + args.post

    for i in range(total_iterations):
        if i == args.pre:
            print(f"[EVENT] Deleting pod {args.victim_pod} in namespace {args.namespace}")

            if not args.no_delete:
                run_kubectl_delete(args.namespace, args.victim_pod)
            else:
                print("[EVENT] --no-delete is enabled. Pod deletion skipped.")

        phase = "pre_delete" if i < args.pre else "post_delete"

        checks = []

        if args.mode in ("new-login", "both"):
            checks.append(
                (
                    "new_login",
                    lambda: oidc_login_once(
                        args.gitea_url,
                        args.provider,
                        username,
                        password,
                        args.timeout,
                    ),
                )
            )

        if args.mode in ("existing-session", "both"):
            checks.append(
                (
                    "existing_session",
                    lambda: existing_session_check(
                        existing_session,
                        args.gitea_url,
                        args.timeout,
                    ),
                )
            )

        for check_type, check_function in checks:
            start_time = time.time()

            success = "0"
            error = ""
            http_status = ""
            final_url = ""

            try:
                result = check_function()
                success = "1"
                http_status = str(result.get("http_status", ""))
                final_url = result.get("final_url", "")
            except Exception as exc:
                error = str(exc).replace("\n", " ")[:500]

            duration = time.time() - start_time

            row = {
                "timestamp": now_ts(),
                "iteration": str(i + 1),
                "phase": phase,
                "check_type": check_type,
                "success": success,
                "duration_s": f"{duration:.6f}",
                "http_status": http_status,
                "final_url": final_url,
                "error": error,
            }

            rows.append(row)

            print(
                f"[{row['timestamp']}] "
                f"{phase} "
                f"{check_type} "
                f"success={success} "
                f"duration={duration:.3f}s "
                f"http_status={http_status} "
                f"error={error}"
            )

        time.sleep(args.interval)

    csv_path = output_dir / "results.csv"

    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "timestamp",
                "iteration",
                "phase",
                "check_type",
                "success",
                "duration_s",
                "http_status",
                "final_url",
                "error",
            ],
        )

        writer.writeheader()
        writer.writerows(rows)

    check_types = sorted(set(r["check_type"] for r in rows))

    for check_type in check_types:
        subset = [r for r in rows if r["check_type"] == check_type]
        summary = summarize(subset, args.interval)

        write_summary_file(
            output_dir=output_dir,
            check_type=check_type,
            summary=summary,
            args=args,
        )

        print(f"\n[SUMMARY] {check_type}")

        for key, value in summary.items():
            print(f"{key}={value}")

    print(f"\n[INFO] Results saved in: {output_dir}")


if __name__ == "__main__":
    main()