import importlib.util
import inspect
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "generate_paper_pptx.py"
)
SPEC = importlib.util.spec_from_file_location("generate_paper_pptx", SCRIPT_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TestGeneratePaperPptx(unittest.TestCase):
    def test_parse_citation_abstract_stops_at_next_heading(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            citation_path = Path(tmpdir) / "paper_citation.md"
            citation_path.write_text(
                textwrap.dedent(
                    """
                    **DOI:** 10.1234/example

                    ## APA Citation

                    Author, A. (2025). Sample Title. *Journal*.
                    ---

                    ## Abstract

                    This is sentence one.
                    This is sentence two.

                    ## Keywords

                    one; two; three
                    """
                ).strip()
                + "\n",
                encoding="utf-8",
            )

            info = MODULE.parse_citation(citation_path)

            self.assertEqual(
                info["abstract"],
                "This is sentence one.\nThis is sentence two.",
            )

    def test_extract_figures_ignores_picture_images(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            folder = Path(tmpdir)
            (folder / "_page_1_Picture_1.jpeg").write_bytes(b"x")
            (folder / "_page_2_Figure_1.png").write_bytes(b"x")

            md_text = textwrap.dedent(
                """
                ![](_page_1_Picture_1.jpeg)
                ## Figure 1. First caption
                (A) first panel

                ![](_page_2_Figure_1.png)
                ## Figure 2. Second caption
                (B) second panel
                """
            ).strip()

            figures = MODULE.extract_figures(md_text, folder)

            self.assertEqual(len(figures), 1)
            self.assertTrue(figures[0]["image_path"].endswith("_page_2_Figure_1.png"))
            self.assertEqual(figures[0]["label"], "Figure 2")
            self.assertEqual(
                figures[0]["caption_text"],
                "Figure 2. Second caption (B) second panel",
            )
            self.assertIn("order", figures[0])

    def test_extract_figure_label_fallback(self):
        self.assertEqual(MODULE.extract_figure_label("", 4), "Figure 4")

    def test_combine_items_in_document_order(self):
        figures = [{"type": "figure", "order": 9}, {"type": "figure", "order": 20}]
        tables = [{"type": "table", "order": 15}]
        equations = [{"type": "equation", "order": 3}]

        merged = MODULE.combine_items_in_document_order(figures, tables, equations)

        self.assertEqual([item["type"] for item in merged], ["equation", "figure", "table", "figure"])
        self.assertEqual([item["order"] for item in merged], [3, 9, 15, 20])

    def test_document_order_from_real_extractors(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            folder = Path(tmpdir)
            (folder / "_page_10_Figure_1.jpeg").write_bytes(b"x")
            md_text = textwrap.dedent(
                """
                Intro context sentence.

                $$
                E = mc^2
                $$

                ![](_page_10_Figure_1.jpeg)
                ## Figure 1. Energy relation
                (A) relation panel

                Table 1. Constants
                | Symbol | Value |
                |---|---|
                | c | speed |
                """
            ).strip()

            figures = MODULE.extract_figures(md_text, folder)
            tables = MODULE.extract_tables(md_text)
            equations = MODULE.extract_equations(md_text)
            merged = MODULE.combine_items_in_document_order(figures, tables, equations)

            self.assertEqual([item["type"] for item in merged], ["equation", "figure", "table"])

    def test_parse_title_authors_skips_image_artifacts_and_uses_citation_authors(self):
        md_text = textwrap.dedent(
            """
            # Sample Title from Markdown

            ![](_page_1_Figure_1.jpeg)
            Received: 10 January 2025
            """
        ).strip()
        citation_info = {
            "citation": "Doe, J., & Smith, A. (2025). Sample title. *Journal*."
        }

        title, authors = MODULE.parse_title_authors(md_text, citation_info)

        self.assertEqual(title, "Sample Title from Markdown")
        self.assertEqual(authors, "Doe, J., & Smith, A.")

    def test_extract_title_from_citation(self):
        citation = "Doe, J. (2025). A useful title for testing. *Journal Name*, 1(1), 1-2."
        self.assertEqual(
            MODULE.extract_title_from_citation(citation),
            "A useful title for testing",
        )

    def test_is_suspicious_title_detects_open_access_artifact(self):
        self.assertTrue(MODULE.is_suspicious_title("<span>ll</span> OPEN ACCESS Article"))

    def test_generate_pptx_defaults_to_figure_only_mode(self):
        sig = inspect.signature(MODULE.generate_pptx)
        self.assertIn("experimental_figure_captions", sig.parameters)
        self.assertFalse(sig.parameters["experimental_figure_captions"].default)


if __name__ == "__main__":
    unittest.main()
