import unittest
from datetime import datetime, timezone
import os
import stat
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request

sys.path.insert(0, str(Path(__file__).parents[1]))
from importlib.machinery import SourceFileLoader

module = SourceFileLoader("omakanvas", str(Path(__file__).parents[1] / "omakanvas")).load_module()


class FakeClient:
    base_url = "https://canvas.test/"

    def get_all(self, path, params=None):
        if path == "api/v1/courses":
            if params["enrollment_type"] != "student":
                return []
            return [{"id": 1, "name": "Software Engineering", "course_code": "CSC3400",
                     "enrollments": [{"type": "student", "computed_current_score": 95.5}]}]
        return [{"id": 2, "name": "In range", "due_at": "2026-09-01T15:00:00Z",
                 "submission": {"submitted_at": None}, "locked_for_user": True,
                 "unlock_at": "2026-08-30T12:00:00Z",
                 "html_url": "https://canvas.test/a/2"},
                {"id": 3, "name": "Too late", "due_at": "2026-09-20T15:00:00Z", "submission": {}}]


class AnnouncementClient:
    base_url = "https://canvas.test/"

    def __init__(self, topics=None, error=None, conversations=None,
                 conversation_error=None, discussions=None,
                 discussion_error=None):
        self.topics = topics if topics is not None else []
        self.error = error
        self.conversation_records = conversations if conversations is not None else []
        self.conversation_error = conversation_error
        self.discussion_records = discussions if discussions is not None else []
        self.discussion_error = discussion_error
        self.requested_paths = []
        self.requested_params = []

    def get_all(self, path, params=None):
        self.requested_paths.append(path)
        self.requested_params.append(params)
        if path == "api/v1/courses":
            return [{"id": 7, "name": "Biology", "course_code": "BIO101",
                     "enrollments": [{"type": "student"}]}]
        if path == "api/v1/courses/7/discussion_topics":
            if (params or {}).get("only_announcements") == "true":
                if self.error is not None:
                    raise self.error
                return self.topics
            if self.discussion_error is not None:
                raise self.discussion_error
            return self.discussion_records
        if path == "api/v1/conversations":
            if self.conversation_error is not None:
                raise self.conversation_error
            return self.conversation_records
        return []


class MixedRoleClient:
    base_url = "https://canvas.test/"

    def __init__(self):
        self.requested_paths = []
        self.requested_params = []

    def get_all(self, path, params=None):
        self.requested_paths.append(path)
        self.requested_params.append(params)
        if path == "api/v1/courses":
            return [
                {"id": 10, "name": "Course I Teach",
                 "needs_grading_count": 3,
                 "enrollments": [{"type": "teacher"}]},
                {"id": 20, "name": "Course I Take",
                 "enrollments": [{"type": "StudentEnrollment", "computed_current_grade": "A"}]},
            ]
        return []


class TeacherClient:
    base_url = "https://canvas.test/"

    def __init__(self):
        self.requests = []

    def get_all(self, path, params=None):
        self.requests.append((path, params))
        if path == "api/v1/courses":
            if params["enrollment_type"] != "teacher":
                return []
            return [{
                "id": 30,
                "name": "Human Computer Interaction",
                "course_code": "CSC4400",
                "workflow_state": "available",
                "needs_grading_count": 7,
                "enrollments": [{"type": "TeacherEnrollment"}],
            }]
        return [
            {
                "id": 31,
                "name": "Prototype Review",
                "due_at": "2026-09-01T15:00:00Z",
                "all_dates": [
                    {"due_at": "2026-08-20T15:00:00Z"},
                    {"title": "Section One", "due_at": "2026-09-01T15:00:00Z",
                     "unlock_at": "2026-08-30T12:00:00Z"},
                    {"title": "Section Two", "due_at": "2026-09-03T15:00:00Z",
                     "unlock_at": "2026-08-31T12:00:00Z"},
                ],
                "published": False,
                "html_url": "https://canvas.test/courses/30/assignments/31",
            },
            {
                "id": 32,
                "name": "Too late",
                "due_at": "2026-09-20T15:00:00Z",
                "published": True,
            },
        ]


class PermissionLimitedClient:
    base_url = "https://canvas.test/"

    def get_all(self, path, params=None):
        if path == "api/v1/courses" and params["enrollment_type"] == "teacher":
            raise module.CanvasPermissionError("Canvas denied access to teaching data")
        return []


