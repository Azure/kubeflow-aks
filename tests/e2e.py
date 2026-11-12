#!/usr/bin/env python3

"""End-to-end release gate for the Kubeflow on AKS lab.

Derived from upstream ``tests/dex_login_test.py`` in
kubeflow/community-distribution, but parameterized by KUBEFLOW_ENDPOINT,
DEX_USERNAME, and DEX_PASSWORD, and with TLS verification mandatory. Upstream
runs against a port-forwarded Kind cluster over plain HTTP and therefore
carries a switch to bypass certificate checking; this gate exists to prove
publicly trusted HTTPS, so no such switch is offered.

The gate prints exactly six PASS markers on success and never prints the Dex
password or a session cookie, including on any failure path.
"""

import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import urlencode, urlsplit

import requests

DEX_AUTHENTICATION_TYPE = "local"
REQUEST_TIMEOUT_SECONDS = 30
KUBECTL_TIMEOUT_SECONDS = 120
KUBECTL_REQUEST_TIMEOUT = "30s"

WORKSPACE_NAME = "aks-e2e-workspace"
WORKSPACE_KIND_NAME = "aks-e2e-jupyterlab"
WORKSPACE_HOME_PVC = "aks-e2e-workspace-home"
WORKSPACE_NAMESPACE = "kubeflow-user-example-com"
WORKSPACE_READY_TIMEOUT_SECONDS = 600
WORKSPACE_POLL_INTERVAL_SECONDS = 10
WORKSPACE_DELETE_TIMEOUT_SECONDS = 180

WORKSPACES_API_PATH = f"/workspaces/api/v1/workspaces/{WORKSPACE_NAMESPACE}"

# Any one of these in the response body identifies the page. They are kept as
# alternatives because the marker a single-page application serves is a
# property of its build, not of this lab.
DASHBOARD_MARKERS = ("Kubeflow Central Dashboard", "<main-page", "centraldashboard")
JUPYTERLAB_MARKERS = ("jupyter-config-data", "JupyterLab", "jupyterlab")

_REDACTED_VALUES: set[str] = set()


def register_secret(secret_value: str) -> None:
    """Register a value that must never reach stdout or stderr."""
    if secret_value and len(secret_value) >= 4:
        _REDACTED_VALUES.add(secret_value)


def scrub(message: object) -> str:
    """Replace every registered secret in ``message`` with a placeholder."""
    scrubbed_message = str(message)
    for secret_value in _REDACTED_VALUES:
        scrubbed_message = scrubbed_message.replace(secret_value, "<redacted>")
    return scrubbed_message


def emit(message: str) -> None:
    print(scrub(message), flush=True)


def emit_error(message: str) -> None:
    print(scrub(message), file=sys.stderr, flush=True)


class GateError(RuntimeError):
    """A release-gate check failed."""


def require_environment(variable_name: str, default_value: str | None = None) -> str:
    value = os.environ.get(variable_name, default_value)
    if value is None or value == "":
        raise GateError(f"{variable_name} must be set")
    return value


def require_https_endpoint(endpoint_url: str) -> str:
    split_endpoint = urlsplit(endpoint_url)
    if split_endpoint.scheme != "https":
        raise GateError(
            f"KUBEFLOW_ENDPOINT must use https, got scheme '{split_endpoint.scheme}'"
        )
    if not split_endpoint.hostname:
        raise GateError("KUBEFLOW_ENDPOINT must contain a hostname")
    return endpoint_url.rstrip("/")


def same_endpoint_host(response: requests.Response, endpoint_url: str) -> bool:
    """True when a response was finally served over HTTPS by the endpoint host."""
    response_url = urlsplit(response.url)
    endpoint = urlsplit(endpoint_url)
    return response_url.scheme == "https" and response_url.netloc == endpoint.netloc


def marker_in_body(response_text: str, markers: tuple[str, ...]) -> bool:
    lowered_body = response_text.lower()
    return any(marker.lower() in lowered_body for marker in markers)


