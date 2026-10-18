#!/usr/bin/env python3
"""Writes synthetic-auth-copyrect-resize.bin: the server half of an RFB 3.8 session that uses VNC
Authentication (password "secret", challenge "0123456789abcdef"), a 4x3 Raw update, a bell, a
CopyRect update, cut text, a DesktopSize change to 6x2 followed by Raw, and prints the SHA-256 of
the BGRX framebuffer after each update. Run: python3 -I synthetic.py <out.bin>"""
import hashlib, struct, sys

out = bytearray()
out += b"RFB 003.008\n"
out += bytes([1, 2])                      # one security type: VNC Authentication
out += b"0123456789abcdef"                # challenge
out += struct.pack(">I", 0)               # SecurityResult OK
out += struct.pack(">HH", 4, 3)           # ServerInit 4x3
out += bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
out += struct.pack(">I", 9) + b"synthetic"

w, h = 4, 3
fb = bytearray(w * h * 4)
def px(i):
    return bytes([(i * 37) % 256, (i * 91) % 256, (i * 13 + 7) % 256, 0])
def rect(x, y, rw, rh, enc):
    return struct.pack(">HHHHi", x, y, rw, rh, enc)
def put(x, y, rw, rh, data):
    for r in range(rh):
        o = ((y + r) * w + x) * 4
        fb[o:o + rw * 4] = data[r * rw * 4:(r + 1) * rw * 4]
hashes = []

# Update 1: full Raw.
data = b"".join(px(i) for i in range(w * h))
out += bytes([0, 0]) + struct.pack(">H", 1) + rect(0, 0, w, h, 0) + data
put(0, 0, w, h, data); hashes.append(hashlib.sha256(fb).hexdigest())

out += bytes([2])                         # Bell

# Update 2: CopyRect 2x2 from (0,0) to (1,1) (overlapping), plus a 1x1 Raw at (3,0).
src = bytes(fb)
block = b"".join(src[((0 + r) * w + 0) * 4:((0 + r) * w + 2) * 4] for r in range(2))
one = bytes([1, 2, 3, 0])
out += bytes([0, 0]) + struct.pack(">H", 2)
out += rect(1, 1, 2, 2, 1) + struct.pack(">HH", 0, 0)
out += rect(3, 0, 1, 1, 0) + one
put(1, 1, 2, 2, block); put(3, 0, 1, 1, one); hashes.append(hashlib.sha256(fb).hexdigest())

out += bytes([3, 0, 0, 0]) + struct.pack(">I", 5) + b"hello"  # ServerCutText

# Update 3: DesktopSize 6x2 then Raw covering the left 3x2 (the rest stays black).
w, h = 6, 2
fb = bytearray(w * h * 4)
data = b"".join(px(100 + i) for i in range(6))
out += bytes([0, 0]) + struct.pack(">H", 2) + rect(0, 0, 6, 2, -223) + rect(0, 0, 3, 2, 0) + data
put(0, 0, 3, 2, data); hashes.append(hashlib.sha256(fb).hexdigest())

open(sys.argv[1], "wb").write(out)
for i, digest in enumerate(hashes, 1):
    print(f"update {i}: {digest}")
