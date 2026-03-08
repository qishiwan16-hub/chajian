#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

BASE_DIR = Path(__file__).resolve().parent
WEB_DIR = BASE_DIR / "web"
SCRIPT_PATH = BASE_DIR / "update_sillytavern_extensions_termux.sh"
OVERRIDES_PATH = BASE_DIR / "plugin_name_overrides.json"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_TIMEOUT = 900
MAX_REQUEST_BODY = 1024 * 1024
MAX_METADATA_BYTES = 512 * 1024

STATUS_LABELS = {
    "update_available": "可更新",
    "updated": "已更新",
    "up_to_date": "已最新",
    "whitelist_skipped": "白名单跳过",
    "non_git": "非 Git",
    "no_upstream": "无上游",
    "remote_unreachable": "远程不可访问",
    "update_failed": "更新失败",
}

SOURCE_LABELS = {
    "public": "公共扩展",
    "user": "用户扩展",
}

DISPLAY_NAME_KEYS = (
    "display_name",
    "displayName",
    "title",
    "plugin_name",
    "pluginName",
    "label",
    "name",
)

NESTED_METADATA_KEYS = (
    "manifest",
    "plugin",
    "extension",
    "package",
    "metadata",
    "meta",
    "info",
)


class ApiError(Exception):
    def __init__(self, code: str, message: str, details: Any = None, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details
        self.status = status

    def to_payload(self) -> dict[str, Any]:
        return {
            "ok": False,
            "error": {
                "code": self.code,
                "message": self.message,
                "details": self.details,
            },
        }


class WebPanelApp:
    def __init__(self, host: str, port: int, timeout: int, preferred_bash: str = "") -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.preferred_bash = preferred_bash.strip()
        self.web_dir = WEB_DIR
        self.script_path = SCRIPT_PATH
        self.overrides_path = OVERRIDES_PATH

    def run(self) -> None:
        if not self.script_path.exists():
            raise RuntimeError(f"找不到脚本文件：{self.script_path}")
        if not self.web_dir.exists():
            raise RuntimeError(f"找不到前端目录：{self.web_dir}")

        server = PanelHTTPServer((self.host, self.port), PanelRequestHandler, self)
        print(f"SillyTavern Web 面板已启动： http://{self.host}:{self.port}")
        print(f"静态目录：{self.web_dir}")
        print(f"脚本路径：{self.script_path}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止 Web 面板。")
        finally:
            server.server_close()

    def resolve_bash_executable(self) -> tuple[str, bool]:
        candidates: list[str] = []
        git_bash_candidates = [
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files\Git\usr\bin\bash.exe",
        ]

        if self.preferred_bash:
            candidates.append(self.preferred_bash)

        if os.name == "nt":
            candidates.extend(git_bash_candidates)
            path_bash = shutil.which("bash")
            if path_bash:
                lowered = path_bash.lower()
                if "windows\\system32\\bash.exe" not in lowered:
                    candidates.append(path_bash)
        else:
            for name in ("bash", "sh"):
                resolved = shutil.which(name)
                if resolved:
                    candidates.append(resolved)

        seen: set[str] = set()
        normalized_candidates: list[str] = []
        for item in candidates:
            if not item:
                continue
            normalized = os.path.normcase(os.path.abspath(item)) if os.path.isabs(item) else item
            if normalized in seen:
                continue
            seen.add(normalized)
            normalized_candidates.append(item)

        for candidate in normalized_candidates:
            if os.path.isabs(candidate):
                if os.path.exists(candidate):
                    return candidate, os.name == "nt" and "git" in candidate.lower()
            else:
                resolved = shutil.which(candidate)
                if resolved:
                    return resolved, os.name == "nt" and "git" in resolved.lower()

        raise ApiError(
            code="bash_not_found",
            message="未找到可用的 bash，请先在 Termux 安装 bash 或在桌面端安装 Git Bash",
            details={"preferred_bash": self.preferred_bash or None},
            status=500,
        )

    def to_bash_path(self, value: str, git_bash_mode: bool) -> str:
        if not value:
            return value
        if not git_bash_mode:
            return value
        if re.match(r"^[A-Za-z]:[\\/]", value):
            drive = value[0].lower()
            rest = value[2:].replace("\\", "/")
            return f"/{drive}{rest}"
        return value.replace("\\", "/")

    def build_script_command(self, command: str, options: dict[str, Any]) -> list[str]:
        bash_executable, git_bash_mode = self.resolve_bash_executable()
        script_arg = self.to_bash_path(str(self.script_path), git_bash_mode)
        cmd = [bash_executable, script_arg, "--json", command]

        def add_path_option(flag: str, raw_value: Any) -> None:
            if raw_value is None:
                return
            value = str(raw_value).strip()
            if not value:
                return
            cmd.extend([flag, self.to_bash_path(value, git_bash_mode)])

        def add_text_option(flag: str, raw_value: Any) -> None:
            if raw_value is None:
                return
            value = str(raw_value).strip()
            if not value:
                return
            cmd.extend([flag, value])

        add_path_option("--st-root", options.get("st_root"))
        add_text_option("--user-name", options.get("user_name"))

        plugins = options.get("plugins")
        if plugins:
            plugin_values = [str(item).strip() for item in plugins if str(item).strip()]
            if plugin_values:
                cmd.extend(["--plugins", ",".join(plugin_values)])

        add_text_option("--default-user-name", options.get("default_user_name"))

        if "default_st_root" in options:
            value = options.get("default_st_root")
            if value is not None:
                stripped = str(value).strip()
                cmd.extend(["--default-st-root", self.to_bash_path(stripped, git_bash_mode)])

        if "auto_check_on_start" in options and options.get("auto_check_on_start") is not None:
            flag_value = "1" if bool(options.get("auto_check_on_start")) else "0"
            cmd.extend(["--auto-check-on-start", flag_value])

        return cmd

    def extract_json_payload(self, stdout_text: str) -> dict[str, Any]:
        text = stdout_text.strip()
        candidates: list[str] = []
        if text:
            candidates.append(text)
            for line in reversed(text.splitlines()):
                stripped = line.strip()
                if stripped.startswith("{") and stripped.endswith("}"):
                    candidates.append(stripped)

        for candidate in candidates:
            try:
                parsed = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict):
                return parsed

        raise ApiError(
            code="script_invalid_json",
            message="脚本返回了无法解析的 JSON",
            details={"stdout": text[:2000]},
            status=502,
        )

    def map_script_error_status(self, code: str) -> int:
        if code in {"invalid_root", "root_not_found", "missing_argument", "missing_plugins", "invalid_plugins", "invalid_auto_check", "unknown_argument"}:
            return 400
        if code in {"unknown_command"}:
            return 404
        if code in {"git_missing"}:
            return 503
        if code in {"save_config_failed", "autostart_enable_failed", "autostart_disable_failed", "write_failed", "delete_failed"}:
            return 500
        return 502

    def run_script_json(self, command: str, **options: Any) -> dict[str, Any]:
        cmd = self.build_script_command(command, options)
        try:
            completed = subprocess.run(
                cmd,
                cwd=str(BASE_DIR),
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=options.get("timeout") or self.timeout,
                env=os.environ.copy(),
            )
        except subprocess.TimeoutExpired as exc:
            raise ApiError(
                code="script_timeout",
                message="调用底层脚本超时",
                details={"command": command, "timeout": exc.timeout},
                status=504,
            ) from exc
        except OSError as exc:
            raise ApiError(
                code="script_exec_failed",
                message="无法启动底层脚本",
                details=str(exc),
                status=500,
            ) from exc

        stdout_text = completed.stdout or ""
        stderr_text = (completed.stderr or "").strip()

        payload = self.extract_json_payload(stdout_text)
        if not payload.get("ok"):
            error = payload.get("error") or {}
            raise ApiError(
                code=str(error.get("code") or "script_error"),
                message=str(error.get("message") or "底层脚本执行失败"),
                details=error.get("details") or stderr_text or None,
                status=self.map_script_error_status(str(error.get("code") or "script_error")),
            )

        if completed.returncode != 0:
            raise ApiError(
                code="script_nonzero_exit",
                message="底层脚本返回了非零退出码",
                details={
                    "returncode": completed.returncode,
                    "stderr": stderr_text or None,
                    "payload": payload,
                },
                status=502,
            )

        return payload

    def load_name_overrides(self) -> dict[str, str]:
        if not self.overrides_path.exists():
            return {}
        try:
            with self.overrides_path.open("r", encoding="utf-8") as handle:
                raw = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return {}
        if not isinstance(raw, dict):
            return {}

        result: dict[str, str] = {}
        for key, value in raw.items():
            if not isinstance(key, str) or not isinstance(value, str):
                continue
            key = key.strip()
            value = value.strip()
            if key and value:
                result[key] = value
        return result

    def read_text_file(self, path: Path) -> str:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            return handle.read(MAX_METADATA_BYTES + 1)

    def is_preferred_display_name(self, value: str, directory_name: str) -> bool:
        candidate = value.strip()
        if not candidate:
            return False
        if candidate.lower() in {"plugin", "extension", "sillytavern", "readme"}:
            return False
        if candidate == directory_name:
            return False
        normalized_candidate = re.sub(r"[-_\s]+", "", candidate).lower()
        normalized_directory = re.sub(r"[-_\s]+", "", directory_name).lower()
        if normalized_candidate == normalized_directory and candidate.lower() == candidate and " " not in candidate:
            return False
        return True

    def walk_display_name_candidates(self, data: Any) -> list[str]:
        candidates: list[str] = []
        if isinstance(data, dict):
            for key in DISPLAY_NAME_KEYS:
                value = data.get(key)
                if isinstance(value, str) and value.strip():
                    candidates.append(value.strip())
            for key in NESTED_METADATA_KEYS:
                value = data.get(key)
                if isinstance(value, (dict, list)):
                    candidates.extend(self.walk_display_name_candidates(value))
            for value in data.values():
                if isinstance(value, (dict, list)):
                    candidates.extend(self.walk_display_name_candidates(value))
        elif isinstance(data, list):
            for item in data:
                candidates.extend(self.walk_display_name_candidates(item))
        return candidates

    def extract_display_name_from_json(self, file_path: Path, directory_name: str) -> str | None:
        try:
            text = self.read_text_file(file_path)
        except OSError:
            return None
        if len(text) > MAX_METADATA_BYTES:
            return None
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            return None
        for candidate in self.walk_display_name_candidates(parsed):
            if self.is_preferred_display_name(candidate, directory_name):
                return candidate.strip()
        return None

    def extract_display_name_from_readme(self, file_path: Path, directory_name: str) -> str | None:
        try:
            text = self.read_text_file(file_path)
        except OSError:
            return None
        if len(text) > MAX_METADATA_BYTES:
            return None
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            match = re.match(r"^#{1,3}\s+(.+?)\s*$", stripped)
            if not match:
                continue
            heading = match.group(1).strip()
            if self.is_preferred_display_name(heading, directory_name):
                return heading
            break
        return None

    def resolve_display_name(self, directory_name: str, plugin_path: str) -> tuple[str, str, str | None]:
        overrides = self.load_name_overrides()
        path = Path(plugin_path) if plugin_path else None
        metadata_candidates = [
            Path("manifest.json"),
            Path("plugin.json"),
            Path("extension.json"),
            Path("package.json"),
            Path("dist/manifest.json"),
            Path("src/manifest.json"),
        ]
        readme_candidates = [Path("README.md"), Path("readme.md")]

        if path and path.exists() and path.is_dir():
            for relative_path in metadata_candidates:
                absolute_path = path / relative_path
                if not absolute_path.exists() or not absolute_path.is_file():
                    continue
                display_name = self.extract_display_name_from_json(absolute_path, directory_name)
                if display_name:
                    return display_name, "metadata", str(relative_path)

            for relative_path in readme_candidates:
                absolute_path = path / relative_path
                if not absolute_path.exists() or not absolute_path.is_file():
                    continue
                display_name = self.extract_display_name_from_readme(absolute_path, directory_name)
                if display_name:
                    return display_name, "metadata", str(relative_path)

        override_name = overrides.get(directory_name, "").strip()
        if override_name:
            return override_name, "override", self.overrides_path.name

        return directory_name, "directory", None

    def enrich_plugin(self, plugin: dict[str, Any]) -> dict[str, Any]:
        directory_name = str(plugin.get("name") or "").strip()
        plugin_path = str(plugin.get("path") or "").strip()
        display_name, display_name_source, display_name_detail = self.resolve_display_name(directory_name, plugin_path)
        status = str(plugin.get("status") or "up_to_date")
        source = str(plugin.get("source") or "")
        reason = str(plugin.get("reason") or STATUS_LABELS.get(status, ""))

        return {
            "display_name": display_name,
            "display_name_source": display_name_source,
            "display_name_detail": display_name_detail,
            "directory_name": directory_name,
            "source": source,
            "source_label": SOURCE_LABELS.get(source, source or "未知来源"),
            "status": status,
            "status_label": STATUS_LABELS.get(status, status),
            "reason": reason,
            "path": plugin_path,
            "whitelisted": bool(plugin.get("whitelisted")),
            "remote": plugin.get("remote"),
            "upstream": plugin.get("upstream"),
            "local_ahead": int(plugin.get("local_ahead") or 0),
            "remote_ahead": int(plugin.get("remote_ahead") or 0),
        }

    def enrich_plugins(self, plugins: list[dict[str, Any]], sort_result: bool) -> list[dict[str, Any]]:
        items = [self.enrich_plugin(item) for item in plugins]
        if sort_result:
            items.sort(key=lambda item: (item["display_name"].lower(), item["directory_name"].lower()))
        return items

    def build_summary(self, raw_summary: dict[str, Any], plugins: list[dict[str, Any]]) -> dict[str, Any]:
        by_source = {"public": 0, "user": 0}
        for plugin in plugins:
            source = plugin.get("source")
            if source in by_source:
                by_source[source] += 1
            else:
                by_source[source] = by_source.get(source, 0) + 1

        total = int(raw_summary.get("total") or len(plugins))
        return {
            "total": total,
            "updatable": int(raw_summary.get("updatable") or 0),
            "up_to_date": int(raw_summary.get("up_to_date") or 0),
            "skipped": int(raw_summary.get("skipped") or 0),
            "failed": int(raw_summary.get("failed") or 0),
            "by_status": raw_summary.get("by_status") or {},
            "by_source": by_source,
        }

    def normalize_context_options(self, source: dict[str, Any]) -> dict[str, Any]:
        return {
            "st_root": str(source.get("st_root") or "").strip() or None,
            "user_name": str(source.get("user_name") or "").strip() or None,
        }

    def normalize_plugin_names(self, source: Any) -> list[str]:
        if isinstance(source, str):
            return [item.strip() for item in source.split(",") if item.strip()]
        if isinstance(source, list):
            result: list[str] = []
            for item in source:
                text = str(item).strip()
                if text and text not in result:
                    result.append(text)
            return result
        return []

    def get_overview(self, params: dict[str, Any]) -> dict[str, Any]:
        context_options = self.normalize_context_options(params)
        status_payload = self.run_script_json("status", **context_options)
        settings_payload = self.run_script_json("settings-get")
        whitelist_payload = self.run_script_json("whitelist-get")

        plugins = self.enrich_plugins(status_payload.get("plugins") or [], sort_result=True)
        summary = self.build_summary(status_payload.get("summary") or {}, plugins)

        return {
            "context": status_payload.get("context") or {},
            "summary": summary,
            "plugins": plugins,
            "whitelist": whitelist_payload.get("items") or [],
            "settings": settings_payload.get("settings") or {},
            "status_catalog": [
                {"value": key, "label": label} for key, label in STATUS_LABELS.items()
            ],
            "source_catalog": [
                {"value": key, "label": label} for key, label in SOURCE_LABELS.items()
            ],
            "name_override_file": self.overrides_path.name,
        }

    def update_all(self, params: dict[str, Any]) -> dict[str, Any]:
        context_options = self.normalize_context_options(params)
        payload = self.run_script_json("update-all", **context_options)
        return {
            "context": payload.get("context") or {},
            "summary": payload.get("summary") or {},
            "status_overview": payload.get("status_overview") or {},
            "results": self.enrich_plugins(payload.get("results") or [], sort_result=False),
        }

    def update_selected(self, params: dict[str, Any]) -> dict[str, Any]:
        context_options = self.normalize_context_options(params)
        plugins = self.normalize_plugin_names(params.get("plugins"))
        if not plugins:
            raise ApiError("missing_plugins", "请至少传入一个插件目录名", status=400)
        payload = self.run_script_json("update-selected", plugins=plugins, **context_options)
        return {
            "context": payload.get("context") or {},
            "requested_plugins": payload.get("requested_plugins") or plugins,
            "missing_plugins": payload.get("missing_plugins") or [],
            "summary": payload.get("summary") or {},
            "status_overview": payload.get("status_overview") or {},
            "results": self.enrich_plugins(payload.get("results") or [], sort_result=False),
        }

    def get_whitelist(self) -> dict[str, Any]:
        payload = self.run_script_json("whitelist-get")
        return {"items": payload.get("items") or []}

    def update_whitelist(self, params: dict[str, Any]) -> dict[str, Any]:
        action = str(params.get("action") or "").strip().lower()
        plugins = self.normalize_plugin_names(params.get("plugins"))
        if action not in {"add", "remove"}:
            raise ApiError("invalid_action", "白名单操作只能是 add 或 remove", status=400)
        if not plugins:
            raise ApiError("missing_plugins", "请至少传入一个插件目录名", status=400)
        command = "whitelist-add" if action == "add" else "whitelist-remove"
        payload = self.run_script_json(command, plugins=plugins)
        return {
            "action": action,
            "results": payload.get("results") or [],
            "items": payload.get("items") or [],
        }

    def delete_plugins(self, params: dict[str, Any]) -> dict[str, Any]:
        context_options = self.normalize_context_options(params)
        plugins = self.normalize_plugin_names(params.get("plugins"))
        if not plugins:
            raise ApiError("missing_plugins", "请至少传入一个插件目录名", status=400)
        payload = self.run_script_json("delete", plugins=plugins, **context_options)
        return {
            "context": payload.get("context") or {},
            "requested_plugins": payload.get("requested_plugins") or plugins,
            "missing_plugins": payload.get("missing_plugins") or [],
            "summary": payload.get("summary") or {},
            "results": self.enrich_plugins(payload.get("results") or [], sort_result=False),
        }

    def get_settings(self) -> dict[str, Any]:
        payload = self.run_script_json("settings-get")
        return {"settings": payload.get("settings") or {}}

    def save_settings(self, params: dict[str, Any]) -> dict[str, Any]:
        payload = self.run_script_json(
            "settings-save",
            default_user_name=params.get("default_user_name"),
            default_st_root=params.get("default_st_root"),
            auto_check_on_start=params.get("auto_check_on_start"),
        )
        return {
            "settings": payload.get("settings") or {},
            "shell_updated": bool(payload.get("shell_updated")),
            "termux_environment": bool(payload.get("termux_environment")),
        }


class PanelHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], handler_class: type[BaseHTTPRequestHandler], app: WebPanelApp) -> None:
        super().__init__(server_address, handler_class)
        self.app = app


class PanelRequestHandler(BaseHTTPRequestHandler):
    server_version = "SillyTavernWebPanel/0.1"

    @property
    def app(self) -> WebPanelApp:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    def do_GET(self) -> None:
        try:
            parsed = urlparse(self.path)
            if parsed.path.startswith("/api/"):
                self.handle_api_get(parsed)
            else:
                self.handle_static_get(parsed.path)
        except ApiError as exc:
            self.send_json(exc.status, exc.to_payload())
        except Exception as exc:  # noqa: BLE001
            self.send_json(
                500,
                {
                    "ok": False,
                    "error": {
                        "code": "internal_error",
                        "message": "服务器内部错误",
                        "details": str(exc),
                    },
                },
            )

    def do_POST(self) -> None:
        try:
            parsed = urlparse(self.path)
            if not parsed.path.startswith("/api/"):
                raise ApiError("not_found", "接口不存在", status=404)
            self.handle_api_post(parsed)
        except ApiError as exc:
            self.send_json(exc.status, exc.to_payload())
        except Exception as exc:  # noqa: BLE001
            self.send_json(
                500,
                {
                    "ok": False,
                    "error": {
                        "code": "internal_error",
                        "message": "服务器内部错误",
                        "details": str(exc),
                    },
                },
            )

    def parse_json_body(self) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        if content_length > MAX_REQUEST_BODY:
            raise ApiError("payload_too_large", "请求体过大", status=413)
        raw = self.rfile.read(content_length) if content_length > 0 else b"{}"
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ApiError("invalid_json", "请求体不是合法 JSON", details=str(exc), status=400) from exc
        if not isinstance(data, dict):
            raise ApiError("invalid_json", "请求体必须是 JSON 对象", status=400)
        return data

    def send_json(self, status_code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_success(self, data: dict[str, Any], status_code: int = 200) -> None:
        self.send_json(status_code, {"ok": True, "data": data})

    def handle_api_get(self, parsed: Any) -> None:
        route = parsed.path
        query = {key: values[-1] for key, values in parse_qs(parsed.query, keep_blank_values=True).items()}

        if route in {"/api/overview", "/api/plugins"}:
            self.send_success(self.app.get_overview(query))
            return
        if route == "/api/whitelist":
            self.send_success(self.app.get_whitelist())
            return
        if route == "/api/settings":
            self.send_success(self.app.get_settings())
            return
        if route == "/api/health":
            self.send_success({"status": "ok"})
            return

        raise ApiError("not_found", "接口不存在", status=404)

    def handle_api_post(self, parsed: Any) -> None:
        route = parsed.path
        payload = self.parse_json_body()

        if route == "/api/update-all":
            self.send_success(self.app.update_all(payload))
            return
        if route == "/api/update-selected":
            self.send_success(self.app.update_selected(payload))
            return
        if route == "/api/whitelist":
            self.send_success(self.app.update_whitelist(payload))
            return
        if route == "/api/delete":
            self.send_success(self.app.delete_plugins(payload))
            return
        if route == "/api/settings":
            self.send_success(self.app.save_settings(payload))
            return

        raise ApiError("not_found", "接口不存在", status=404)

    def handle_static_get(self, request_path: str) -> None:
        normalized_path = request_path or "/"
        if normalized_path == "/":
            target = self.app.web_dir / "index.html"
        else:
            relative = normalized_path.lstrip("/")
            target = (self.app.web_dir / relative).resolve()
            web_root = self.app.web_dir.resolve()
            if web_root not in target.parents and target != web_root:
                raise ApiError("not_found", "文件不存在", status=404)

        if not target.exists() or not target.is_file():
            raise ApiError("not_found", "文件不存在", status=404)

        content = target.read_bytes()
        content_type, _ = mimetypes.guess_type(str(target))
        if not content_type:
            content_type = "application/octet-stream"
        if content_type.startswith("text/") or content_type in {"application/javascript", "application/json"}:
            content_type = f"{content_type}; charset=utf-8"

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SillyTavern 扩展本地 Web 面板")
    parser.add_argument("--host", default=DEFAULT_HOST, help="监听地址，默认 127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="监听端口，默认 8765")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="底层脚本调用超时秒数，默认 900")
    parser.add_argument("--bash", default=os.environ.get("ST_MANAGER_BASH", ""), help="可选：指定 bash 可执行文件路径")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app = WebPanelApp(host=args.host, port=args.port, timeout=args.timeout, preferred_bash=args.bash)
    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
