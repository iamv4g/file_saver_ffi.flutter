# Web – Limitations

Saving files on **Flutter Web** is fundamentally different from mobile and desktop platforms due to browser security restrictions.

## How Downloads Work

The download mechanism depends on which API and arguments are used:

| API           | Scenario              | Mechanism                                             | CORS required | Progress                    |
|---------------|-----------------------|-------------------------------------------------------|---------------|-----------------------------|
| `saveBytes`   | —                     | Blob → `<a download>`                                 | ❌            | ❌                          |
| `saveNetwork` | No custom `headers`   | `<a href=url download>` — browser native streaming    | ❌            | ❌                          |
| `saveNetwork` | With custom `headers` | `window.fetch()` → Blob → `<a download>`              | ✅            | ✅ (fraction needs `Content-Length`) |
| `saveAs`      | Chrome / Edge 86+     | FSA: streams chunks directly to disk (zero RAM)       | Only for `SaveNetworkInput` | ✅ (fraction needs `Content-Length`) |
| `saveAs`      | Firefox / Safari      | Falls back to `saveBytes` / `saveNetwork` above       | As above      | As above                    |
| `openWrite`   | —                     | Chunks buffered in memory → Blob → `<a download>` on `close()` | ❌     | ✅ (needs `totalSize`)      |
| `openWriteAs` | Chrome / Edge 86+     | FSA: each chunk written to disk before the next       | ❌            | ✅ (needs `totalSize`)      |
| `openWriteAs` | Firefox / Safari      | Falls back to `openWrite` above                       | ❌            | ✅ (needs `totalSize`)      |

"Fraction needs `Content-Length`": every chunk reports `SaveProgressUpdate.bytesWritten`. A response without `Content-Length`, or with `Content-Encoding` (the header counts the compressed bytes, the body is decompressed), has an unknown size: `totalBytes` is null and `progress` stays 0.0.

The sections below explain each limitation that flows from these mechanisms.

---

## 1. Browser-Controlled Downloads

When using `saveNetwork` or `saveBytes` without the File System Access API, the browser controls where the file is saved. You cannot programmatically choose a directory, and the final behavior depends on server headers and browser settings.

This is a browser security constraint and cannot be overridden. It also means that for a browser download:

- `saveLocation`, `subDir` and `conflictResolution` are ignored. The browser picks the folder and renames on a conflict (`file (1).pdf`) itself.
- `timeout` is ignored by `saveNetwork` without `headers`: the browser runs that download.
- `SaveProgressComplete` means the download was handed to the browser, not that the file is on disk. For `saveNetwork` without `headers` it comes right away, even when the browser then opens the file in a tab (§2) or the download fails.
- A Blob download keeps its object URL, and with it the bytes, for 60 s after the click, because revoking it at once can cancel the download in some browsers.

---

## 2. Media / PDF Files May Open Instead of Download

When `saveNetwork` is called without custom headers, the library uses `<a href=url download>` (anchor element). For **cross-origin URLs**, the browser ignores the `download` attribute entirely and instead respects the server's `Content-Disposition` header.

The file opens in the current tab (instead of downloading) in either of these cases:

| Server `Content-Disposition` | Result                                                        |
|------------------------------|---------------------------------------------------------------|
| `attachment; filename="..."` | ✅ Downloaded                                                  |
| `inline; filename="..."`     | ❌ Opens in tab                                                |
| *(absent)*                   | ❌ Opens in tab for viewable types (PDF, images, audio, video) |

### To Force Download

Your server must return:

```
Content-Disposition: attachment; filename="file.ext"
```

> The `download` attribute on `<a>` elements is **not** sufficient for cross-origin files — the browser ignores it silently. Only same-origin URLs respect the `download` attribute unconditionally.

---

## 3. Custom Headers Require `fetch()` (Memory Usage)

If you pass custom HTTP headers:

```dart
saveNetwork(
  url: '...',
  headers: {'Authorization': 'Bearer ...'},
)
```

The browser must use `fetch()` instead of native anchor download. This means the file is loaded into memory (RAM) as a Blob before the download is triggered. Large files may consume significant memory.

**Recommendation:** For large files, avoid custom headers when possible, or use `saveAs()` with directory selection (see §5).

---

## 4. CORS Restrictions

`fetch()` (used when custom headers are present, or when using FSA streaming) is blocked by the browser if the server does not send the appropriate `Access-Control-Allow-Origin` header. The operation immediately yields `SaveProgressError(NetworkException(...))`.

| Scenario                                          | CORS required |
|---------------------------------------------------|---------------|
| `saveNetwork` without `headers` (anchor download) | ❌            |
| `saveNetwork` with custom `headers`               | ✅            |
| `saveAs` + `SaveNetworkInput` (FSA path)          | ✅            |

**Solutions:**
1. Configure `Access-Control-Allow-Origin: *` (or your app origin) on the server.
2. Route the request through a same-origin proxy.
3. Drop custom headers when authorization is not needed.

