# Validation-only unique family; never install or distribute the modified font.
# Run from repository root, then build application-fallback-probe.cpp with Qt 6.11.2 Gui.
import struct
from pathlib import Path
source = Path('windows/assets/nerd-font-symbols/SymbolsNerdFontMono-Regular.ttf')
target = Path('windows/.local/font-probe/AppOnly.ttf')
data = bytearray(source.read_bytes().replace(b'Symbols', b'AppOnly').replace('Symbols'.encode('utf-16-be'), 'AppOnly'.encode('utf-16-be')))
tables = [struct.unpack_from('>4sIII', data, 12 + i * 16) for i in range(struct.unpack_from('>H', data, 4)[0])]
head = next(offset for tag, _, offset, length in tables if tag == b'head')
struct.pack_into('>I', data, head + 8, 0)
def checksum(block):
    block = bytes(block) + b'\0' * (-len(block) % 4)
    return sum(struct.unpack('>' + 'I' * (len(block) // 4), block)) & 0xffffffff
for i, (tag, _, offset, length) in enumerate(tables):
    struct.pack_into('>I', data, 16 + i * 16, checksum(data[offset:offset + length]))
struct.pack_into('>I', data, head + 8, (0xB1B0AFBA - checksum(data)) & 0xffffffff)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(data)