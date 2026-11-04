/// Called with the bytes a save has written so far, and the size of the file
/// if known. The size is nil for a download without a usable `Content-Length`.
typealias ProgressHandler = (_ bytesWritten: Int64, _ totalBytes: Int64?) -> Void