class FakeResponse:
    def __init__(self, payload, link=None, raw=None):
        self.raw = raw if raw is not None else module.json.dumps(payload).encode("utf-8")
        self.headers = {"Link": link} if link else {}

    def read(self, limit=-1):
        return self.raw if limit < 0 else self.raw[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


class FakeOpener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        if not self.responses:
            raise AssertionError("Unexpected API request")
        return self.responses.pop(0)


class RaisingOpener:
    def __init__(self, error):
        self.error = error

    def open(self, _request, timeout=None):
        raise self.error


class CanvasTests(unittest.TestCase):
    def test_normalizes_canvas_url(self):
        self.assertEqual(
            module.normalize_instance_url(" HTTPS://Canvas.Example.EDU/ "),
            "https://canvas.example.edu",
        )

    def test_rejects_malformed_canvas_url(self):
        for value in (
            "canvas.example.edu",
            "not a url",
            "http://canvas.example.edu",
            "ftp://canvas.example.edu",
            "https://user:password@canvas.example.edu",
            "https://canvas.example.edu/courses/123",
            "https://canvas.example.edu?account=1",
            "https://canvas.example.edu#settings",
            "https://canvas.example.edu:invalid",
        ):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                module.normalize_instance_url(value)

    def test_reads_canvas_base_url_from_omarchy_bar_setting(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "shell.json"
            path.write_text(module.json.dumps({
                "bar": {
                    "layout": {
                        "left": [],
                        "center": [],
                        "right": [{
                            "id": "io.github.erikwb.omakanvas",
                            "baseUrl": "https://Canvas.Example.EDU/",
                        }],
                    },
                },
            }), encoding="utf-8")

            self.assertEqual(
                module.configured_canvas_base_url(path),
                "https://canvas.example.edu",
            )

    def test_resolves_configured_canvas_base_url_when_no_override_exists(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "shell.json"
            path.write_text(module.json.dumps({
                "bar": {"layout": {"right": [{
                    "id": "io.github.erikwb.omakanvas",
                    "baseUrl": "https://canvas.example.edu",
                }]}},
            }), encoding="utf-8")
            with patch.dict(os.environ, {"CANVAS_BASE_URL": ""}):
                self.assertEqual(
                    module.resolve_base_url(config_path=path),
                    "https://canvas.example.edu",
                )

    def test_explicit_canvas_base_url_precedes_environment_and_bar_setting(self):
        with patch.dict(os.environ, {"CANVAS_BASE_URL": "https://environment.example"}):
            self.assertEqual(
                module.resolve_base_url(
                    "https://argument.example", Path("/does/not/need/to/exist"),
                ),
                "https://argument.example",
            )

    def test_missing_configured_canvas_base_url_has_actionable_error(self):
        with TemporaryDirectory() as directory, \
             patch.dict(os.environ, {"CANVAS_BASE_URL": ""}):
            with self.assertRaisesRegex(RuntimeError, "omarchy bar set"):
                module.resolve_base_url(config_path=Path(directory) / "missing.json")

    def test_sanitizes_canvas_text_for_ui_and_terminal_output(self):
        self.assertEqual(
            module.sanitize_text("&lt;img src='https://attacker.example/pixel'&gt;\x1b[31m"),
            "<img src='https://attacker.example/pixel'> [31m",
        )
        self.assertEqual(module.sanitize_text(None, "Untitled"), "Untitled")

    def test_validates_canvas_assignment_web_url(self):
        self.assertEqual(
            module.validated_canvas_web_url(
                "https://canvas.example.edu",
                "/courses/10/assignments/20",
            ),
            "https://canvas.example.edu/courses/10/assignments/20",
        )

    def test_rejects_external_or_unsafe_assignment_web_url(self):
        for value in (
            "https://attacker.example/collect",
            "http://canvas.example.edu/courses/10/assignments/20",
            "javascript:alert(1)",
            "https://canvas.example.edu/courses/10/assignments/20\nfile:///etc/passwd",
            None,
        ):
            with self.subTest(value=value):
                self.assertIsNone(
                    module.validated_canvas_web_url("https://canvas.example.edu", value)
                )

    def test_builds_canvas_course_web_url(self):
        self.assertEqual(
            module.canvas_course_web_url("https://canvas.example.edu", 12345),
            "https://canvas.example.edu/courses/12345",
        )

    def test_rejects_invalid_canvas_course_id_for_web_url(self):
        for value in (True, "", "../account", "12/assignments"):
            with self.subTest(value=value):
                self.assertIsNone(
                    module.canvas_course_web_url("https://canvas.example.edu", value)
                )

    def test_missing_credentials_return_none(self):
        with patch.dict(os.environ, {"CANVAS_API_KEY": "environment-token"}), \
             patch.object(module, "_keyring_token", return_value=None):
            self.assertIsNone(module.get_token("https://canvas.example.edu"))

    def test_environment_token_requires_explicit_opt_in(self):
        with patch.dict(os.environ, {"CANVAS_API_KEY": "from-environment"}), \
             patch.object(module, "_keyring_token") as keyring:
            self.assertEqual(
                module.get_token("https://canvas.example.edu", token_from_environment=True),
                "from-environment",
            )
            keyring.assert_not_called()

    def test_environment_token_does_not_override_scoped_keyring(self):
        with patch.dict(os.environ, {"CANVAS_API_KEY": "wrong-instance-token"}), \
             patch.object(module, "_keyring_token", return_value="scoped-token"):
            self.assertEqual(
                module.get_token("https://canvas.example.edu"),
                "scoped-token",
            )

    def test_keyring_lookup_is_scoped_to_canvas_url(self):
        completed = Mock(stdout="saved-token\n")
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run", return_value=completed) as run:
            self.assertEqual(module._keyring_token("https://canvas.example.edu/"), "saved-token")
            self.assertEqual(
                run.call_args.args[0],
                ["/usr/bin/secret-tool", "lookup", "service", "omakanvas", "base_url", "https://canvas.example.edu"],
            )

    def test_keyring_failure_has_actionable_error(self):
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run", side_effect=OSError("keyring unavailable")):
            with self.assertRaisesRegex(RuntimeError, "system keyring"):
                module._keyring_token("https://canvas.example.edu")

    def test_save_token_is_scoped_to_canvas_url(self):
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run") as run:
            module.save_token("https://canvas.example.edu/", "secret-token")
            self.assertEqual(
                run.call_args.args[0],
                ["/usr/bin/secret-tool", "store", "--label=Omakanvas API token (canvas.example.edu)",
                 "service", "omakanvas", "base_url", "https://canvas.example.edu"],
            )
            self.assertEqual(run.call_args.kwargs["input"], "secret-token\n")

    def test_save_token_failure_has_actionable_error(self):
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run", side_effect=OSError("keyring unavailable")):
            with self.assertRaisesRegex(RuntimeError, "Could not save"):
                module.save_token("https://canvas.example.edu", "secret-token")

    def test_clear_token_checks_keyring_exit_status(self):
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run") as run:
            module.clear_token("https://canvas.example.edu")
            self.assertTrue(run.call_args.kwargs["check"])
            self.assertEqual(run.call_args.kwargs["timeout"], 10)

    def test_clear_token_failure_is_not_reported_as_success(self):
        failure = module.subprocess.CalledProcessError(1, ["secret-tool", "clear"])
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run", side_effect=failure):
            with self.assertRaisesRegex(RuntimeError, "Could not remove"):
                module.clear_token("https://canvas.example.edu")

    def test_browser_session_keyring_is_separate_and_scoped_to_canvas_url(self):
        completed = Mock(stdout="browser-session\n")
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run", return_value=completed) as run:
            self.assertEqual(
                module._keyring_browser_session("https://canvas.example.edu/"),
                module.BrowserSession(
                    "https://canvas.example.edu", "browser-session",
                ),
            )
            self.assertEqual(
                run.call_args.args[0],
                ["/usr/bin/secret-tool", "lookup", "service",
                 "omakanvas-browser-session", "base_url", "https://canvas.example.edu"],
            )

    def test_saves_browser_session_and_validated_api_base_url_in_keyring(self):
        with patch.object(module, "secret_tool_path", return_value="/usr/bin/secret-tool"), \
             patch.object(module.subprocess, "run") as run:
            module.save_browser_session(
                "https://canvas.example.edu/", "signed-session-value",
                "https://school.instructure.com/",
            )
            self.assertEqual(
                run.call_args.args[0],
                ["/usr/bin/secret-tool", "store",
                 "--label=Omakanvas browser session (school.instructure.com)",
                 "service", "omakanvas-browser-session", "base_url",
                 "https://canvas.example.edu"],
            )
            self.assertEqual(
                module.json.loads(run.call_args.kwargs["input"]),
                {
                    "version": 1,
                    "base_url": "https://school.instructure.com",
                    "canvas_session": "signed-session-value",
                },
            )

    def test_reads_versioned_browser_session_with_stored_base_url(self):
        value = module.json.dumps({
            "version": 1,
            "base_url": "https://school.instructure.com/",
            "canvas_session": "signed-session",
        })
        self.assertEqual(
            module._decode_browser_session(value, "https://canvas.example.edu"),
            module.BrowserSession(
                "https://school.instructure.com", "signed-session",
            ),
        )

    def test_reads_legacy_bare_browser_session_with_lookup_base_url(self):
        self.assertEqual(
            module._decode_browser_session(
                "legacy-session", "https://canvas.example.edu/",
            ),
            module.BrowserSession(
                "https://canvas.example.edu", "legacy-session",
            ),
        )

    def test_rejects_unsafe_browser_session_value(self):
        for value in ("", "value; another=cookie", "value\r\nInjected: header"):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "invalid"):
                module._validate_browser_session(value)

    def test_browser_session_takes_precedence_over_saved_token(self):
        with patch.object(
            module,
            "_keyring_browser_session",
            return_value=module.BrowserSession(
                "https://canvas.example.edu", "session",
            ),
        ), \
             patch.object(module, "get_token", return_value="token") as get_token:
            self.assertEqual(
                module.get_credential("https://canvas.example.edu"),
                ("browser_session", "session", "https://canvas.example.edu"),
            )
            get_token.assert_not_called()

    def test_environment_token_explicitly_overrides_browser_session(self):
        with patch.object(module, "_keyring_browser_session") as browser_session, \
             patch.object(module, "get_token", return_value="environment-token"):
            self.assertEqual(
                module.get_credential(
                    "https://canvas.example.edu", token_from_environment=True,
                ),
                ("token", "environment-token", "https://canvas.example.edu"),
            )
            browser_session.assert_not_called()

    def test_browser_credential_uses_stored_api_base_url(self):
        with patch.object(
            module,
            "_keyring_browser_session",
            return_value=module.BrowserSession(
                "https://school.instructure.com", "session",
            ),
        ):
            self.assertEqual(
                module.get_credential("https://canvas.example.edu"),
                ("browser_session", "session", "https://school.instructure.com"),
            )

    def test_collects_https_origins_from_browser_pages(self):
        targets = [
            {"type": "page", "url": "https://login.example.edu/sso"},
            {"type": "page", "url": "https://school.instructure.com/dashboard"},
            {"type": "worker", "url": "https://ignored.example/worker.js"},
            {"type": "page", "url": "http://insecure.example/dashboard"},
        ]
        self.assertEqual(
            module._browser_target_origins(
                targets, "https://canvas.example.edu/",
            ),
            [
                "https://canvas.example.edu",
                "https://login.example.edu",
                "https://school.instructure.com",
            ],
        )

    def test_selects_only_applicable_secure_canvas_session_cookie(self):
        cookies = [
            {"name": "canvas_session", "value": "external", "domain": "attacker.test",
             "path": "/", "secure": True, "expires": -1},
            {"name": "canvas_session", "value": "expired", "domain": ".example.edu",
             "path": "/", "secure": True, "expires": 99},
            {"name": "canvas_session", "value": "parent", "domain": ".example.edu",
             "path": "/", "secure": True, "expires": -1},
            {"name": "canvas_session", "value": "exact", "domain": "canvas.example.edu",
             "path": "/", "secure": True, "expires": -1},
            {"name": "analytics", "value": "ignored", "domain": "canvas.example.edu",
             "path": "/", "secure": True, "expires": -1},
        ]
        self.assertEqual(
            module._canvas_session_from_cookies(
                cookies, "https://canvas.example.edu", now=100,
            ),
            "exact",
        )

    def test_rejects_insecure_canvas_session_cookie(self):
        self.assertIsNone(module._canvas_session_from_cookies(
            [{"name": "canvas_session", "value": "session",
              "domain": "canvas.example.edu", "path": "/", "secure": False}],
            "https://canvas.example.edu",
        ))

    def test_devtools_pipe_sends_commands_and_ignores_events(self):
        response_read, response_write = os.pipe()
        command_read, command_write = os.pipe()
        os.write(
            response_write,
            b'{"method":"Target.targetCreated"}\0'
            b'{"id":1,"result":{"cookies":[]}}\0',
        )
        os.close(response_write)
        connection = module.DevToolsPipe(response_read, command_write)
        try:
            self.assertEqual(
                connection.command("Network.getCookies", {"urls": ["https://canvas.test"]}),
                {"cookies": []},
            )
            sent = os.read(command_read, 4096)
            self.assertTrue(sent.endswith(b"\0"))
            self.assertEqual(
                module.json.loads(sent[:-1]),
                {"id": 1, "method": "Network.getCookies",
                 "params": {"urls": ["https://canvas.test"]}},
            )
        finally:
            connection.close()
            os.close(command_read)

    def test_browser_session_client_sends_cookie_without_bearer_token(self):
        opener = FakeOpener(FakeResponse([]))
        client = module.CanvasClient(
            "https://canvas.example.edu", browser_session="signed-session",
            opener=opener, clock=lambda: 0,
        )

        client.get_all("api/v1/courses")

        headers = dict(opener.requests[0].header_items())
        self.assertEqual(headers["Cookie"], "canvas_session=signed-session")
        self.assertNotIn("Authorization", headers)

    def test_browser_session_authentication_error_is_actionable(self):
        error = HTTPError(
            "https://canvas.example.edu/api/v1/courses", 401, "failure", {}, None,
        )
        client = module.CanvasClient(
            "https://school.instructure.com", browser_session="expired-session",
            login_base_url="https://canvas.example.edu",
            opener=RaisingOpener(error), clock=lambda: 0,
        )
        with self.assertRaisesRegex(
            module.CanvasAuthenticationError,
            "login --base-url https://canvas.example.edu",
        ):
            client.get_all("api/v1/courses")

    def test_browser_login_cancel_handler_reports_cancellation(self):
        with self.assertRaisesRegex(RuntimeError, "cancelled"):
            module._cancel_browser_login(module.signal.SIGTERM, None)

    def test_browser_login_restores_sigterm_handler_on_failure(self):
        before = module.signal.getsignal(module.signal.SIGTERM)
        with patch.object(
            module, "_start_browser", side_effect=RuntimeError("no browser"),
        ):
            with self.assertRaisesRegex(RuntimeError, "no browser"):
                module.browser_login("https://canvas.example.edu")
        self.assertEqual(module.signal.getsignal(module.signal.SIGTERM), before)

    def test_browser_login_cancel_stops_browser_and_cleans_up(self):
        import os as os_module
        import threading as threading_module

        class FakeProcess:
            def __init__(self):
                self.terminated = False
                self.killed = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

            def kill(self):
                self.killed = True

            def wait(self, timeout=None):
                return 0

        class FakeConnection:
            def __init__(self):
                self.closed = False

            def command(self, method, params=None, session_id=None):
                if method == "Target.getTargets":
                    return {"targetInfos": [{
                        "type": "page", "targetId": "target-1",
                        "url": "https://canvas.example.edu/login",
                    }]}
                if method == "Target.attachToTarget":
                    return {"sessionId": "session-1"}
                return {"cookies": []}

            def close(self):
                self.closed = True

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        process = FakeProcess()
        connection = FakeConnection()
        before = module.signal.getsignal(module.signal.SIGTERM)
        timer = threading_module.Timer(
            0.2, os_module.kill, args=(os_module.getpid(), module.signal.SIGTERM),
        )
        with patch.object(
            module, "_start_browser", return_value=(process, connection),
        ), patch.object(
            module, "_browser_session_is_authenticated", return_value=False,
        ):
            timer.start()
            try:
                with self.assertRaisesRegex(RuntimeError, "cancelled"):
                    module.browser_login("https://canvas.example.edu")
            finally:
                timer.cancel()
        self.assertTrue(process.terminated)
        self.assertTrue(connection.closed)
        self.assertEqual(module.signal.getsignal(module.signal.SIGTERM), before)

    def test_collects_only_assignments_in_window(self):
        data = module.collect(FakeClient(), 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        student = data["roles"]["student"]
        self.assertEqual(data["schema_version"], 5)
        self.assertEqual(len(student["courses"]), 1)
        self.assertEqual([a["name"] for a in student["courses"][0]["assignments"]], ["In range"])
        self.assertEqual(
            student["courses"][0]["assignments"][0]["html_url"],
            "https://canvas.test/a/2",
        )
        self.assertEqual(
            student["courses"][0]["html_url"],
            "https://canvas.test/courses/1",
        )
        assignment = student["courses"][0]["assignments"][0]
        self.assertTrue(assignment["locked_for_user"])
        self.assertEqual(assignment["unlock_at"], "2026-08-30T12:00:00+00:00")
        self.assertFalse(data["roles"]["teacher"]["available"])

    def test_collects_teacher_courses_dates_status_and_grading_count(self):
        client = TeacherClient()
        data = module.collect(
            client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
        )
        teacher = data["roles"]["teacher"]
        course = teacher["courses"][0]
        assignment = course["assignments"][0]

        self.assertTrue(teacher["available"])
        self.assertEqual(course["needs_grading_count"], 7)
        self.assertEqual(course["workflow_state"], "available")
        self.assertEqual(assignment["name"], "Prototype Review")
        self.assertEqual(
            assignment["due_dates"],
            ["2026-09-01T15:00:00+00:00", "2026-09-03T15:00:00+00:00"],
        )
        self.assertEqual(len(assignment["availability_schedules"]), 2)
        self.assertEqual(
            assignment["availability_schedules"][0]["unlock_at"],
            "2026-08-30T12:00:00+00:00",
        )
        self.assertFalse(assignment["published"])
        teacher_course_request = next(
            params for path, params in client.requests
            if path == "api/v1/courses" and params["enrollment_type"] == "teacher"
        )
        assignment_request = next(
            params for path, params in client.requests
            if path == "api/v1/courses/30/assignments"
        )
        self.assertEqual(teacher_course_request["include[]"], ["needs_grading_count"])
        self.assertEqual(assignment_request["include[]"], ["all_dates"])

    def test_teacher_permission_failure_does_not_discard_student_role(self):
        data = module.collect(
            PermissionLimitedClient(), 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
        )

        self.assertEqual(data["roles"]["student"]["error"], "")
        self.assertEqual(
            data["roles"]["teacher"]["error"],
            "Canvas denied access to teaching data",
        )

    def test_next_link(self):
        self.assertEqual(module._next_link('<https://canvas.test/p2>; rel="next"'), "https://canvas.test/p2")

    def test_accepts_same_origin_pagination_link(self):
        self.assertEqual(
            module._require_same_origin(
                "https://canvas.example.edu/",
                "https://canvas.example.edu/api/v1/courses?page=2",
            ),
            "https://canvas.example.edu/api/v1/courses?page=2",
        )

    def test_rejects_cross_origin_pagination_link(self):
        with self.assertRaisesRegex(module.CrossOriginRequestError, "outside"):
            module._require_same_origin(
                "https://canvas.example.edu/",
                "https://attacker.example/api/v1/courses?page=2",
            )

    def test_rejects_cross_origin_redirect_before_copying_headers(self):
        handler = module.SameOriginRedirectHandler("https://canvas.example.edu/")
        request = Request(
            "https://canvas.example.edu/api/v1/courses",
            headers={"Authorization": "Bearer secret-token"},
        )
        with self.assertRaises(module.CrossOriginRequestError):
            handler.redirect_request(
                request, None, 302, "Found", {},
                "https://attacker.example/collect",
            )

    def test_rejects_oversized_api_response(self):
        response = FakeResponse([], raw=b"[" + b" " * 20 + b"]")
        with patch.object(module, "MAX_RESPONSE_BYTES", 10):
            client = module.CanvasClient(
                "https://canvas.example.edu", "token",
                opener=FakeOpener(response), clock=lambda: 0,
            )
            with self.assertRaisesRegex(RuntimeError, "size limit"):
                client.get_all("api/v1/courses")

    def test_rejects_repeated_pagination_page(self):
        first_url = "https://canvas.example.edu/api/v1/courses"
        response = FakeResponse([], link=f'<{first_url}>; rel="next"')
        client = module.CanvasClient(
            "https://canvas.example.edu", "token",
            opener=FakeOpener(response), clock=lambda: 0,
        )
        with self.assertRaisesRegex(RuntimeError, "repeated"):
            client.get_all("api/v1/courses")

    def test_rejects_too_many_api_records(self):
        with patch.object(module, "MAX_RECORDS", 1):
            client = module.CanvasClient(
                "https://canvas.example.edu", "token",
                opener=FakeOpener(FakeResponse([{"id": 1}, {"id": 2}])),
                clock=lambda: 0,
            )
            with self.assertRaisesRegex(RuntimeError, "record limit"):
                client.get_all("api/v1/courses")

    def test_enforces_overall_fetch_deadline(self):
        times = iter((0, module.MAX_FETCH_SECONDS + 1))
        client = module.CanvasClient(
            "https://canvas.example.edu", "token",
            opener=FakeOpener(), clock=lambda: next(times),
        )
        with self.assertRaisesRegex(RuntimeError, "allowed duration"):
            client.get_all("api/v1/courses")

    def test_distinguishes_authentication_and_permission_failures(self):
        for status, expected in (
            (401, module.CanvasAuthenticationError),
            (403, module.CanvasPermissionError),
        ):
            error = HTTPError(
                "https://canvas.example.edu/api/v1/courses",
                status, "failure", {}, None,
            )
            client = module.CanvasClient(
                "https://canvas.example.edu", "token",
                opener=RaisingOpener(error), clock=lambda: 0,
            )
            with self.subTest(status=status), self.assertRaises(expected):
                client.get_all("api/v1/courses")

    def test_separates_student_and_teacher_courses(self):
        client = MixedRoleClient()
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))

        self.assertEqual(
            [course["name"] for course in data["roles"]["student"]["courses"]],
            ["Course I Take"],
        )
        self.assertEqual(
            [course["name"] for course in data["roles"]["teacher"]["courses"]],
            ["Course I Teach"],
        )
        self.assertEqual(client.requested_params[0]["enrollment_type"], "student")
        teacher_courses_params = next(
            params for path, params in zip(client.requested_paths, client.requested_params)
            if path == "api/v1/courses" and params.get("enrollment_type") == "teacher"
        )
        self.assertEqual(teacher_courses_params["enrollment_type"], "teacher")
        self.assertIn("api/v1/courses/10/assignments", client.requested_paths)
        self.assertIn("api/v1/courses/20/assignments", client.requested_paths)

    def test_hidden_course_skips_assignment_request(self):
        client = MixedRoleClient()
        data = module.collect(
            client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
            hidden_course_ids={"20"},
        )

        student = data["roles"]["student"]
        self.assertEqual(student["courses"], [])
        self.assertEqual([course["id"] for course in student["hidden_courses"]], [20])
        self.assertNotIn("api/v1/courses/20/assignments", client.requested_paths)

    def test_hidden_teacher_course_skips_assignment_request(self):
        client = MixedRoleClient()
        data = module.collect(
            client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
            hidden_course_ids={"10"},
        )

        teacher = data["roles"]["teacher"]
        self.assertEqual(teacher["courses"], [])
        self.assertEqual([course["id"] for course in teacher["hidden_courses"]], [10])
        self.assertNotIn("api/v1/courses/10/assignments", client.requested_paths)

    def test_hidden_course_preferences_are_scoped_by_canvas_url(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "hidden-courses.json"
            module.set_course_hidden(
                "https://canvas.example.edu/", "20", True,
                "Orientation", "ORIENT", path,
            )

            self.assertIn("20", module.hidden_courses_for("https://canvas.example.edu", path))
            self.assertEqual(module.hidden_courses_for("https://other.example.edu", path), {})

            module.set_course_hidden("https://canvas.example.edu", "20", False, path=path)
            self.assertEqual(module.hidden_courses_for("https://canvas.example.edu", path), {})

    def test_hidden_course_preferences_are_written_privately_and_atomically(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "omakanvas" / "hidden-courses.json"
            module.set_course_hidden(
                "https://canvas.example.edu", "20", True,
                "Orientation", "ORIENT", path,
            )

            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual(list(path.parent.glob(".hidden-courses.json.*.tmp")), [])

    def test_rejects_symlinked_hidden_course_preferences(self):
        with TemporaryDirectory() as directory:
            target = Path(directory) / "target.json"
            target.write_text('{"version": 1, "instances": {}}', encoding="utf-8")
            path = Path(directory) / "hidden-courses.json"
            path.symlink_to(target)

            with self.assertRaisesRegex(RuntimeError, "symbolic link"):
                module.hidden_courses_for("https://canvas.example.edu", path)

    def test_collects_all_announcements_newest_first(self):
        topics = [
            {"id": 1, "title": "Old news", "posted_at": "2026-08-01T10:00:00Z",
             "message": "<p>First.</p>",
             "author": {"display_name": "Instructor"},
             "html_url": "https://canvas.test/courses/7/discussion_topics/1"},
            {"id": 2, "title": "Newer news", "posted_at": "2026-08-20T10:00:00Z",
             "message": "Second",
             "author": {"display_name": "Instructor"},
             "html_url": "https://canvas.test/courses/7/discussion_topics/2"},
            {"id": 3, "title": "Newest news", "posted_at": "2026-08-25T10:00:00Z",
             "message": "Third",
             "author": {"display_name": "Instructor"},
             "html_url": "https://canvas.test/courses/7/discussion_topics/3"},
            {"id": 4, "title": "Middle news", "posted_at": "2026-08-10T10:00:00Z",
             "message": "Fourth",
             "author": {"display_name": "Instructor"},
             "html_url": "https://canvas.test/courses/7/discussion_topics/4"},
            {"id": 5, "title": "Undated news",
             "message": "Fifth",
             "author": {"display_name": "Instructor"},
             "html_url": "https://canvas.test/courses/7/discussion_topics/5"},
        ]
        client = AnnouncementClient(topics=topics)
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        announcements = data["roles"]["student"]["courses"][0]["announcements"]
        self.assertEqual(
            [item["title"] for item in announcements],
            ["Newest news", "Newer news", "Middle news", "Old news", "Undated news"],
        )
        self.assertEqual(
            announcements[0]["posted_at"], "2026-08-25T10:00:00+00:00",
        )
        self.assertEqual(announcements[0]["author"], "Instructor")
        self.assertEqual(announcements[0]["excerpt"], "Third")
        self.assertEqual(
            announcements[0]["html_url"],
            "https://canvas.test/courses/7/discussion_topics/3",
        )
        announcement_request = next(
            params for path, params in zip(client.requested_paths, client.requested_params)
            if path == "api/v1/courses/7/discussion_topics"
        )
        self.assertEqual(announcement_request["only_announcements"], "true")

    def test_announcement_excerpt_strips_markup_and_truncates(self):
        self.assertEqual(
            module.plain_text_excerpt("<p>Hello <b>world</b></p>"),
            "Hello world",
        )
        self.assertEqual(module.plain_text_excerpt(None), "")
        long_text = "word " * 100
        excerpt = module.plain_text_excerpt(long_text)
        self.assertLessEqual(len(excerpt), module.ANNOUNCEMENT_EXCERPT_LENGTH)
        self.assertTrue(excerpt.endswith("…"))

    def test_announcement_with_external_url_is_not_linkable(self):
        client = AnnouncementClient(topics=[
            {"id": 9, "title": "External", "posted_at": "2026-08-25T10:00:00Z",
             "message": "Body", "author": {"display_name": "Instructor"},
             "html_url": "https://attacker.example/collect"},
        ])
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        announcements = data["roles"]["student"]["courses"][0]["announcements"]
        self.assertEqual(len(announcements), 1)
        self.assertIsNone(announcements[0]["html_url"])

    def test_announcement_permission_failure_yields_empty_list(self):
        client = AnnouncementClient(error=module.CanvasPermissionError("denied"))
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        course = data["roles"]["student"]["courses"][0]
        self.assertEqual(course["announcements"], [])
        self.assertEqual(data["roles"]["student"]["error"], "")

    def test_hidden_course_skips_announcement_request(self):
        client = AnnouncementClient(topics=[
            {"id": 1, "title": "News", "posted_at": "2026-08-25T10:00:00Z",
             "message": "Body", "author": {},
             "html_url": "https://canvas.test/courses/7/discussion_topics/1"},
        ])
        data = module.collect(
            client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
            hidden_course_ids={"7"},
        )
        self.assertEqual(data["roles"]["student"]["courses"], [])
        self.assertNotIn(
            "api/v1/courses/7/discussion_topics", client.requested_paths,
        )

    def test_collects_all_conversations_for_course_newest_first(self):
        records = [
            {"id": 11, "subject": "Old thread", "workflow_state": "read",
             "last_message": "First", "last_message_at": "2026-08-01T10:00:00Z",
             "message_count": 2, "starred": False,
             "participants": [{"id": 5, "name": "Instructor"}],
             "context_name": "Biology"},
            {"id": 12, "subject": "New question", "workflow_state": "unread",
             "last_message": "<p>Second</p>", "last_message_at": "2026-08-25T10:00:00Z",
             "message_count": 1, "starred": True,
             "participants": [{"id": 5, "name": "Instructor"}],
             "context_name": "Biology"},
            {"id": 13, "subject": "Middle thread", "workflow_state": "unread",
             "last_message": "Third", "last_message_at": "2026-08-10T10:00:00Z",
             "message_count": 4, "starred": False,
             "participants": [{"id": 5, "name": "Instructor"}],
             "context_name": "Biology"},
        ]
        client = AnnouncementClient(conversations=records)
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        conversations = data["roles"]["student"]["courses"][0]["conversations"]
        self.assertEqual(
            [item["subject"] for item in conversations],
            ["New question", "Middle thread", "Old thread"],
        )
        newest = conversations[0]
        self.assertTrue(newest["unread"])
        self.assertEqual(newest["last_message"], "Second")
        self.assertEqual(
            newest["last_message_at"], "2026-08-25T10:00:00+00:00",
        )
        self.assertTrue(newest["starred"])
        self.assertEqual(newest["participants"], [{"id": 5, "name": "Instructor"}])
        self.assertEqual(newest["html_url"], "https://canvas.test/conversations")
        self.assertFalse(conversations[2]["unread"])
        conversation_request = next(
            params for path, params in zip(client.requested_paths, client.requested_params)
            if path == "api/v1/conversations"
        )
        self.assertEqual(conversation_request["filter"], "course_7")

    def test_conversation_permission_failure_yields_empty_list(self):
        client = AnnouncementClient(
            conversation_error=module.CanvasPermissionError("denied"),
        )
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        course = data["roles"]["student"]["courses"][0]
        self.assertEqual(course["conversations"], [])
        self.assertEqual(data["roles"]["student"]["error"], "")

    def test_hidden_course_skips_conversation_request(self):
        client = AnnouncementClient(conversations=[
            {"id": 12, "subject": "New question", "workflow_state": "unread",
             "last_message": "Hi", "last_message_at": "2026-08-25T10:00:00Z",
             "message_count": 1, "starred": False,
             "participants": [], "context_name": "Biology"},
        ])
        data = module.collect(
            client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
            hidden_course_ids={"7"},
        )
        self.assertEqual(data["roles"]["student"]["courses"], [])
        self.assertNotIn("api/v1/conversations", client.requested_paths)

    def test_collects_all_discussions_most_active_first(self):
        records = [
            {"id": 21, "title": "Quiet thread", "posted_at": "2026-08-01T10:00:00Z",
             "last_reply_at": "2026-08-02T10:00:00Z",
             "message": "First", "author": {"display_name": "Student"},
             "discussion_subentry_count": 1, "pinned": False, "locked": False,
             "html_url": "https://canvas.test/courses/7/discussion_topics/21"},
            {"id": 22, "title": "Hot thread", "posted_at": "2026-08-05T10:00:00Z",
             "last_reply_at": "2026-08-25T10:00:00Z",
             "message": "<p>Second</p>", "author": {"display_name": "Instructor"},
             "discussion_subentry_count": 12, "pinned": True, "locked": False,
             "html_url": "https://canvas.test/courses/7/discussion_topics/22"},
            {"id": 23, "title": "Locked thread", "posted_at": "2026-08-10T10:00:00Z",
             "message": "Third", "author": {"display_name": "Instructor"},
             "discussion_subentry_count": 0, "pinned": False, "locked": True,
             "html_url": "https://attacker.example/collect"},
        ]
        client = AnnouncementClient(discussions=records)
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        discussions = data["roles"]["student"]["courses"][0]["discussions"]
        self.assertEqual(
            [item["title"] for item in discussions],
            ["Hot thread", "Locked thread", "Quiet thread"],
        )
        hot = discussions[0]
        self.assertEqual(hot["last_activity_at"], "2026-08-25T10:00:00+00:00")
        self.assertEqual(hot["reply_count"], 12)
        self.assertTrue(hot["pinned"])
        self.assertFalse(hot["locked"])
        self.assertEqual(hot["excerpt"], "Second")
        self.assertEqual(
            hot["html_url"],
            "https://canvas.test/courses/7/discussion_topics/22",
        )
        self.assertTrue(discussions[1]["locked"])
        self.assertIsNone(discussions[1]["html_url"])
        discussion_request = next(
            params for path, params in zip(client.requested_paths, client.requested_params)
            if path == "api/v1/courses/7/discussion_topics"
            and params.get("only_announcements") != "true"
        )
        self.assertEqual(discussion_request["order_by"], "recent_activity")

    def test_discussion_permission_failure_yields_empty_list(self):
        client = AnnouncementClient(
            discussion_error=module.CanvasPermissionError("denied"),
        )
        data = module.collect(client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc))
        course = data["roles"]["student"]["courses"][0]
        self.assertEqual(course["discussions"], [])
        self.assertEqual(data["roles"]["student"]["error"], "")

    def test_hidden_course_skips_discussion_request(self):
        client = AnnouncementClient(discussions=[
            {"id": 21, "title": "Thread", "posted_at": "2026-08-25T10:00:00Z",
             "message": "Body", "author": {},
             "discussion_subentry_count": 3, "pinned": False, "locked": False,
             "html_url": "https://canvas.test/courses/7/discussion_topics/21"},
        ])
        data = module.collect(
            client, 14, datetime(2026, 8, 27, tzinfo=timezone.utc),
            hidden_course_ids={"7"},
        )
        self.assertEqual(data["roles"]["student"]["courses"], [])
        discussion_requests = [
            params for path, params in zip(client.requested_paths, client.requested_params)
            if path == "api/v1/courses/7/discussion_topics"
            and (params or {}).get("only_announcements") != "true"
        ]
        self.assertEqual(discussion_requests, [])


if __name__ == "__main__":
    unittest.main()
