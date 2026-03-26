from pathlib import Path

def pdf_escape(data: bytes) -> bytes:
    return data.replace(b'\\', b'\\\\').replace(b'(', b'\\(').replace(b')', b'\\)')

img_dir = Path(r'e:\CanvasProjcet\docs\rendered')
out_pdf = Path(r'e:\CanvasProjcet\docs\main_android_explained.pdf')
images = sorted(img_dir.glob('page_*.jpg'))
if not images:
    raise SystemExit('no images found')

page_w_pt = 595.0
page_h_pt = 842.0
objects = []
page_refs = []

# 1 catalog, 2 pages reserved later
objects.append(None)
objects.append(None)

for idx, img_path in enumerate(images, start=1):
    img_bytes = img_path.read_bytes()
    img_obj_num = len(objects) + 1
    page_obj_num = img_obj_num + 1
    content_obj_num = img_obj_num + 2

    image_obj = b"<< /Type /XObject /Subtype /Image /Width 1240 /Height 1754 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " + str(len(img_bytes)).encode() + b" >>\nstream\n" + img_bytes + b"\nendstream"
    objects.append(image_obj)

    content_stream = f"q\n{page_w_pt} 0 0 {page_h_pt} 0 0 cm\n/Im{idx} Do\nQ\n".encode()
    content_obj = b"<< /Length " + str(len(content_stream)).encode() + b" >>\nstream\n" + content_stream + b"endstream"
    objects.append(None)  # placeholder for page, index page_obj_num-1
    objects.append(content_obj)

    page_obj = (
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_w_pt} {page_h_pt}] ".encode()
        + f"/Resources << /XObject << /Im{idx} {img_obj_num} 0 R >> >> ".encode()
        + f"/Contents {content_obj_num} 0 R >>".encode()
    )
    objects[page_obj_num - 1] = page_obj
    page_refs.append(f"{page_obj_num} 0 R")

pages_obj = ("<< /Type /Pages /Count {count} /Kids [{kids}] >>".format(count=len(page_refs), kids=' '.join(page_refs))).encode()
catalog_obj = b"<< /Type /Catalog /Pages 2 0 R >>"
objects[0] = catalog_obj
objects[1] = pages_obj

pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = [0]
for i, obj in enumerate(objects, start=1):
    offsets.append(len(pdf))
    pdf.extend(f"{i} 0 obj\n".encode())
    pdf.extend(obj)
    pdf.extend(b"\nendobj\n")

xref_offset = len(pdf)
pdf.extend(f"xref\n0 {len(objects)+1}\n".encode())
pdf.extend(b"0000000000 65535 f \n")
for off in offsets[1:]:
    pdf.extend(f"{off:010d} 00000 n \n".encode())
pdf.extend(b"trailer\n")
pdf.extend(f"<< /Size {len(objects)+1} /Root 1 0 R >>\n".encode())
pdf.extend(b"startxref\n")
pdf.extend(f"{xref_offset}\n%%EOF".encode())
out_pdf.write_bytes(pdf)
print(f"created={out_pdf}")
