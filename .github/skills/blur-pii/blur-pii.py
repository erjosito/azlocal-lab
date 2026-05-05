#!/usr/bin/env python3
"""Redact PII from screenshots using OCR to find text and regex to match sensitive values.

Uses pytesseract (Tesseract OCR) to extract word-level bounding boxes,
then matches against known PII patterns (GUIDs, emails, subscription paths)
or user-provided known values. Only the matched regions are redacted.
"""

import argparse
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# Default patterns that indicate Azure PII
DEFAULT_PATTERNS: list[tuple[str, str]] = [
    ("guid", r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
    ("email", r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"),
    ("subscription-path", r"/subscriptions/[a-z0-9\-]+"),
]


def get_ocr_data(image: Image.Image) -> list[dict]:
    """Run Tesseract OCR and return word-level bounding boxes with text."""
    try:
        import pytesseract
    except ImportError:
        print("ERROR: pytesseract not installed. Run: pip install pytesseract", file=sys.stderr)
        print("       Also install Tesseract OCR: https://github.com/tesseract-ocr/tesseract", file=sys.stderr)
        sys.exit(1)

    # Get word-level data with bounding boxes
    data = pytesseract.image_to_data(image, output_type=pytesseract.Output.DICT)
    words = []
    for i in range(len(data["text"])):
        text = data["text"][i].strip()
        if not text:
            continue
        words.append({
            "text": text,
            "x": data["left"][i],
            "y": data["top"][i],
            "w": data["width"][i],
            "h": data["height"][i],
            "conf": int(data["conf"][i]),
            "line_num": data["line_num"][i],
            "block_num": data["block_num"][i],
        })
    return words


def group_words_into_lines(words: list[dict]) -> list[dict]:
    """Group consecutive words into lines based on block/line numbers."""
    lines: dict[tuple[int, int], list[dict]] = {}
    for w in words:
        key = (w["block_num"], w["line_num"])
        lines.setdefault(key, []).append(w)

    result = []
    for key in sorted(lines.keys()):
        line_words = lines[key]
        text = " ".join(w["text"] for w in line_words)
        x1 = min(w["x"] for w in line_words)
        y1 = min(w["y"] for w in line_words)
        x2 = max(w["x"] + w["w"] for w in line_words)
        y2 = max(w["y"] + w["h"] for w in line_words)
        result.append({
            "text": text,
            "words": line_words,
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        })
    return result


def find_matches_in_lines(lines: list[dict], patterns: list[tuple[str, str]],
                          known_values: list[str]) -> list[dict]:
    """Find PII matches in OCR lines and map back to pixel regions."""
    matches = []

    for line in lines:
        line_text = line["text"]
        line_words = line["words"]

        # Check each pattern
        for pattern_name, pattern_re in patterns:
            for m in re.finditer(pattern_re, line_text, re.IGNORECASE):
                region = get_region_for_match(line_words, line_text, m.start(), m.end())
                if region:
                    matches.append({
                        "reason": pattern_name,
                        "matched_text": m.group(),
                        **region,
                    })

        # Check known values (fuzzy match to handle OCR character confusion)
        for known in known_values:
            match_pos = fuzzy_find(line_text, known, max_errors=3)
            if match_pos is not None:
                idx, end = match_pos
                region = get_region_for_match(line_words, line_text, idx, end)
                if region:
                    matches.append({
                        "reason": "known-value",
                        "matched_text": known,
                        **region,
                    })

    return matches


def fuzzy_find(text: str, pattern: str, max_errors: int = 3) -> tuple[int, int] | None:
    """Find pattern in text allowing character substitutions for OCR errors.
    
    OCR commonly confuses: 8/B, 0/O, 1/l/I, 5/S, f/t, c/¢, etc.
    Error tolerance scales with pattern length: ~20% of characters can differ.
    """
    text_lower = text.lower()
    pattern_lower = pattern.lower()
    plen = len(pattern_lower)

    # Scale tolerance: allow ~20% errors for longer strings (GUIDs are 36 chars)
    tolerance = max(max_errors, plen // 5)

    # Exact match first
    idx = text_lower.find(pattern_lower)
    if idx != -1:
        return (idx, idx + plen)

    # Sliding window fuzzy match
    if plen > len(text_lower):
        return None

    best_errors = tolerance + 1
    best_pos = -1
    for i in range(len(text_lower) - plen + 1):
        window = text_lower[i:i + plen]
        errors = sum(1 for a, b in zip(window, pattern_lower) if a != b)
        if errors < best_errors:
            best_errors = errors
            best_pos = i

    if best_errors <= tolerance:
        return (best_pos, best_pos + plen)

    return None


def get_region_for_match(words: list[dict], line_text: str,
                         char_start: int, char_end: int) -> dict | None:
    """Map character positions in the joined line text back to pixel bounding boxes."""
    # Build a map: for each character position in line_text, which word index owns it
    char_to_word: list[int] = []
    pos = 0
    for i, w in enumerate(words):
        text = w["text"]
        # Account for the space between words
        if i > 0:
            char_to_word.append(i - 1)  # space belongs to gap
            pos += 1
        for _ in text:
            char_to_word.append(i)
            pos += 1

    if char_start >= len(char_to_word) or char_end > len(char_to_word):
        return None

    # Find which words are covered by the match
    covered_word_indices = set(char_to_word[char_start:char_end])
    covered_words = [words[i] for i in sorted(covered_word_indices) if i < len(words)]

    if not covered_words:
        return None

    x1 = min(w["x"] for w in covered_words)
    y1 = min(w["y"] for w in covered_words)
    x2 = max(w["x"] + w["w"] for w in covered_words)
    y2 = max(w["y"] + w["h"] for w in covered_words)

    return {"x1": x1, "y1": y1, "x2": x2, "y2": y2}


def redact_regions(image: Image.Image, regions: list[dict], method: str = "fill") -> Image.Image:
    """Redact regions in the image. Methods: 'fill' (match background) or 'blur' (gaussian blur)."""
    import numpy as np
    img = image.copy()

    if method == "blur":
        for r in regions:
            box = (r["x1"], r["y1"], r["x2"], r["y2"])
            region_crop = img.crop(box)
            blurred = region_crop.filter(ImageFilter.GaussianBlur(radius=15))
            img.paste(blurred, box)
    else:  # fill with sampled background color
        arr = np.array(img)
        draw = ImageDraw.Draw(img)
        for r in regions:
            pad = 2
            x1, y1 = max(0, r["x1"] - pad), max(0, r["y1"] - pad)
            x2, y2 = min(img.width - 1, r["x2"] + pad), min(img.height - 1, r["y2"] + pad)
            bg_color = sample_background_color(arr, x1, y1, x2, y2)
            draw.rectangle([x1, y1, x2, y2], fill=bg_color)

    return img


def sample_background_color(arr, x1: int, y1: int, x2: int, y2: int) -> tuple:
    """Sample the dominant background color around a region by looking at edge pixels."""
    import numpy as np
    h, w = arr.shape[:2]
    samples = []

    # Sample pixels just outside the region edges (5px margin)
    margin = 5
    # Above the region
    if y1 - margin >= 0:
        samples.extend(arr[y1 - margin, x1:x2].tolist())
    # Below the region
    if y2 + margin < h:
        samples.extend(arr[y2 + margin, x1:x2].tolist())
    # Left of region
    if x1 - margin >= 0:
        samples.extend(arr[y1:y2, x1 - margin].tolist())
    # Right of region
    if x2 + margin < w:
        samples.extend(arr[y1:y2, x2 + margin].tolist())

    if not samples:
        return (255, 255, 255)

    # Filter out dark pixels (those are likely text, not background)
    bg_pixels = [p for p in samples if sum(p[:3]) > 400]  # keep lighter pixels
    if not bg_pixels:
        bg_pixels = samples

    # Return the median color
    bg_arr = np.array(bg_pixels)
    median = tuple(int(v) for v in np.median(bg_arr[:, :3], axis=0))
    return median


def parse_region_str(s: str) -> dict:
    """Parse 'x1,y1,x2,y2' string into a region dict."""
    parts = [int(x.strip()) for x in s.split(",")]
    if len(parts) != 4:
        raise ValueError(f"Region must have 4 values (x1,y1,x2,y2), got: {s}")
    return {"x1": parts[0], "y1": parts[1], "x2": parts[2], "y2": parts[3], "reason": "manual"}


def process_image(image_path: Path, args: argparse.Namespace) -> None:
    """Process a single image file."""
    print(f"\n{'='*60}")
    print(f"Processing: {image_path}")

    img = Image.open(image_path)
    if img.mode == "RGBA":
        img = img.convert("RGB")

    # If explicit regions provided, just redact those
    if args.regions:
        regions = [parse_region_str(r) for r in args.regions]
        print(f"  Redacting {len(regions)} manual region(s)")
        result = redact_regions(img, regions, method=args.method)
        result.save(image_path)
        print(f"  Saved: {image_path}")
        return

    # OCR the image
    print("  Running OCR...")
    words = get_ocr_data(img)
    print(f"  Found {len(words)} words")

    lines = group_words_into_lines(words)

    # Build pattern list
    patterns = list(DEFAULT_PATTERNS)
    for p in (args.patterns or []):
        patterns.append(("custom", p))

    # Find matches
    matches = find_matches_in_lines(lines, patterns, args.known_values or [])

    if args.scan:
        # Report mode — don't modify
        print(f"\n  OCR lines found:")
        for line in lines:
            print(f"    [{line['x1']},{line['y1']} - {line['x2']},{line['y2']}] {line['text'][:80]}")
        print(f"\n  PII matches found: {len(matches)}")
        for m in matches:
            print(f"    [{m['x1']},{m['y1']} - {m['x2']},{m['y2']}] "
                  f"({m['reason']}) \"{m['matched_text'][:40]}\"")
        return

    if not matches:
        print("  No PII matches found. Image unchanged.")
        return

    # Deduplicate overlapping regions
    unique_regions = deduplicate_regions(matches)
    print(f"  Redacting {len(unique_regions)} region(s):")
    for m in unique_regions:
        print(f"    ({m.get('reason', 'unknown')}) \"{m.get('matched_text', '')[:40]}\"")

    result = redact_regions(img, unique_regions, method=args.method)
    result.save(image_path)
    print(f"  Saved: {image_path}")


def deduplicate_regions(regions: list[dict]) -> list[dict]:
    """Remove regions that are fully contained within another region."""
    if not regions:
        return []

    # Sort by area (largest first)
    sorted_regions = sorted(regions, key=lambda r: (r["x2"] - r["x1"]) * (r["y2"] - r["y1"]), reverse=True)
    result = []

    for r in sorted_regions:
        is_contained = False
        for existing in result:
            if (r["x1"] >= existing["x1"] and r["y1"] >= existing["y1"]
                    and r["x2"] <= existing["x2"] and r["y2"] <= existing["y2"]):
                is_contained = True
                break
        if not is_contained:
            result.append(r)

    return result


def main():
    parser = argparse.ArgumentParser(
        description="Redact PII from screenshots using OCR + regex matching.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  # Scan image to see what OCR finds (no modifications)
  python blur-pii.py --scan screenshot.png

  # Redact all GUIDs and emails found via OCR
  python blur-pii.py screenshot.png

  # Redact only a specific known subscription ID
  python blur-pii.py --known-values "a8fbd8e1-fb5a-4411-804a-4ac80929c93c" screenshot.png

  # Redact explicit pixel regions (no OCR needed)
  python blur-pii.py --regions "475,271,730,283" "1050,352,1540,370" screenshot.png

  # Use blur instead of white fill
  python blur-pii.py --method blur screenshot.png
""",
    )
    parser.add_argument("images", nargs="+", help="Image file(s) to process")
    parser.add_argument("--scan", action="store_true",
                        help="Report OCR text and PII matches without modifying the image")
    parser.add_argument("--known-values", nargs="*", default=[],
                        help="Specific sensitive strings to search for and redact")
    parser.add_argument("--patterns", nargs="*", default=[],
                        help="Additional regex patterns to match (beyond built-in GUID/email)")
    parser.add_argument("--regions", nargs="*", default=[],
                        help='Explicit regions to redact as "x1,y1,x2,y2" (skips OCR)')
    parser.add_argument("--method", choices=["fill", "blur"], default="fill",
                        help="Redaction method: white fill (default) or gaussian blur")
    parser.add_argument("--no-default-patterns", action="store_true",
                        help="Disable built-in GUID/email patterns (only use --known-values or --patterns)")

    args = parser.parse_args()

    for image_path_str in args.images:
        path = Path(image_path_str)
        if not path.exists():
            print(f"ERROR: File not found: {path}", file=sys.stderr)
            continue
        if path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"}:
            print(f"WARNING: Skipping non-image file: {path}", file=sys.stderr)
            continue
        process_image(path, args)


if __name__ == "__main__":
    main()
