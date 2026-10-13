#!/usr/bin/env python3
"""Rectify a photographed page and save it as a PDF."""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import img2pdf
import numpy as np


def order_corners(points: np.ndarray) -> np.ndarray:
    """Return four points in top-left, top-right, bottom-right, bottom-left order."""
    points = points.reshape(4, 2).astype(np.float32)
    ordered = np.zeros((4, 2), dtype=np.float32)

    sums = points.sum(axis=1)
    differences = np.diff(points, axis=1).ravel()

    ordered[0] = points[np.argmin(sums)]        # Top left
    ordered[2] = points[np.argmax(sums)]        # Bottom right
    ordered[1] = points[np.argmin(differences)] # Top right
    ordered[3] = points[np.argmax(differences)] # Bottom left

    return ordered


def detect_page(image: np.ndarray) -> np.ndarray | None:
    """Find the largest clear four-corner page outline in the image."""
    image_height, image_width = image.shape[:2]
    image_area = image_height * image_width

    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blurred, 50, 160)

    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    edges = cv2.dilate(edges, kernel, iterations=1)
    edges = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, kernel)

    contours, _ = cv2.findContours(
        edges,
        cv2.RETR_LIST,
        cv2.CHAIN_APPROX_SIMPLE,
    )

    contours = sorted(contours, key=cv2.contourArea, reverse=True)

    for contour in contours[:150]:
        if cv2.contourArea(contour) < 0.05 * image_area:
            break

        x, y, width, height = cv2.boundingRect(contour)

        # Ignore contours that touch the photo border.
        if (
            x <= 2
            or y <= 2
            or x + width >= image_width - 2
            or y + height >= image_height - 2
        ):
            continue

        perimeter = cv2.arcLength(contour, True)

        for fraction in (0.015, 0.02, 0.03):
            polygon = cv2.approxPolyDP(
                contour,
                fraction * perimeter,
                True,
            )

            if len(polygon) == 4 and cv2.isContourConvex(polygon):
                return polygon.reshape(4, 2).astype(np.float32)

    return None


def choose_corners_manually(image: np.ndarray) -> np.ndarray | None:
    """Open a window to select the four page corners by mouse."""
    image_height, image_width = image.shape[:2]
    scale = min(1.0, 1400 / image_width, 1000 / image_height)

    display_width = max(1, round(image_width * scale))
    display_height = max(1, round(image_height * scale))
    display = cv2.resize(image, (display_width, display_height))

    scale_x = image_width / display_width
    scale_y = image_height / display_height
    selected: list[tuple[int, int]] = []
    window = "Select four page corners"

    def on_click(event: int, x: int, y: int, flags: int, data: object) -> None:
        if event == cv2.EVENT_LBUTTONDOWN and len(selected) < 4:
            selected.append((x, y))
        elif event == cv2.EVENT_RBUTTONDOWN and selected:
            selected.pop()

    cv2.namedWindow(window)
    cv2.setMouseCallback(window, on_click)

    while True:
        canvas = display.copy()
        cv2.putText(
            canvas,
            "Click four corners; Enter accepts; right-click undoes; Esc cancels",
            (12, 28),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (255, 0, 255),
            2,
            cv2.LINE_AA,
        )

        if len(selected) >= 2:
            points = np.array(selected, dtype=np.int32).reshape(-1, 1, 2)
            cv2.polylines(
                canvas,
                [points],
                isClosed=len(selected) == 4,
                color=(255, 0, 255),
                thickness=2,
            )

        for number, point in enumerate(selected, start=1):
            cv2.circle(canvas, point, 7, (255, 0, 255), -1)
            cv2.putText(
                canvas,
                str(number),
                (point[0] + 8, point[1] - 8),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.7,
                (255, 0, 255),
                2,
                cv2.LINE_AA,
            )

        cv2.imshow(window, canvas)
        key = cv2.waitKey(30) & 0xFF

        if key in (10, 13) and len(selected) == 4:
            break
        if key == 27:
            cv2.destroyWindow(window)
            return None

    cv2.destroyWindow(window)

    original_points = np.array(
        [(x * scale_x, y * scale_y) for x, y in selected],
        dtype=np.float32,
    )

    return original_points


def rectify_page(image: np.ndarray, corners: np.ndarray) -> np.ndarray:
    """Warp the selected four corners into a rectangular page image."""
    top_left, top_right, bottom_right, bottom_left = order_corners(corners)

    width_top = np.linalg.norm(top_right - top_left)
    width_bottom = np.linalg.norm(bottom_right - bottom_left)
    height_right = np.linalg.norm(bottom_right - top_right)
    height_left = np.linalg.norm(bottom_left - top_left)

    output_width = max(2, round(max(width_top, width_bottom)))
    output_height = max(2, round(max(height_right, height_left)))

    destination = np.array(
        [
            [0, 0],
            [output_width - 1, 0],
            [output_width - 1, output_height - 1],
            [0, output_height - 1],
        ],
        dtype=np.float32,
    )

    transform = cv2.getPerspectiveTransform(
        np.array([top_left, top_right, bottom_right, bottom_left],
                 dtype=np.float32),
        destination,
    )

    return cv2.warpPerspective(image, transform, (output_width, output_height))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Detect a page in a photo, straighten it, and save a PDF."
    )
    parser.add_argument("image", type=Path, help="Input JPEG or other image")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("document.pdf"),
        help="Output PDF path (default: document.pdf)",
    )
    parser.add_argument(
        "--manual",
        action="store_true",
        help="Select the four page corners with the mouse",
    )
    args = parser.parse_args()

    image = cv2.imread(str(args.image), cv2.IMREAD_COLOR)
    if image is None:
        parser.error(f"Could not read image: {args.image}")

    corners = (
        choose_corners_manually(image)
        if args.manual
        else detect_page(image)
    )

    if corners is None:
        parser.error(
            "Could not find a four-corner page. Try again with --manual."
        )

    corners = order_corners(corners)
    rectified = rectify_page(image, corners)

    output_pdf = args.output.expanduser()
    output_pdf.parent.mkdir(parents=True, exist_ok=True)

    base = output_pdf.with_suffix("")
    rectified_path = base.with_name(base.name + ".rectified.png")
    preview_path = base.with_name(base.name + ".corners.jpg")

    if not cv2.imwrite(str(rectified_path), rectified):
        parser.error(f"Could not save rectified image: {rectified_path}")

    preview = image.copy()
    preview_corners = np.round(corners).astype(np.int32).reshape(-1, 1, 2)
    cv2.polylines(
        preview,
        [preview_corners],
        isClosed=True,
        color=(255, 0, 255),
        thickness=max(2, round(max(image.shape[:2]) / 700)),
    )

    if not cv2.imwrite(str(preview_path), preview):
        parser.error(f"Could not save corner preview: {preview_path}")

    with output_pdf.open("wb") as pdf_file:
        pdf_file.write(img2pdf.convert(str(rectified_path)))

    print(f"PDF:             {output_pdf}")
    print(f"Rectified image: {rectified_path}")
    print(f"Corner preview:  {preview_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
