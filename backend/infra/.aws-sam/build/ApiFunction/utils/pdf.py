import base64
import io
from pdf2image import convert_from_bytes
from PIL import Image


def pdf_to_base64_images(pdf_bytes: bytes, dpi: int = 150) -> list[str]:
    """
    Convert PDF bytes to a list of base64-encoded PNG images.

    Args:
        pdf_bytes: Raw PDF file bytes
        dpi: Resolution for rendering (150 is good balance of quality/size)

    Returns:
        List of base64-encoded PNG strings (one per page)
    """
    # Convert PDF to images
    images = convert_from_bytes(pdf_bytes, dpi=dpi)

    base64_images = []
    for img in images:
        # Convert to PNG bytes
        buffer = io.BytesIO()
        img.save(buffer, format="PNG")
        buffer.seek(0)

        # Encode to base64
        b64 = base64.standard_b64encode(buffer.read()).decode("utf-8")
        base64_images.append(b64)

    return base64_images
