import Foundation

enum AppLogger {
    private static let fileName = "notification-log.txt"
    private static let maxBytes = 512_000

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(fileName)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
        let data = Data(line.utf8)

        do {
            try trimIfNeeded(adding: data.count)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            print("[LOGGER] failed to write log: \(error)")
        }

        print(message)
    }

    static func readLog() -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    static func clear() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            log("[N1] cleared persistent notification log")
        } catch {
            print("[LOGGER] failed to clear log: \(error)")
        }
    }

    static func exportURL() -> URL? {
        FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private static func trimIfNeeded(adding incomingBytes: Int) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let currentSize = attrs[.size] as? NSNumber else {
            return
        }

        let total = currentSize.intValue + incomingBytes
        guard total > maxBytes else { return }

        guard let data = try? Data(contentsOf: fileURL),
              var text = String(data: data, encoding: .utf8) else {
            return
        }

        let target = maxBytes / 2
        while text.utf8.count > target {
            guard let newline = text.firstIndex(of: "\n") else { break }
            text.removeSubrange(text.startIndex...newline)
        }

        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }
}
