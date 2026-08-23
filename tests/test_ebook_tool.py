import base64
import importlib.machinery
import io
import json
import struct
import sys
import tempfile
import unittest
import urllib.request
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
leaf = importlib.machinery.SourceFileLoader("leaf_ebook_tool", str(ROOT / "ebook-tool")).load_module()

VALID_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def make_epub(
    path: Path, title="A Quiet Book", author="A. Reader", cover_data=VALID_PNG,
    *, container_data=None, opf_data=None,
):
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
  <manifest><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/></manifest>
</package>"""
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr("META-INF/container.xml", container if container_data is None else container_data)
        archive.writestr("OPS/book.opf", opf if opf_data is None else opf_data)
        archive.writestr("OPS/cover.png", cover_data)


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
        def fake_sanitizer(data, book_id, _mtime):
            target = leaf.CACHE_DIR / "covers" / f"{book_id}.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            return str(target)
        with mock.patch.object(leaf, "sanitize_cover_bytes", side_effect=fake_sanitizer):
            books = leaf.scan_library()
        self.assertEqual(len(books), 1)
        self.assertEqual(books[0]["title"], "A Quiet Book")
        self.assertEqual(books[0]["author"], "A. Reader")
        self.assertEqual(books[0]["formats"], ["epub", "azw3"])
        self.assertTrue(Path(books[0]["cover"]).is_file())

    def test_cover_headers_and_dimensions_are_bounded_before_decode(self):
        self.assertEqual(leaf.cover_image_info(VALID_PNG), ("png", 1, 1))
        oversized = bytearray(VALID_PNG)
        oversized[16:24] = struct.pack(">II", leaf.MAX_COVER_DIMENSION + 1, 1)
        self.assertIsNone(leaf.cover_image_info(bytes(oversized)))
        self.assertIsNone(leaf.cover_image_info(b"not an image"))
        with mock.patch.object(leaf.shutil, "which") as which:
            self.assertEqual(leaf.sanitize_cover_bytes(b"x" * (leaf.MAX_COVER_SOURCE_BYTES + 1), "huge"), "")
        which.assert_not_called()

    def test_oversized_epub_cover_is_rejected_before_extraction(self):
        path = self.library / "Oversized.epub"
        make_epub(path, cover_data=b"x" * (leaf.MAX_COVER_SOURCE_BYTES + 1))
        with mock.patch.object(leaf, "sanitize_cover_bytes") as sanitizer:
            self.assertEqual(leaf.safe_cover_from_epub(path, "oversized"), "")
        sanitizer.assert_not_called()

    def test_oversized_epub_container_is_rejected_before_xml_parsing(self):
        path = self.library / "Oversized Container.epub"
        make_epub(
            path,
            container_data=b"x" * (leaf.MAX_EPUB_CONTAINER_XML_BYTES + 1),
        )
        with mock.patch.object(leaf.ET, "fromstring") as parse_xml:
            self.assertEqual(leaf.epub_metadata(path), {})
            self.assertEqual(leaf.safe_cover_from_epub(path, "oversized-container"), "")
        parse_xml.assert_not_called()

    def test_oversized_epub_package_is_rejected_before_opf_parsing(self):
        path = self.library / "Oversized Package.epub"
        make_epub(
            path,
            opf_data=b"x" * (leaf.MAX_EPUB_PACKAGE_XML_BYTES + 1),
        )
        with mock.patch.object(leaf, "parse_opf_bytes") as parse_opf, \
             mock.patch.object(leaf, "sanitize_cover_bytes") as sanitizer:
            self.assertEqual(leaf.epub_metadata(path), {})
            self.assertEqual(leaf.safe_cover_from_epub(path, "oversized-package"), "")
        parse_opf.assert_not_called()
        sanitizer.assert_not_called()

    def test_sidecar_package_metadata_is_bounded_before_read(self):
        (self.library / "metadata.opf").write_bytes(
            b"x" * (leaf.MAX_EPUB_PACKAGE_XML_BYTES + 1)
        )
        with mock.patch.object(leaf, "parse_opf_bytes") as parse_opf:
            self.assertEqual(leaf.sidecar_metadata(self.library), {})
        parse_opf.assert_not_called()

    def test_zip_member_read_has_an_independent_actual_byte_ceiling(self):
        info = mock.Mock()
        info.is_dir.return_value = False
        info.flag_bits = 0
        info.file_size = 1
        archive = mock.Mock()
        archive.getinfo.return_value = info
        member = mock.MagicMock()
        member.__enter__.return_value.read.return_value = b"x" * 10
        archive.open.return_value = member
        self.assertIsNone(leaf.bounded_zip_member(archive, "OPS/book.opf", 8))
        member.__enter__.return_value.read.assert_called_once_with(9)

    def test_cover_is_reencoded_by_resource_limited_process(self):
        def fake_run(command, **_kwargs):
            Path(command[-1].removeprefix("png:")).write_bytes(VALID_PNG)
            return mock.Mock(returncode=0)
        with mock.patch.object(leaf.shutil, "which", return_value="/usr/bin/magick"), \
             mock.patch.object(leaf.subprocess, "run", side_effect=fake_run) as run:
            cover = leaf.sanitize_cover_bytes(VALID_PNG, "bounded-cover")
        self.assertTrue(Path(cover).is_file())
        command = run.call_args.args[0]
        self.assertEqual(command[0], "/usr/bin/magick")
        self.assertIn("64MiB", command)
        self.assertIn("512x768>", command)
        self.assertTrue(command[-1].startswith("png:"))
        self.assertEqual(run.call_args.kwargs["timeout"], 15)

    def test_sidecar_cover_is_never_served_directly_to_qml(self):
        folder = self.library / "Sidecar"
        folder.mkdir()
        (folder / "Book.azw3").write_bytes(b"kindle")
        sidecar = folder / "cover.jpg"
        sidecar.write_bytes(VALID_PNG)
        bounded = leaf.CACHE_DIR / "covers" / "bounded.png"
        bounded.parent.mkdir(parents=True)
        bounded.write_bytes(VALID_PNG)
        with mock.patch.object(leaf, "sanitize_cover_bytes", return_value=str(bounded)) as sanitizer:
            book = leaf.scan_library()[0]
        self.assertEqual(book["cover"], str(bounded))
        self.assertNotEqual(book["cover"], str(sidecar))
        sanitizer.assert_called_once()

    def test_sidecar_metadata_is_used_without_calibre_database(self):
        folder = self.library / "River North" / "Cloud Atlas"
        folder.mkdir(parents=True)
        (folder / "Cloud Atlas.azw3").write_bytes(b"kindle")
        (folder / "metadata.opf").write_text("""<package xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>Clouds Over Alder</dc:title><dc:creator>River North</dc:creator></metadata>
        </package>""", encoding="utf-8")
        book = leaf.scan_library()[0]
        self.assertEqual(book["title"], "Clouds Over Alder")
        self.assertEqual(book["author"], "River North")

    def test_markup_shaped_epub_metadata_remains_literal_data(self):
        folder = self.library / "Untrusted Metadata"
        make_epub(
            folder / "Markup.epub",
            title='&lt;img src="http://127.0.0.1:9/cover"&gt; ![cover](http://127.0.0.1:9/cover)',
            author='&lt;a href="file:///tmp/author"&gt;A. Reader&lt;/a&gt;',
        )
        book = leaf.scan_library()[0]
        self.assertEqual(
            book["title"],
            '<img src="http://127.0.0.1:9/cover"> ![cover](http://127.0.0.1:9/cover)',
        )
        self.assertEqual(book["author"], '<a href="file:///tmp/author">A. Reader</a>')

    def test_fresh_install_prefers_personal_books_then_starter_library(self):
        base = Path(self.temp.name)
        home = base / "home"
        personal = home / "Books"
        starter = base / "starter-books"
        starter.mkdir()
        make_epub(starter / "Welcome.epub")
        with mock.patch.object(leaf.Path, "home", return_value=home), \
             mock.patch.object(leaf, "STARTER_LIBRARY_DIR", starter):
            self.assertEqual(leaf.default_library(), str(starter))
            make_epub(personal / "Mine.epub")
            self.assertEqual(leaf.default_library(), str(personal))

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
            "pageTurn": False,
        })
        self.assertEqual(result["fontSize"], 36)
        self.assertEqual(result["lineHeight"], 1.25)
        self.assertEqual(result["pageWidth"], 1100)
        self.assertEqual(result["theme"], "paper")
        self.assertEqual(result["fontFamily"], "serif")
        self.assertEqual(result["flow"], "paginated")
        self.assertFalse(result["pageTurn"])

    def test_boolean_settings_are_tolerant_of_saved_json_values(self):
        self.assertFalse(leaf.validate_settings({"pageTurn": "off"})["pageTurn"])
        self.assertTrue(leaf.validate_settings({"pageTurn": "yes"})["pageTurn"])
        self.assertTrue(leaf.validate_settings({"pageTurn": ["invalid"]})["pageTurn"])
        self.assertFalse(leaf.validate_settings({"showClock": "false"})["showClock"])

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
        self.assertEqual(command[2], "--")
        self.assertEqual(command[3], f"--leaf-reader-url=http://127.0.0.1:4189/?book={book['id']}")
        webengine_flags = popen.call_args.kwargs["env"]["QTWEBENGINE_CHROMIUM_FLAGS"]
        self.assertIn("--proxy-server=http://127.0.0.1:9", webengine_flags)
        self.assertIn("--disable-background-networking", webengine_flags)
        activate.assert_called_once_with(4242)
        self.assertEqual(leaf.progress_state()["lastBookId"], book["id"])

    def test_untrusted_qml_metadata_is_rendered_as_plain_text(self):
        panel = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        metadata_bindings = (
            'text: root.lastBook() ? String(root.lastBook().title || "") : ""',
            'width: parent.width; text: root.lastBook() ? String(root.lastBook().title || "") : ""',
            'width: parent.width; text: root.lastBook() ? String(root.lastBook().author || "") : ""',
            'text: String(modelData.title || "")',
            'text: String(modelData.author || "")',
            'text: root.statusText',
        )
        def containing_text_block(position):
            start = panel.rfind("Text {", 0, position)
            self.assertNotEqual(start, -1, "metadata binding is not inside a Text object")
            depth = 0
            for index in range(start, len(panel)):
                if panel[index] == "{":
                    depth += 1
                elif panel[index] == "}":
                    depth -= 1
                    if depth == 0:
                        self.assertLess(position, index, "metadata binding is outside the nearest Text object")
                        return panel[start:index + 1]
            self.fail("unterminated Text object")

        for binding in metadata_bindings:
            position = panel.find(binding)
            self.assertNotEqual(position, -1, f"missing guarded metadata binding: {binding}")
            while position != -1:
                self.assertIn("textFormat: Text.PlainText", containing_text_block(position), binding)
                position = panel.find(binding, position + len(binding))

        bar = (ROOT / "BarWidget.qml").read_text(encoding="utf-8")
        self.assertIn('tooltipText: root.lastTitle !== "" ? "Leaf Reader · Continue reading" : "Leaf Reader"', bar)
        self.assertNotIn('tooltipText: root.lastTitle !== "" ? "Leaf Reader · Continue “" + root.lastTitle', bar)
        self.assertNotIn("hostWidget.lastTitle =", panel)

    def test_shell_cover_images_have_explicit_decode_bounds(self):
        panel = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        self.assertEqual(panel.count("sourceSize: Qt.size("), 2)
        self.assertIn("sourceSize: Qt.size(Style.space(140), Style.space(212))", panel)
        self.assertIn("sourceSize: Qt.size(Style.space(212), Style.space(290))", panel)


if __name__ == "__main__":
    unittest.main()