---

## 5. Zero-RAM Streaming (Recommended for Large Files)

When using `saveAs()` with a directory chosen via `pickDirectory()`, the package uses the **File System Access API (FSA)** to stream data directly to disk — chunk by chunk — without ever loading the full file into memory.

```dart
final directory = await FileSaver.pickDirectory();

await FileSaver.saveAsAsync(
  input: SaveNetworkInput(url: 'https://example.com/large-file.zip'),
  fileName: 'large_file',
  fileType: CustomFileType(ext: 'zip', mimeType: 'application/zip'),
  saveLocation: directory,
  onProgress: (p) => print('${(p * 100).toInt()}%'),
);
```

**Benefits:** no full file in memory, supports GB+ files, real progress reporting, timeout handling.

**Supported browsers:** Chrome 86+, Edge 86+, and other Chromium-based browsers.

**Not supported:** Firefox, Safari — `saveAs()` falls back to browser-controlled download automatically.

**Conflicts:** the File System Access API can't create a file only if it doesn't exist yet. The package keeps track of the names its own saves are writing, so saves of the same name in the same page at the same time each get their own file (`autoRename`) or fail (`fail`). A file that another tab or app creates in the directory at the same moment can still get the same name, and then one save replaces the other.

---

## 6. `saveAs()` Fallback Behavior

On browsers without `showDirectoryPicker()` (Firefox / Safari):

- `pickDirectory()` throws an `UnsupportedError`.
- `saveAs()` and `openWriteAs()` (when called with `saveLocation: null`) catch it and fall back: `saveAs()` to a standard browser download, `openWriteAs()` to a sink that buffers in memory and downloads on `close()`.
- The browser controls the save location; zero-RAM streaming is not available.

Any other picker failure, such as calling it without a user gesture, is not a fallback: `pickDirectory()` and `openWriteAs()` throw a `NativePlatformException`, and `saveAs()` emits a `SaveProgressError`.

---

## 7. Keeping a Picked Directory

`persistDirectory()` stores the directory handle in IndexedDB and returns a token; `restoreDirectory(token)` gives it back on a later visit, and `releaseDirectory(token)` deletes it.

The browser decides whether the page may still write to a restored directory. Chrome keeps the permission while another tab of the site has it, or for good when the user chose "Allow on every visit". Otherwise, ask again from a button:

```dart
final location = await FileSaver.restoreDirectory(token);
if (location is WebPickedDirectoryLocation && !await location.hasAccess()) {
  // In an onPressed handler: the prompt needs a user gesture.
  if (!await location.requestAccess()) return;
}
```

A save into a directory the page can't write to fails with `PermissionDeniedException`.

---

## 8. Returned URIs and Unsupported APIs

Browsers don't expose file paths, so the `Uri` of `SaveProgressComplete` (and of `saveAsync`, `saveAsAsync` and `FileSaverSink.result`) only names the file:

| URI                        | Returned by                                                  |
|----------------------------|--------------------------------------------------------------|
| `browser-download:<name>`  | A browser download: `saveBytes`, `saveNetwork`, `openWrite`, and the fallbacks of `saveAs` / `openWriteAs` |
| `web-directory:<name>`     | A file in a picked directory: `saveAs`, `openWriteAs` (FSA)  |

`<name>` is the file name with its extension, after `autoRename` for `web-directory:`. Neither URI can be opened again.

Not supported on web:

- `saveFile` / `SaveInput.file` throws `InvalidInputException`: a page can't read a path on disk. Read the file into bytes first, for example with a file picker.
- `canOpenFile` and `openFile` throw `UnsupportedError`: the browser owns downloaded files.

## 9. Write Sessions (`openWrite` / `openWriteAs`)

- `openWrite` always buffers every chunk in memory and downloads one Blob on `close()`. `saveLocation`, `subDir` and `conflictResolution` are ignored, as for any browser download. `cancel()` drops the buffer and downloads nothing.
- `openWriteAs` with a picked directory writes each chunk to the file before the next one, without holding the file in memory. `conflictResolution` applies: `autoRename` picks a free name, `skip` returns `null` for an existing file, `fail` throws `FileExistsException`. `cancel()` deletes a file it created and keeps the original of an `overwrite`, because the browser writes to a swap file until `close()`.
- `openWriteAs` without `showDirectoryPicker()` falls back to `openWrite` (§6).

---

## Recommended Setup for Reliable Web Downloads

1. Use Chromium-based browsers for the best experience.
2. Configure your server to send `Content-Disposition: attachment` for downloadable files.
3. Add `Access-Control-Allow-Origin` headers if you need custom HTTP headers or FSA streaming.
4. Use `pickDirectory()` + `saveAs()` for large files to avoid memory issues.

---

> These limitations are enforced by the browser to prevent silent file system access, unauthorized downloads, and cross-origin data leaks. They cannot be bypassed by JavaScript or Flutter Web.
