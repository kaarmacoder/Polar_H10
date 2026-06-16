//
//  SessionWriter.swift
//  Polar H10
//
//  Writes a capture session's three CSV streams to disk incrementally. This
//  lets a recording run for hours, survive backgrounding / screen-lock /
//  system termination, and be finalized into a ZIP on stop — independent of
//  the bounded in-memory buffers used for the live charts.
//

import Foundation

final class SessionWriter: @unchecked Sendable {

    let stamp: String
    let directory: URL

    /// All FileHandle access happens on this serial queue, so streaming bursts
    /// never block the main thread with synchronous disk I/O.
    private let ioQueue = DispatchQueue(label: "com.polarh10.session.io", qos: .utility)

    private var hrHandle: FileHandle?
    private var ecgHandle: FileHandle?
    private var accHandle: FileHandle?

    static let hrHeader  = "time_iso,bpm,rr_ms,contact\n"
    static let ecgHeader = "index,timestamp_ns,microvolts\n"
    static let accHeader = "index,timestamp_ns,x_mg,y_mg,z_mg\n"

    /// Persistent folder that survives relaunch (Application Support / Sessions).
    static func sessionsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// - Parameter resume: when true, reopens existing files (after a relaunch)
    ///   and appends instead of rewriting headers.
    init?(stamp: String, resume: Bool) {
        self.stamp = stamp
        self.directory = SessionWriter.sessionsRoot()
            .appendingPathComponent("PolarH10_\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        hrHandle  = SessionWriter.open(directory.appendingPathComponent("\(stamp)_heart_rate.csv"),
                                       header: SessionWriter.hrHeader, resume: resume)
        ecgHandle = SessionWriter.open(directory.appendingPathComponent("\(stamp)_ecg.csv"),
                                       header: SessionWriter.ecgHeader, resume: resume)
        accHandle = SessionWriter.open(directory.appendingPathComponent("\(stamp)_motion.csv"),
                                       header: SessionWriter.accHeader, resume: resume)
    }

    private static func open(_ url: URL, header: String, resume: Bool) -> FileHandle? {
        let fm = FileManager.default
        if !resume || !fm.fileExists(atPath: url.path) {
            // `completeUntilFirstUserAuthentication` keeps the file writable while
            // the device is locked (required for background streaming).
            fm.createFile(atPath: url.path, contents: Data(header.utf8),
                          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }

    // Appends are dispatched asynchronously to the serial I/O queue — they never
    // block the caller (the BLE callbacks run on the main actor).
    func appendHr(_ s: String)  { let d = Data(s.utf8); ioQueue.async { [weak self] in try? self?.hrHandle?.write(contentsOf: d) } }
    func appendEcg(_ s: String) { let d = Data(s.utf8); ioQueue.async { [weak self] in try? self?.ecgHandle?.write(contentsOf: d) } }
    func appendAcc(_ s: String) { let d = Data(s.utf8); ioQueue.async { [weak self] in try? self?.accHandle?.write(contentsOf: d) } }

    /// Flush and close all files. Synchronous on the I/O queue, so it waits for
    /// any pending async writes to finish first.
    func close() {
        ioQueue.sync {
            for h in [hrHandle, ecgHandle, accHandle] {
                try? h?.synchronize()
                try? h?.close()
            }
            hrHandle = nil; ecgHandle = nil; accHandle = nil
        }
    }

    /// Zip the session directory into the temp dir for sharing. No third-party
    /// dependency — uses NSFileCoordinator's `.forUploading` option.
    /// Call off the main thread — it flushes the files and zips synchronously.
    func makeZip() -> URL? {
        close()
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: URL?
        coordinator.coordinate(readingItemAt: directory, options: [.forUploading], error: &coordError) { zipped in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("PolarH10_\(stamp).zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipped, to: dest)) != nil {
                result = dest
            }
        }
        return result
    }
}
