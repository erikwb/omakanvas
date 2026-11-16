import hashlib
import io
import json
from pathlib import Path
import stat
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request

import test_omacanvas as existing

module = existing.module


class BinaryResponse(io.BytesIO):
    def __init__(self, body, headers=None):
        super().__init__(body)
        self.headers = headers or {"Content-Length": str(len(body))}


class Routes:
    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        parsed = urlparse(request.full_url)
        key = parsed.path
        page = parse_qs(parsed.query).get("page")
        if page:
            key += "?page=" + page[0]
        if key not in self.routes:
            raise AssertionError(f"Unexpected request: {key}")
        response = self.routes[key]
        if isinstance(response, Exception):
            raise response
        return response()


def json_response(value, next_page=None):
    return lambda: existing.FakeResponse(
        value, link=f'<https://canvas.test{next_page}>; rel="next"' if next_page else None,
    )


def metadata(file_id=42, body=b"document", **overrides):
    return {
        "id": file_id, "filename": "reading.pdf", "display_name": "Reading",
        "size": len(body), "url": f"https://storage.test/files/{file_id}?signature=secret",
        "updated_at": "2026-09-17T12:00:00Z", "content-type": "application/pdf",
        **overrides,
    }


class ModuleTests(unittest.TestCase):
    def test_paginated_modules_and_items_full_bodies_documents_and_both_roles(self):
        body = "Full text with ünicode. " * 3000
        html = (f'<p>{body}</p><a href="/courses/7/files/42/download?wrap=1">Reading</a>'
                '<img data-api-endpoint="https://canvas.test/api/v1/files/43" src="/files/43/preview">'
                '<a href="https://outside.test/files/999">External link</a>')
        document_bytes = b"%PDF-original\x00\xff" * 100
        api = Routes({
            "/api/v1/courses": json_response([{
                "id": 7, "name": "Biology", "enrollments": [{"type": "student"}, {"type": "teacher"}],
            }]),
            "/api/v1/courses/7/assignments": json_response([]),
            "/api/v1/courses/7/discussion_topics": json_response([]),
            "/api/v1/conversations": json_response([]),
            "/api/v1/courses/7/modules": json_response([
                {"id": 2, "name": "Second", "position": 2, "items_count": 6},
            ], "/api/v1/courses/7/modules?page=2"),
            "/api/v1/courses/7/modules?page=2": json_response([
                {"id": 1, "name": "First", "position": 1, "items_count": 2, "items": [{"id": 999}]},
            ]),
            "/api/v1/courses/7/modules/1/items": json_response([
                {"id": 11, "position": 1, "type": "Page", "title": "Reading", "page_url": "reading"},
            ], "/api/v1/courses/7/modules/1/items?page=2"),
            "/api/v1/courses/7/modules/1/items?page=2": json_response([
                {"id": 12, "position": 2, "type": "File", "title": "File", "content_id": 42},
            ]),
            "/api/v1/courses/7/modules/2/items": json_response([
                {"id": i, "position": i, "type": kind, "title": kind, "content_id": i}
                for i, kind in enumerate([
                    "Assignment", "Discussion", "Quiz", "SubHeader", "ExternalUrl", "ExternalTool",
                ], 20)
            ]),
            "/api/v1/courses/7/pages/reading": json_response({"body": html}),
            "/api/v1/courses/7/assignments/20": json_response({"description": html}),
            "/api/v1/courses/7/discussion_topics/21": json_response({"message": html, "attachment": {"id": 44}}),
            "/api/v1/courses/7/quizzes/22": json_response({"description": html, "attachments": [{"id": 44}]}),
            **{f"/api/v1/files/{file_id}": json_response(metadata(file_id, document_bytes)) for file_id in (42, 43, 44)},
        })
        files = Routes({f"/files/{file_id}": lambda: BinaryResponse(document_bytes) for file_id in (42, 43, 44)})
        with TemporaryDirectory() as directory:
            snapshot = Path(directory) / "data/latest.json"
            client = module.CanvasClient("https://canvas.test", "token", opener=api, document_opener=files)
            with patch.object(module, "DOCUMENT_CHUNK_BYTES", 31):
                status, stdout, stderr = existing.SnapshotTests().fetch(client, snapshot)
            self.assertEqual((status, stderr), (0, ""))
            data = json.loads(snapshot.read_text())
            self.assertEqual(json.loads(stdout), data)
            student = data["roles"]["student"]["courses"][0]
            self.assertEqual(student["modules"], data["roles"]["teacher"]["courses"][0]["modules"])
            self.assertEqual([m["id"] for m in student["modules"]], [1, 2])
            self.assertEqual([len(m["items"]) for m in student["modules"]], [2, 6])
            for item in [student["modules"][0]["items"][0], *student["modules"][1]["items"][:3]]:
                self.assertEqual(item["body_html"], html)
                self.assertTrue(item["body"].startswith(body.strip()))
                self.assertEqual(item["fetch_error"], "")
                for document in item["documents"]:
                    local_path = Path(document["local_path"])
                    self.assertEqual(local_path.read_bytes(), document_bytes)
                    self.assertEqual(document["sha256"], hashlib.sha256(document_bytes).hexdigest())
                    self.assertEqual(document["local_url"], local_path.as_uri())
                    self.assertEqual(stat.S_IMODE(local_path.stat().st_mode), 0o600)
                    self.assertEqual(stat.S_IMODE(local_path.parent.stat().st_mode), 0o700)
            self.assertEqual(len(files.requests), 3)
            self.assertEqual(sum(r.full_url.endswith("pages/reading") for r in api.requests), 1)
            self.assertNotIn("signature=secret", snapshot.read_text())
            self.assertTrue(all(r.get_header("Authorization") is None for r in files.requests))

    def test_hidden_courses_do_not_fetch_modules_or_files(self):
        client = existing.AnnouncementClient()
        data = module.collect(client, hidden_course_ids={"7"})
        self.assertEqual(data["roles"]["student"]["courses"], [])
        self.assertFalse(any("modules" in path or "files" in path for path in client.requested_paths))

    def test_unavailable_modules_and_items_remain_explicit(self):
        for level in ("modules", "items", "page", "file"):
            with self.subTest(level=level):
                routes = {
                    "/api/v1/courses/7/modules": json_response([{"id": 1, "name": "Module"}]),
                    "/api/v1/courses/7/modules/1/items": json_response([
                        {"id": 11, "type": "Page", "page_url": "reading"},
                        {"id": 12, "type": "File", "content_id": 42},
                    ]),
                    "/api/v1/courses/7/pages/reading": json_response({"body": "Full body"}),
                    "/api/v1/files/42": json_response(metadata(locked_for_user=True)),
                }
                path = {
                    "modules": "/api/v1/courses/7/modules", "items": "/api/v1/courses/7/modules/1/items",
                    "page": "/api/v1/courses/7/pages/reading", "file": "/api/v1/files/42",
                }[level]
                routes[path] = HTTPError("https://canvas.test" + path, 404 if level == "file" else 403, "unavailable", {}, None)
                client = module.CanvasClient("https://canvas.test", "token", opener=Routes(routes))
                modules, error = module.ModuleCollector(client).collect(7)
                if level == "modules":
                    self.assertEqual(modules, [])
                    self.assertTrue(error)
                else:
                    target = modules[0]
                    if level == "page":
                        target = target["items"][0]
                    elif level == "file":
                        target = target["items"][1]["documents"][0]
                        self.assertIsNone(target["local_path"])
                    self.assertTrue(target["fetch_error"])

    def test_locked_content_keeps_metadata_without_attempting_download(self):
        client = module.CanvasClient("https://canvas.test", "token", opener=Routes({
            "/api/v1/files/42": json_response(metadata(locked_for_user=True, lock_explanation="Locked until Monday")),
        }), document_opener=Routes({}))
        collector = module.ModuleCollector(client)
        item = collector.item("7", {"id": 11, "type": "Page", "page_url": "locked", "content_details": {"locked_for_user": True}})
        self.assertIn("locked", item["fetch_error"])
        document = collector.document(42)
        self.assertEqual(document["download_status"], "locked")
        self.assertEqual(document["fetch_error"], "Locked until Monday")
        self.assertIsNone(document["local_path"])
        self.assertEqual(client.document_opener.requests, [])

    def test_html_references_deduplicate_and_reject_foreign_origins(self):
        parser = module.CanvasFileReferences("https://canvas.test")
        parser.feed('''<a href="/courses/7/files/42/download?download_frd=1&amp;x=2">one</a>
          <img src="https://canvas.test/files/42/preview" />
          <object data="/api/v1/groups/3/files/43"></object>
          <a data-api-endpoint="/api/v1/files/44">two</a>
          <a href="https://canvas.test.evil.test/files/99">bad</a>
          <a href="http://canvas.test/files/99">bad</a>
          <a href="https://user:pass@canvas.test/files/99">bad</a>''')
        parser.close()
        self.assertEqual(list(parser.file_ids), ["42", "43", "44"])


class DocumentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.snapshot = Path(self.temporary.name) / "data/latest.json"
        self.path_patch = patch.object(module, "data_path", return_value=self.snapshot)
        self.path_patch.start()
        self.addCleanup(self.path_patch.stop)

    def client(self, responses, **kwargs):
        return module.CanvasClient("https://canvas.test", **kwargs, document_opener=existing.FakeOpener(*responses))

    def test_cache_reuses_unchanged_bytes_but_repairs_corruption(self):
        body = b"original document"
        client = self.client([BinaryResponse(body)], token="token")
        first = client.download_document(metadata(body=body))
        second = client.download_document(metadata(body=body))
        self.assertEqual(first, second)
        self.assertEqual(len(client.document_opener.requests), 1)
        Path(first["local_path"]).write_bytes(b"X" * len(body))
        client.document_opener.responses.append(BinaryResponse(body))
        repaired = client.download_document(metadata(body=body))
        self.assertEqual(Path(repaired["local_path"]).read_bytes(), body)
        self.assertEqual(len(client.document_opener.requests), 2)

    def test_new_version_keeps_old_snapshot_document(self):
        client = self.client([BinaryResponse(b"old"), BinaryResponse(b"new")], token="token")
        first = client.download_document(metadata(body=b"old"))
        second = client.download_document(metadata(body=b"new", updated_at="2026-09-18T12:00:00Z"))
        self.assertNotEqual(first["local_path"], second["local_path"])
        self.assertEqual(Path(first["local_path"]).read_bytes(), b"old")
        self.assertEqual(Path(second["local_path"]).read_bytes(), b"new")

    def test_partial_download_is_not_published_or_cached(self):
        for headers in ({"Content-Length": "100"}, {"Content-Length": "3"}):
            with self.subTest(headers=headers):
                client = self.client([BinaryResponse(b"abc", headers)], token="token")
                with self.assertRaisesRegex(RuntimeError, "incomplete|expected size"):
                    client.download_document(metadata(body=b"complete"))
                self.assertEqual(list(self.snapshot.parent.rglob("*.tmp")), [])
                self.assertEqual(list(self.snapshot.parent.rglob("*.pdf")), [])
                self.assertEqual(list(self.snapshot.parent.rglob("cache.json")), [])

    def test_interrupted_read_removes_temporary_file(self):
        class Interrupted(BinaryResponse):
            def read(self, size=-1):
                if self.tell():
                    raise ConnectionResetError("connection reset")
                return super().read(2)
        client = self.client([Interrupted(b"complete")], token="token")
        with self.assertRaises(OSError):
            client.download_document(metadata(body=b"complete"))
        self.assertEqual(list(self.snapshot.parent.rglob("*.tmp")), [])
        self.assertEqual(list(self.snapshot.parent.rglob("cache.json")), [])

    def test_document_bytes_are_not_limited_by_json_budget(self):
        body = b"original bytes" * 100
        client = self.client([BinaryResponse(body)], token="token")
        with patch.object(module, "MAX_DOWNLOAD_BYTES", 1), patch.object(module, "DOCUMENT_CHUNK_BYTES", 17):
            saved = client.download_document(metadata(body=body))
        self.assertEqual(Path(saved["local_path"]).read_bytes(), body)
        self.assertEqual(client.downloaded_bytes, 0)

    def test_filenames_cannot_escape_cache_and_empty_files_are_complete(self):
        client = self.client([BinaryResponse(b"")], token="token")
        saved = client.download_document(metadata(body=b"", filename="../../outside.pdf"))
        path = Path(saved["local_path"])
        self.assertTrue(path.is_relative_to(self.snapshot.parent / "documents"))
        self.assertEqual(path.read_bytes(), b"")
        self.assertEqual(saved["downloaded_size"], 0)

    def test_cache_is_scoped_to_canvas_origin(self):
        first = self.client([BinaryResponse(b"one")], token="token").download_document(metadata(body=b"one"))
        other = module.CanvasClient("https://other.test", "token", document_opener=existing.FakeOpener(BinaryResponse(b"two")))
        second = other.download_document(metadata(body=b"two"))
        self.assertEqual(Path(first["local_path"]).read_bytes(), b"one")
        self.assertEqual(Path(second["local_path"]).read_bytes(), b"two")
        self.assertNotEqual(Path(first["local_path"]).parent, Path(second["local_path"]).parent)

    def test_authenticated_same_origin_and_anonymous_storage_requests(self):
        for credential in ({"token": "secret-token"}, {"browser_session": "secret-session"}):
            for origin in ("https://canvas.test", "https://storage.test"):
                with self.subTest(credential=credential, origin=origin):
                    client = self.client([BinaryResponse(b"document")], **credential)
                    # No version timestamp forces a request for each case.
                    client.download_document(metadata(url=origin + "/download", updated_at=None))
                    request = client.document_opener.requests[0]
                    auth = request.get_header("Authorization") or request.get_header("Cookie")
                    self.assertEqual(bool(auth), origin == "https://canvas.test")

    def test_redirects_strip_credentials_and_reject_unsafe_urls(self):
        handler = module.DocumentRedirectHandler()
        request = Request("https://canvas.test/files/42/download", headers={
            "Authorization": "Bearer token", "Cookie": "canvas_session=session", "Accept-Encoding": "identity",
        })
        same = handler.redirect_request(request, None, 302, "", {}, "/download/42")
        self.assertEqual(same.get_header("Authorization"), "Bearer token")
        external = handler.redirect_request(same, None, 302, "", {}, "https://storage.test/signed")
        self.assertIsNone(external.get_header("Authorization"))
        self.assertIsNone(external.get_header("Cookie"))
        self.assertEqual(external.get_header("Accept-encoding"), "identity")
        back = handler.redirect_request(external, None, 302, "", {}, "https://canvas.test/again")
        self.assertIsNone(back.get_header("Authorization"))
        for url in ("http://storage.test/file", "file:///etc/passwd", "https://user:pass@storage.test/file"):
            with self.subTest(url=url), self.assertRaises(module.CrossOriginRequestError):
                handler.redirect_request(request, None, 302, "", {}, url)

    def test_document_errors_do_not_disclose_signed_urls(self):
        client = self.client([], token="token")
        client.document_opener = existing.RaisingOpener(URLError("https://storage.test/file?secret=private"))
        with self.assertRaises(RuntimeError) as error:
            client.download_document(metadata())
        self.assertNotIn("private", str(error.exception))
        self.assertEqual(list(self.snapshot.parent.rglob("*.tmp")), [])

    def test_failed_document_fetch_preserves_previous_snapshot(self):
        self.snapshot.parent.mkdir()
        self.snapshot.write_text('{"previous": true}\n')
        api = Routes({
            "/api/v1/courses": json_response([{"id": 7, "name": "Biology", "enrollments": [{"type": "student"}]}]),
            "/api/v1/courses/7/assignments": json_response([]),
            "/api/v1/courses/7/discussion_topics": json_response([]),
            "/api/v1/conversations": json_response([]),
            "/api/v1/courses/7/modules": json_response([{"id": 1}]),
            "/api/v1/courses/7/modules/1/items": json_response([{"id": 11, "type": "File", "content_id": 42}]),
            "/api/v1/files/42": json_response(metadata()),
        })
        client = self.client([BinaryResponse(b"partial")], token="token", opener=api)
        status, stdout, stderr = existing.SnapshotTests().fetch(client, self.snapshot)
        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("expected size", stderr)
        self.assertEqual(json.loads(self.snapshot.read_text()), {"previous": True})


if __name__ == "__main__":
    unittest.main()
