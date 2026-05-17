//
//  CSVMirrorPaths.swift
//  Steward — Track F
//
//  Resolves the on-disk layout for the iCloud Drive CSV mirror, per
//  spec §12 + addendum §1.4. Single source of truth for path strings so the
//  watcher, tools, and tests all agree on where files live.
//
//  Layout (under the ubiquity container's Documents/<folder>/ root):
//
//    Steward/
//      README.md
//      instruments/<domain>/<instrument_name>/
//        data.csv          ← read+write
//        state.csv         ← write-only from Steward; user edits ignored
//        README.txt
//      events/
//        events_YYYY-MM.csv
//
//  When iCloud Drive is unavailable (simulator without iCloud, etc.) the
//  resolver falls back to a sandboxed app-support folder so the app stays
//  usable. Tests inject `.directory(URL)` to point at a temp dir.
//

import Foundation

/// Where the CSV mirror writes. Tests use `.directory(temporary URL)` so they
/// never touch the real iCloud container.
enum CSVMirrorRoot: Sendable {
    /// Resolve `FileManager.url(forUbiquityContainerIdentifier:)` at access
    /// time. The container id is the entitlement Pod A landed
    /// (`iCloud.com.rajatscode.steward`).
    case ubiquityContainer(identifier: String, subfolder: String)
    /// Use the app's `Application Support/<subfolder>` directory. Triggered
    /// when iCloud Drive is disabled — keeps the app fully usable offline /
    /// without an iCloud account.
    case applicationSupport(subfolder: String)
    /// Explicit path. Tests use this.
    case directory(URL)
}

enum CSVMirrorPathError: Error, CustomStringConvertible {
    case ubiquityContainerUnavailable(identifier: String)
    case applicationSupportUnavailable
    case createDirectoryFailed(URL, underlying: Error)
    case invalidInstrumentName(String)

    var description: String {
        switch self {
        case .ubiquityContainerUnavailable(let id):
            return "iCloud ubiquity container not available for identifier \(id) — is iCloud Drive enabled?"
        case .applicationSupportUnavailable:
            return "Application Support directory not available"
        case .createDirectoryFailed(let url, let underlying):
            return "Failed to create directory \(url.path): \(underlying)"
        case .invalidInstrumentName(let name):
            return "Instrument name '\(name)' contains characters unsafe for a CSV path"
        }
    }
}

struct CSVMirrorPaths: Sendable {
    let rootURL: URL

    /// Build a resolver. On unavailable iCloud, falls back to Application
    /// Support so tools degrade gracefully (matches addendum §3 "iCloud Drive
    /// folder existence — read-only check; no permission prompt").
    static func resolve(_ root: CSVMirrorRoot, fileManager: FileManager = .default) throws -> CSVMirrorPaths {
        switch root {
        case .directory(let url):
            try ensureDirectory(at: url, fileManager: fileManager)
            return CSVMirrorPaths(rootURL: url)

        case .applicationSupport(let subfolder):
            guard let base = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) else {
                throw CSVMirrorPathError.applicationSupportUnavailable
            }
            let root = base.appendingPathComponent(subfolder, isDirectory: true)
            try ensureDirectory(at: root, fileManager: fileManager)
            return CSVMirrorPaths(rootURL: root)

        case .ubiquityContainer(let identifier, let subfolder):
            // Apple's docs: call this off the main thread. The actor that
            // owns CSVMirrorWatcher already hops off main, so this is safe.
            guard let container = fileManager.url(forUbiquityContainerIdentifier: identifier) else {
                throw CSVMirrorPathError.ubiquityContainerUnavailable(identifier: identifier)
            }
            // The container's Documents/ subdirectory is what shows up in
            // Files.app under iCloud Drive when
            // NSUbiquitousContainerIsDocumentScopePublic is true (it is, per
            // Pod A's Info.plist).
            let root = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(subfolder, isDirectory: true)
            try ensureDirectory(at: root, fileManager: fileManager)
            return CSVMirrorPaths(rootURL: root)
        }
    }

    private static func ensureDirectory(at url: URL, fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CSVMirrorPathError.createDirectoryFailed(url, underlying: error)
        }
    }

    // MARK: - Layout

    var rootREADMEURL: URL {
        rootURL.appendingPathComponent("README.md", isDirectory: false)
    }

    var instrumentsRootURL: URL {
        rootURL.appendingPathComponent("instruments", isDirectory: true)
    }

    var eventsRootURL: URL {
        rootURL.appendingPathComponent("events", isDirectory: true)
    }

    func instrumentFolderURL(domain: String, name: String) throws -> URL {
        try CSVMirrorPaths.validateName(domain)
        try CSVMirrorPaths.validateName(name)
        return instrumentsRootURL
            .appendingPathComponent(domain, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    func instrumentDataURL(domain: String, name: String) throws -> URL {
        try instrumentFolderURL(domain: domain, name: name)
            .appendingPathComponent("data.csv", isDirectory: false)
    }

    func instrumentStateURL(domain: String, name: String) throws -> URL {
        try instrumentFolderURL(domain: domain, name: name)
            .appendingPathComponent("state.csv", isDirectory: false)
    }

    func instrumentREADMEURL(domain: String, name: String) throws -> URL {
        try instrumentFolderURL(domain: domain, name: name)
            .appendingPathComponent("README.txt", isDirectory: false)
    }

    /// `events_YYYY-MM.csv` partition for the given month (UTC).
    func eventLogURL(for month: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: month)
        return eventsRootURL.appendingPathComponent("events_\(stamp).csv", isDirectory: false)
    }

    private static let unsafeChars: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        set.formUnion(.controlCharacters)
        return set
    }()

    private static func validateName(_ name: String) throws {
        if name.isEmpty { throw CSVMirrorPathError.invalidInstrumentName(name) }
        if name.rangeOfCharacter(from: unsafeChars) != nil {
            throw CSVMirrorPathError.invalidInstrumentName(name)
        }
        // `..` and `.` traversal guard. Reject literal directory-traversal
        // names AND any name containing `..` between segments — `split` with
        // `omittingEmptySubsequences: false` so the empty subsequence between
        // consecutive dots actually surfaces.
        if name == "." || name == ".." {
            throw CSVMirrorPathError.invalidInstrumentName(name)
        }
        for segment in name.split(separator: ".", omittingEmptySubsequences: false)
            where segment.isEmpty
        {
            throw CSVMirrorPathError.invalidInstrumentName(name)
        }
    }
}

enum CSVMirrorBoilerplate {
    static let rootREADME = """
    # Steward — iCloud Drive Mirror

    These files are an auto-maintained mirror of Steward's local database.

    - `instruments/<domain>/<name>/data.csv` — editable; Steward picks up your changes.
    - `instruments/<domain>/<name>/state.csv` — auto-generated; do NOT edit (your edits are silently ignored).
    - `events/events_YYYY-MM.csv` — append-only event log, one file per month.

    Steward writes through `NSFileCoordinator`; if you edit a file in Numbers while
    Steward is also writing, iCloud will create a conflict version and Steward will
    resolve it by choosing the most recent modification and flagging affected rows
    in the next sync.
    """

    static let instrumentREADME = """
    Edit data.csv only.

    state.csv is auto-generated from the instrument's current state and will be
    overwritten on every update — your edits to state.csv are silently lost.

    Reserved columns (__row_id, __steward_version, __last_synced_at) let Steward
    track which row is which. Do NOT delete or reorder them; do NOT change the
    values in those columns.
    """
}