class DexSessionManager:
    """Authenticate against Dex through oauth2-proxy and keep the session.

    This is the upstream DexSessionManager narrowed to the one transport this
    lab supports: HTTPS with normal CA verification. ``requests`` verifies by
    default and this class never overrides that.
    """

    def __init__(self, endpoint_url: str, dex_username: str, dex_password: str) -> None:
        self._endpoint_url = endpoint_url
        self._dex_username = dex_username
        self._dex_password = dex_password
        self.session = requests.Session()

    def _request_get(self, request_url: str) -> requests.Response:
        return self.session.get(
            request_url, allow_redirects=True, timeout=REQUEST_TIMEOUT_SECONDS
        )

    def _request_post(self, request_url: str, form_data: dict) -> requests.Response:
        return self.session.post(
            request_url,
            data=form_data,
            allow_redirects=True,
            timeout=REQUEST_TIMEOUT_SECONDS,
        )

    def has_oauth2_session_cookie(self) -> bool:
        return any(cookie.name.startswith("oauth2_proxy") for cookie in self.session.cookies)

    def _register_cookies_as_secrets(self) -> None:
        for cookie in self.session.cookies:
            register_secret(cookie.value)

    def _resolve_dex_login_url(self, split_url_object) -> str:
        if re.search(r"/auth$", split_url_object.path):
            split_url_object = split_url_object._replace(
                path=re.sub(
                    r"/auth$", f"/auth/{DEX_AUTHENTICATION_TYPE}", split_url_object.path
                )
            )
        if re.search(r"/auth/.*/login$", split_url_object.path):
            return split_url_object.geturl()
        response = self._request_get(split_url_object.geturl())
        if response.status_code != 200:
            raise GateError(
                f"HTTP {response.status_code} for GET against the Dex login page"
            )
        return response.url

    def authenticate(self) -> requests.Response:
        """Log in through oauth2-proxy and Dex. Returns the final response."""
        try:
            response = self._request_get(self._endpoint_url)

            if response.status_code in (401, 403):
                # oauth2-proxy sign-in page: start the flow explicitly.
                split_url_object = urlsplit(response.url)
                split_url_object = split_url_object._replace(
                    path="/oauth2/start", query=urlencode({"rd": split_url_object.path})
                )
                response = self._request_get(split_url_object.geturl())
                if response.status_code not in (200, 302):
                    raise GateError(
                        f"HTTP {response.status_code} for GET against /oauth2/start"
                    )
            elif response.status_code != 200:
                raise GateError(
                    f"HTTP {response.status_code} for GET against the Kubeflow endpoint"
                )

            if len(response.history) == 0:
                raise GateError(
                    "The Kubeflow endpoint did not redirect to authentication. "
                    "The dashboard must not be reachable unauthenticated."
                )

            dex_login_url = self._resolve_dex_login_url(urlsplit(response.url))
            response = self._request_post(
                dex_login_url,
                form_data={"login": self._dex_username, "password": self._dex_password},
            )

            if response.status_code == 403:
                # A 403 whose redirect chain already passed through the callback
                # with a session cookie set means the login actually succeeded.
                history_urls = [history.url for history in response.history]
                if any("/oauth2/callback" in url for url in history_urls) and (
                    self.has_oauth2_session_cookie()
                ):
                    self._register_cookies_as_secrets()
                    return response

                oauth_start_url = f"{self._endpoint_url}/oauth2/start"
                response = self._request_get(oauth_start_url)
                if response.status_code not in (200, 302):
                    raise GateError(
                        f"HTTP {response.status_code} for GET against /oauth2/start "
                        "during 403 recovery"
                    )
                dex_login_url = self._resolve_dex_login_url(urlsplit(response.url))
                response = self._request_post(
                    dex_login_url,
                    form_data={
                        "login": self._dex_username,
                        "password": self._dex_password,
                    },
                )

            if response.status_code != 200:
                raise GateError(
                    f"HTTP {response.status_code} for the Dex login POST"
                )
            if len(response.history) == 0:
                raise GateError(
                    "No redirect after the Dex login POST: the credentials are "
                    "probably invalid."
                )

            split_url_object = urlsplit(response.url)
            if re.search(r"/approval$", split_url_object.path):
                response = self._request_post(
                    split_url_object.geturl(), form_data={"approval": "approve"}
                )
                if response.status_code != 200:
                    raise GateError(
                        f"HTTP {response.status_code} for the Dex approval POST"
                    )

            self._register_cookies_as_secrets()
            return response
        except requests.exceptions.SSLError as ssl_error:
            raise GateError(f"TLS verification failed during login: {ssl_error}") from ssl_error
        except requests.RequestException as request_exception:
            raise GateError(
                f"Dex authentication request failed: {request_exception}"
            ) from request_exception


