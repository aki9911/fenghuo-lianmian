"""Fetch only required official export templates using ZIP HTTP ranges."""
from pathlib import Path
import io
import urllib.request
import zipfile

URL = 'https://godot-releases.nbg1.your-objectstorage.com/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz'
OUT = Path(__file__).resolve().parents[1] / '.runtime/roaming/Godot/export_templates/4.7.2.stable'

class RemoteZip(io.RawIOBase):
    def __init__(self):
        self.pos = 0
        with urllib.request.urlopen(urllib.request.Request(URL, method='HEAD'), timeout=60) as response:
            self.length = int(response.headers['Content-Length'])
    def seekable(self): return True
    def tell(self): return self.pos
    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.length + offset
        return self.pos
    def read(self, size=-1):
        end = self.length - 1 if size < 0 else min(self.length - 1, self.pos + size - 1)
        if end < self.pos: return b''
        request = urllib.request.Request(URL, headers={'Range': f'bytes={self.pos}-{end}'})
        with urllib.request.urlopen(request, timeout=180) as response:
            if response.status != 206: raise RuntimeError('Server does not honor Range requests')
            data = response.read()
        self.pos += len(data)
        return data

if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    wanted = {'web_nothreads_release.zip', 'web_release.zip', 'windows_release_x86_64.exe', 'version.txt'}
    with zipfile.ZipFile(RemoteZip()) as archive:
        for entry in archive.infolist():
            name = Path(entry.filename).name
            if name not in wanted: continue
            target = OUT / name
            if target.exists() and target.stat().st_size == entry.file_size:
                print('Already present', name, flush=True)
                continue
            print('Downloading', name, entry.compress_size, flush=True)
            target.write_bytes(archive.read(entry))
            print('Saved', name, target.stat().st_size, flush=True)
