"""Render original vector-style swap arrows as a multiresolution Windows ICO."""
from pathlib import Path
import math
import struct
import zlib


def distance(x, y, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = max(0, min(1, ((x-a[0])*dx+(y-a[1])*dy)/(dx*dx+dy*dy)))
    return math.hypot(x-a[0]-t*dx, y-a[1]-t*dy)


def png(size):
    scale = 3
    segments = [((.28,.38),(.72,.38)), ((.28,.38),(.42,.24)),
                ((.28,.38),(.42,.52)), ((.72,.64),(.28,.64)),
                ((.72,.64),(.58,.50)), ((.72,.64),(.58,.78))]
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            sums = [0, 0, 0, 0]
            for sy in range(scale):
                for sx in range(scale):
                    px, py = (x+(sx+.5)/scale)/size, (y+(sy+.5)/scale)/size
                    if math.hypot(px-.5, py-.5) > .46:
                        color = (0, 0, 0, 0)
                    elif min(distance(px, py, a, b) for a, b in segments) <= .025:
                        color = (255, 255, 255, 255)
                    else:
                        color = (0, 117, 240, 255)
                    sums = [a+b for a,b in zip(sums, color)]
            raw.extend(round(v/(scale*scale)) for v in sums)
    def chunk(tag, data):
        return struct.pack(">I", len(data))+tag+data+struct.pack(">I", zlib.crc32(tag+data))
    return b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR", struct.pack(">IIBBBBB", size,size,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b"")


if __name__ == "__main__":
    sizes = [16, 32, 48, 256]
    images = [png(size) for size in sizes]
    offset = 6+16*len(images)
    output = bytearray(struct.pack("<HHH", 0, 1, len(images)))
    for size, image in zip(sizes, images):
        output.extend(struct.pack("<BBBBHHII",size%256,size%256,0,0,1,32,len(image),offset))
        offset += len(image)
    for image in images:
        output.extend(image)
    target = Path(__file__).resolve().parents[1]/"src/WiFiSwitch.Windows/Assets/app.ico"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(output)
    print(target)