def run_kubectl(arguments: list[str], check: bool = True) -> subprocess.CompletedProcess:
    command_arguments = ["kubectl", "--request-timeout", KUBECTL_REQUEST_TIMEOUT, *arguments]
    try:
        command_result = subprocess.run(
            command_arguments,
            check=False,
            text=True,
            capture_output=True,
            timeout=KUBECTL_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as timeout_exception:
        raise GateError(
            f"kubectl timed out after {KUBECTL_TIMEOUT_SECONDS}s: {' '.join(arguments)}"
        ) from timeout_exception
    if check and command_result.returncode != 0:
        raise GateError(
            f"kubectl failed (rc={command_result.returncode}): {' '.join(arguments)}\n"
            f"stderr:\n{command_result.stderr.strip()}"
        )
    return command_result


def check_trusted_tls(endpoint_url: str) -> None:
    """Require a TLS handshake that a default CA bundle accepts."""
    try:
        response = requests.get(
            endpoint_url, allow_redirects=True, timeout=REQUEST_TIMEOUT_SECONDS
        )
    except requests.exceptions.SSLError as ssl_error:
        raise GateError(
            f"TLS verification against {endpoint_url} failed: {ssl_error}"
        ) from ssl_error
    except requests.RequestException as request_exception:
        raise GateError(
            f"Request to {endpoint_url} failed: {request_exception}"
        ) from request_exception
    if not same_endpoint_host(response, endpoint_url):
        raise GateError(
            f"Endpoint left the requested host over HTTPS: final URL was {response.url}"
        )
    emit("PASS trusted-tls")


def check_dex_login(manager: DexSessionManager, endpoint_url: str) -> requests.Response:
    response = manager.authenticate()
    if not manager.has_oauth2_session_cookie():
        raise GateError(
            "No oauth2_proxy session cookie after login: oauth2-proxy did not "
            "establish a session."
        )
    if not same_endpoint_host(response, endpoint_url):
        raise GateError(
            f"Login did not return to the endpoint host over HTTPS: {response.url}"
        )
    emit("PASS dex-login")
    return response


def check_dashboard(manager: DexSessionManager, endpoint_url: str) -> None:
    response = manager.session.get(
        f"{endpoint_url}/", allow_redirects=True, timeout=REQUEST_TIMEOUT_SECONDS
    )
    if response.status_code != 200:
        raise GateError(f"HTTP {response.status_code} for the authenticated dashboard")
    if not same_endpoint_host(response, endpoint_url):
        raise GateError(f"Dashboard served from an unexpected URL: {response.url}")
    if not marker_in_body(response.text, DASHBOARD_MARKERS):
        raise GateError(
            "The dashboard response carried no Kubeflow marker "
            f"(looked for: {', '.join(DASHBOARD_MARKERS)})"
        )
    emit("PASS dashboard")


def apply_test_workspace(
    workspacekind_manifest_path: str,
    workspace_manifest_path: str,
) -> None:
    for manifest_path, description in (
        (workspacekind_manifest_path, "WorkspaceKind"),
        (workspace_manifest_path, "Workspace"),
    ):
        if not os.path.isfile(manifest_path):
            raise GateError(f"{description} manifest not found: {manifest_path}")

    run_kubectl(["apply", "--filename", workspacekind_manifest_path])
    run_kubectl(["apply", "--filename", workspace_manifest_path])


def wait_for_workspace_ready() -> None:
    deadline = time.monotonic() + WORKSPACE_READY_TIMEOUT_SECONDS
    last_observed = "<none>"
    last_message = ""

    while time.monotonic() < deadline:
        command_result = run_kubectl(
            [
                "get",
                "workspace",
                WORKSPACE_NAME,
                "--namespace",
                WORKSPACE_NAMESPACE,
                "--output",
                "json",
            ],
            check=False,
        )

        if command_result.returncode == 0:
            try:
                payload = json.loads(command_result.stdout)
            except ValueError:
                payload = {}

            status = payload.get("status", {})
            if isinstance(status, dict):
                state = status.get("state")
                message = status.get("stateMessage")

                if isinstance(state, str) and state:
                    last_observed = state
                if isinstance(message, str):
                    last_message = message

                if state == "Running":
                    emit("PASS workspaces-controller")
                    return

        time.sleep(WORKSPACE_POLL_INTERVAL_SECONDS)

    detail = f"state={last_observed}"
    if last_message:
        detail += f", message={last_message}"

    raise GateError(
        f"Workspace {WORKSPACE_NAME} did not reach state=Running within "
        f"{WORKSPACE_READY_TIMEOUT_SECONDS}s ({detail})"
    )


def check_workspaces_api(
    manager: DexSessionManager,
    endpoint_url: str,
) -> str:
    response = manager.session.get(
        f"{endpoint_url}{WORKSPACES_API_PATH}",
        allow_redirects=True,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )

    if response.status_code != 200:
        raise GateError(f"HTTP {response.status_code} for {WORKSPACES_API_PATH}")

    if not same_endpoint_host(response, endpoint_url):
        raise GateError(f"Workspaces API served from an unexpected URL: {response.url}")

    try:
        payload = response.json()
    except ValueError as value_error:
        raise GateError(
            f"The Workspaces API did not return JSON: {value_error}"
        ) from value_error

    if not isinstance(payload, dict):
        raise GateError(
            f"The Workspaces API returned {type(payload).__name__}, expected an object"
        )

    workspaces = payload.get("data")
    if not isinstance(workspaces, list):
        raise GateError("The Workspaces API response has no data array")

    workspace = next(
        (
            item
            for item in workspaces
            if isinstance(item, dict)
            and item.get("name") == WORKSPACE_NAME
            and item.get("namespace") == WORKSPACE_NAMESPACE
        ),
        None,
    )

    if workspace is None:
        names = [
            item.get("name")
            for item in workspaces
            if isinstance(item, dict)
        ]
        raise GateError(
            f"The Workspaces API did not list '{WORKSPACE_NAME}'; "
            f"it returned: {names}"
        )

    state = workspace.get("state")
    if state != "Running":
        raise GateError(
            f"The Workspaces API reported state={state!r} for "
            f"'{WORKSPACE_NAME}', expected 'Running'"
        )

    services = workspace.get("services")
    if not isinstance(services, list):
        raise GateError(
            f"The Workspaces API returned no services for '{WORKSPACE_NAME}'"
        )

    http_path = None
    for service in services:
        if not isinstance(service, dict):
            continue

        http_service = service.get("httpService")
        if not isinstance(http_service, dict):
            continue

        candidate = http_service.get("httpPath")
        if (
            http_service.get("displayName") == "JupyterLab"
            and isinstance(candidate, str)
        ):
            http_path = candidate
            break

    if not http_path:
        raise GateError(
            f"The Workspaces API returned no JupyterLab HTTP service for "
            f"'{WORKSPACE_NAME}'"
        )

    expected_prefix = (
        f"/workspace/connect/{WORKSPACE_NAMESPACE}/{WORKSPACE_NAME}/"
    )
    if not http_path.startswith(expected_prefix):
        raise GateError(
            f"The Workspaces API returned an unexpected service path: {http_path}"
        )

    if not http_path.endswith("/jupyterlab/"):
        raise GateError(
            f"The JupyterLab service path does not end in /jupyterlab/: {http_path}"
        )

    emit("PASS workspaces-api")
    return http_path


def check_jupyterlab(
    manager: DexSessionManager,
    endpoint_url: str,
    http_path: str,
) -> None:
    jupyterlab_path = f"{http_path.rstrip('/')}/lab"

    response = manager.session.get(
        f"{endpoint_url}{jupyterlab_path}",
        allow_redirects=True,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )

    if response.status_code != 200:
        raise GateError(f"HTTP {response.status_code} for {jupyterlab_path}")

    if not same_endpoint_host(response, endpoint_url):
        raise GateError(f"JupyterLab served from an unexpected URL: {response.url}")

    if not marker_in_body(response.text, JUPYTERLAB_MARKERS):
        raise GateError(
            "The JupyterLab response carried no JupyterLab marker "
            f"(looked for: {', '.join(JUPYTERLAB_MARKERS)})"
        )

    emit("PASS jupyterlab")


def delete_test_workspace() -> None:
    """Delete the gate Workspace and the resources created specifically for it."""

    run_kubectl(
        [
            "delete",
            "workspace",
            WORKSPACE_NAME,
            "--namespace",
            WORKSPACE_NAMESPACE,
            "--ignore-not-found",
            f"--timeout={WORKSPACE_DELETE_TIMEOUT_SECONDS}s",
        ],
        check=False,
    )

    deadline = time.monotonic() + WORKSPACE_DELETE_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        command_result = run_kubectl(
            [
                "get",
                "pods",
                "--namespace",
                WORKSPACE_NAMESPACE,
                "--selector",
                f"workspaces.kubeflow.org/workspace-name={WORKSPACE_NAME}",
                "--output",
                "jsonpath={.items[*].metadata.name}",
            ],
            check=False,
        )

        if command_result.returncode == 0 and not command_result.stdout.strip():
            break

        time.sleep(WORKSPACE_POLL_INTERVAL_SECONDS)
    else:
        emit_error(
            f"Warning: pods for Workspace {WORKSPACE_NAME} were still present "
            f"after {WORKSPACE_DELETE_TIMEOUT_SECONDS}s."
        )

    run_kubectl(
        [
            "delete",
            "pvc",
            WORKSPACE_HOME_PVC,
            "--namespace",
            WORKSPACE_NAMESPACE,
            "--ignore-not-found",
            f"--timeout={WORKSPACE_DELETE_TIMEOUT_SECONDS}s",
        ],
        check=False,
    )

    run_kubectl(
        [
            "delete",
            "workspacekind",
            WORKSPACE_KIND_NAME,
            "--ignore-not-found",
            f"--timeout={WORKSPACE_DELETE_TIMEOUT_SECONDS}s",
        ],
        check=False,
    )


def main() -> None:
    endpoint_url = require_https_endpoint(require_environment("KUBEFLOW_ENDPOINT"))
    dex_username = require_environment("DEX_USERNAME", "user@example.com")
    dex_password = require_environment("DEX_PASSWORD")
    workspacekind_manifest_path = require_environment("WORKSPACEKIND_MANIFEST")
    workspace_manifest_path = require_environment("WORKSPACE_MANIFEST")
    register_secret(dex_password)

    check_trusted_tls(endpoint_url)

    manager = DexSessionManager(endpoint_url, dex_username, dex_password)
    check_dex_login(manager, endpoint_url)
    check_dashboard(manager, endpoint_url)

    try:
        apply_test_workspace(
            workspacekind_manifest_path,
            workspace_manifest_path,
        )
        wait_for_workspace_ready()
        http_path = check_workspaces_api(manager, endpoint_url)
        check_jupyterlab(manager, endpoint_url, http_path)
    finally:
        delete_test_workspace()


if __name__ == "__main__":
    try:
        main()
    except Exception as gate_exception:  # noqa: BLE001 - the message is scrubbed
        emit_error(f"Release gate failed: {gate_exception}")
        raise SystemExit(1) from None
