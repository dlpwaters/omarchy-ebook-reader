import importlib.machinery
import io
import json
import sys
import tempfile
import unittest
import urllib.request
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
leaf = importlib.machinery.SourceFileLoader("leaf_ebook_tool", str(ROOT / "ebook-tool")).load_module()


def make_epub(path: Path, title="A Quiet Book", author="A. Reader"):
    container = """<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""
    opf = f"""<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>en</dc:language>
    <meta name="cover" content="cover"/>
  </metadata>
  <manifest><item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/></manifest>
</package>"""
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr("META-INF/container.xml", container)
        archive.writestr("OPS/book.opf", opf)
        archive.writestr("OPS/cover.jpg", b"\xff\xd8\xff\xd9")


class LeafReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.library = base / "Library"
        self.library.mkdir()
        leaf.STATE_DIR = base / "state"
        leaf.CACHE_DIR = base / "cache"
        leaf.SETTINGS_FILE = leaf.STATE_DIR / "settings.json"
        leaf.PROGRESS_FILE = leaf.STATE_DIR / "progress.json"
        leaf.INDEX_FILE = leaf.CACHE_DIR / "index.json"
        leaf.SERVER_FILE = leaf.STATE_DIR / "server.json"
        leaf.READER_FILE = leaf.STATE_DIR / "reader.json"
        leaf.atomic_json(leaf.SETTINGS_FILE, {"libraryFolder": str(self.library)})

    def tearDown(self):
        self.temp.cleanup()

    def test_epub_metadata_cover_and_format_grouping(self):
        folder = self.library / "A Reader" / "A Quiet Book"
        make_epub(folder / "A Quiet Book.epub")
        (folder / "A Quiet Book.azw3").write_bytes(b"kindle")
        books = leaf.scan_library()
        self.assertEqual(len(books), 1)
        self.assertEqual(books[0]["title"], "A Quiet Book")
        self.assertEqual(books[0]["author"], "A. Reader")
        self.assertEqual(books[0]["formats"], ["epub", "azw3"])
        self.assertTrue(Path(books[0]["cover"]).is_file())

    def test_sidecar_metadata_is_used_without_calibre_database(self):
        folder = self.library / "Octavia Butler" / "Parable"
        folder.mkdir(parents=True)
        (folder / "Parable.azw3").write_bytes(b"kindle")
        (folder / "metadata.opf").write_text("""<package xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>Parable of the Sower</dc:title><dc:creator>Octavia E. Butler</dc:creator></metadata>
        </package>""", encoding="utf-8")
        book = leaf.scan_library()[0]
        self.assertEqual(book["title"], "Parable of the Sower")
        self.assertEqual(book["author"], "Octavia E. Butler")

    def test_progress_and_last_book_are_atomic_and_bounded(self):
        make_epub(self.library / "Book.epub")
        book = leaf.scan_library()[0]
        saved = leaf.update_progress(book["id"], {"cfi": "epubcfi(/6/2)", "percentage": 1.7, "chapter": "One"})
        self.assertEqual(saved["percentage"], 1.0)
        state = leaf.progress_state()
        self.assertEqual(state["lastBookId"], book["id"])
        self.assertEqual(state["books"][book["id"]]["cfi"], "epubcfi(/6/2)")

    def test_settings_are_validated(self):
        result = leaf.save_settings({
            "libraryFolder": str(self.library), "fontSize": 99, "lineHeight": 0.5,
            "pageWidth": 4000, "theme": "neon", "fontFamily": "comic", "flow": "flipbook",
        })
        self.assertEqual(result["fontSize"], 36)
        self.assertEqual(result["lineHeight"], 1.25)
        self.assertEqual(result["pageWidth"], 1100)
        self.assertEqual(result["theme"], "paper")
        self.assertEqual(result["fontFamily"], "serif")
        self.assertEqual(result["flow"], "paginated")

    def test_index_cache_refreshes_when_book_changes(self):
        path = self.library / "Book.epub"
        make_epub(path, "First Title")
        self.assertEqual(leaf.scan_library()[0]["title"], "First Title")
        make_epub(path, "Revised Title")
        self.assertEqual(leaf.scan_library()[0]["title"], "Revised Title")

    def test_http_api_requires_token_for_writes_and_serves_epub(self):
        make_epub(self.library / "Book.epub")
        book = leaf.scan_library()[0]
        server = leaf.ReaderServer(("127.0.0.1", 0), "test-token")
        thread = leaf.threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            with urllib.request.urlopen(base + "/api/bootstrap") as response:
                payload = json.load(response)
            self.assertEqual(payload["token"], "test-token")
            with urllib.request.urlopen(base + "/api/book/" + book["id"]) as response:
                self.assertEqual(response.headers.get_content_type(), "application/epub+zip")
                self.assertTrue(response.read(4).startswith(b"PK"))
            request = urllib.request.Request(base + "/api/progress/" + book["id"], data=b"{}", method="POST")
            request.add_header("Content-Type", "application/json")
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request)
            self.assertEqual(caught.exception.code, 403)
            caught.exception.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_paths_outside_web_root_are_not_served(self):
        server = leaf.ReaderServer(("127.0.0.1", 0), "test-token")
        thread = leaf.threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/../ebook-tool")
            self.assertEqual(caught.exception.code, 404)
            caught.exception.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_native_reader_launch_uses_isolated_qt6_process(self):
        make_epub(self.library / "Book.epub")
        book = leaf.scan_library()[0]
        fake_process = mock.Mock(pid=4242)
        with mock.patch.object(leaf, "start_server", return_value={"ok": True, "url": "http://127.0.0.1:4189/"}), \
             mock.patch.object(leaf.shutil, "which", side_effect=lambda name: sys.executable if name == "qml6" else None), \
             mock.patch.object(leaf, "activate_reader", return_value=True) as activate, \
             mock.patch.object(leaf.subprocess, "Popen", return_value=fake_process) as popen:
            result = leaf.launch_reader(book["id"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["pid"], 4242)
        command = popen.call_args.args[0]
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(Path(command[1]).name, "ReaderApp.qml")
        activate.assert_called_once_with(4242)
        self.assertEqual(leaf.progress_state()["lastBookId"], book["id"])


if __name__ == "__main__":
    unittest.main()
