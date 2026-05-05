---
name: blur-pii
description: Detects and redacts PII (subscription IDs, tenant IDs, resource GUIDs, email addresses) from screenshot images using OCR. Use when asked to blur, redact, or clean screenshots of sensitive information.
allowed-tools:
  - shell
---

Use this skill when the user wants to blur, redact, or clean sensitive data from screenshots before sharing them.

## What to run

Run the Python helper against the target image file(s):

```bash
python .github/skills/blur-pii/blur-pii.py <image-path> [more-images...]
```

### Dependencies

```bash
pip install Pillow pytesseract
```

Tesseract OCR must also be installed on the system:
- **Windows**: Download from https://github.com/UB-Mannheim/tesseract/wiki
- **macOS**: `brew install tesseract`
- **Linux**: `apt install tesseract-ocr`

## How the script works

1. Opens each image with Pillow and converts RGBA → RGB if needed.
2. Runs **Tesseract OCR** via pytesseract to extract word-level bounding boxes with text.
3. Groups words into text lines.
4. Matches each line against regex patterns (GUIDs, emails, subscription paths) and user-provided known values.
5. Only redacts the **specific bounding boxes** where PII was matched — nothing else is touched.
6. Saves the image (overwrites original).

## Sensitive patterns detected by default

- **GUIDs** — `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (subscription IDs, tenant IDs, resource IDs)
- **Email addresses** — `user@domain.com`
- **Subscription paths** — `/subscriptions/xxxx-...`

## Modes

| Flag | Purpose |
|------|---------|
| `--scan` | OCR the image and report matches **without modifying** it |
| `--known-values` | Only redact these specific strings (still uses OCR to locate them) |
| `--patterns` | Add custom regex patterns beyond the defaults |
| `--regions "x1,y1,x2,y2"` | Skip OCR entirely; redact explicit pixel rectangles |
| `--method blur` | Use gaussian blur instead of white fill |
| `--no-default-patterns` | Disable built-in patterns (use only --known-values or --patterns) |

## Examples

```bash
# Scan to see what OCR finds (dry-run, no changes)
python .github/skills/blur-pii/blur-pii.py --scan screenshot.png

# Redact all GUIDs and emails automatically
python .github/skills/blur-pii/blur-pii.py screenshot.png

# Redact only a specific subscription ID
python .github/skills/blur-pii/blur-pii.py --known-values "a8fbd8e1-fb5a-4411-804a-4ac80929c93c" exercises/screenshots/ex01/*.png

# Redact explicit pixel regions (no OCR needed, no Tesseract needed)
python .github/skills/blur-pii/blur-pii.py --regions "475,271,730,283" screenshot.png

# Use blur instead of white rectangles
python .github/skills/blur-pii/blur-pii.py --method blur --known-values "my-tenant-id" screenshot.png
```

## Workflow for Copilot

1. **First**: Run `--scan` to see what OCR detects and which lines match PII patterns.
2. **Then**: Either use `--known-values` with the user's specific sensitive values, or use `--regions` with coordinates found in step 1.
3. **Verify**: Open the image to confirm only the intended data was redacted.

Prefer `--known-values` over bare execution — this ensures only the user's actual secrets are redacted, not random GUIDs that might be non-sensitive (like well-known Azure service IDs).
