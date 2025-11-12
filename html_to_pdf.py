#!/usr/bin/env python3

"""
html_to_pdf_merge.py

Usage:
    python html_to_pdf_merge.py -i <input_directory> -o <output_file>

Description:
    This script converts all HTML files in the specified input directory into individual PDF
    files, each suffixed with an index (e.g., `page_1.pdf`, `page_2.pdf`, ...), and then
    merges them into a single consolidated PDF.

Requirements:
    - Python 3.7 or higher
    - WeasyPrint (for HTML to PDF conversion)
    - PyPDF2 (for PDF merging)

Install dependencies:
    pip install weasyprint PyPDF2

"""

import os
import argparse
from weasyprint import HTML
from PyPDF2 import PdfMerger

def convert_html_to_pdf(html_path: str, pdf_path: str) -> None:
    """
    Convert a single HTML file to a PDF file.

    Args:
        html_path: Path to the source HTML file.
        pdf_path: Path where the output PDF will be saved.
    """
    HTML(html_path).write_pdf(pdf_path)


def merge_pdfs(pdf_paths: list, output_path: str) -> None:
    """
    Merge multiple PDF files into one.

    Args:
        pdf_paths: List of paths to PDF files to merge in order.
        output_path: Path for the final merged PDF.
    """
    merger = PdfMerger()
    for pdf in pdf_paths:
        merger.append(pdf)
    with open(output_path, 'wb') as f_out:
        merger.write(f_out)


def main() -> None:
    """
    Parse command-line arguments, convert HTMLs to PDFs, then merge.
    """
    parser = argparse.ArgumentParser(
        description="Convert HTML files to individual PDFs and merge them into one."
    )
    parser.add_argument(
        '-i', '--input-dir',
        required=True,
        help='Directory containing HTML files to process.'
    )
    parser.add_argument(
        '-o', '--output',
        default='merged.pdf',
        help='Filename for the merged output PDF (default: merged.pdf).'
    )
    parser.add_argument(
        '--keep-individual',
        action='store_true',
        help='If set, individual PDFs will not be removed after merging.'
    )
    args = parser.parse_args()

    # Gather and sort HTML files
    html_files = [f for f in os.listdir(args.input_dir) if f.lower().endswith('.html')]
    html_files.sort()  # Ensure consistent order; adjust if natural sorting is needed

    if not html_files:
        print(f"No HTML files found in {args.input_dir}.")
        return

    pdf_paths = []
    # Convert each HTML to a PDF with an index suffix
    for idx, html_file in enumerate(html_files, start=1):
        html_path = os.path.join(args.input_dir, html_file)
        base_name = os.path.splitext(html_file)[0]
        pdf_name = f"{base_name}_{idx}.pdf"
        pdf_path = os.path.join(args.input_dir, pdf_name)
        print(f"Converting {html_file} -> {pdf_name}...")
        convert_html_to_pdf(html_path, pdf_path)
        pdf_paths.append(pdf_path)

    # Merge individual PDFs
    print(f"Merging {len(pdf_paths)} PDF files into {args.output}...")
    merge_pdfs(pdf_paths, args.output)
    print("Merge complete.")

    # Optionally clean up individual PDFs
    if not args.keep_individual:
        for pdf in pdf_paths:
            os.remove(pdf)
        print("Removed individual PDF files.")

if __name__ == '__main__':
    main()
