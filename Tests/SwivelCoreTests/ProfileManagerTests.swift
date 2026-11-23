import Testing
@testable import SwivelCore

/// Round-trips the on-disk profile/state logic against a temp home, so it
/// never touches the user's real Claude/Swivel data. Covers the parts that
/// don't require the keychain (color state + directory management);
/// keychain-coupled save/restore is left for a future integration test.
@Suite("ProfileManager")
struct ProfileManagerTests {
    let home: URL
    let manager: ProfileManager

    init() {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swivel-test-\(UUID().uuidString)")
        manager = ProfileManager(home: home)
    }

    /// Lay down a profile directory the way a save would, without the
    /// keychain-coupled `saveCurrent`.
    private func makeProfile(_ name: String) throws {
        let dir = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("Claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    }

    private var swivelRoot: URL {
        home.appendingPathComponent("Library/Application Support/Swivel")
    }

    private var liveClaude: URL {
        home.appendingPathComponent("Library/Application Support/Claude")
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Point state.json at an active profile without the keychain-coupled
    /// save path.
    private func setActive(_ name: String) throws {
        try FileManager.default.createDirectory(at: swivelRoot, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["activeProfile": name])
        try data.write(to: swivelRoot.appendingPathComponent("state.json"), options: .atomic)
    }

    /// A live Claude folder with session-critical files, a transient journal,
    /// and excluded Claude Code / cache state.
    private func makeLiveSession() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: liveClaude, withIntermediateDirectories: true)
        for file in ["Cookies", "config.json", "config.json.journal"] {
            try "live".write(
                to: liveClaude.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
        }
        let codeDir = liveClaude.appendingPathComponent("claude-code")
        try fm.createDirectory(at: codeDir, withIntermediateDirectories: true)
        try "session".write(to: codeDir.appendingPathComponent("session"), atomically: true, encoding: .utf8)
        let cacheDir = liveClaude.appendingPathComponent("Cache")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try "cache".write(to: cacheDir.appendingPathComponent("blob"), atomically: true, encoding: .utf8)
    }

    @Test func colorRoundTrip() throws {
        defer { cleanup() }
        #expect(manager.profileColorHex(for: "Work") == nil)
        try manager.setProfileColorHex("#BE3A3A", for: "Work")
        #expect(manager.profileColorHex(for: "Work") == "#BE3A3A")
        try manager.setProfileColorHex(nil, for: "Work")
        #expect(manager.profileColorHex(for: "Work") == nil)
    }

    @Test func colorPersistsAcrossInstances() throws {
        defer { cleanup() }
        try manager.setProfileColorHex("#3559A1", for: "Personal")
        let reopened = ProfileManager(home: home)
        #expect(reopened.profileColorHex(for: "Personal") == "#3559A1")
    }

    @Test func listProfilesIsAlphabetical() throws {
        defer { cleanup() }
        #expect(manager.listProfiles() == [])
        try makeProfile("Work")
        try makeProfile("Personal")
        #expect(manager.listProfiles() == ["Personal", "Work"])
    }

    @Test func snapshotDirResolvesOnlyForExisting() throws {
        defer { cleanup() }
        #expect(manager.snapshotClaudeDir(for: "Ghost") == nil)
        try makeProfile("Real")
        #expect(manager.snapshotClaudeDir(for: "Real") != nil)
    }

    @Test func deleteRemovesProfile() throws {
        defer { cleanup() }
        try makeProfile("Temp")
        #expect(manager.listProfiles().contains("Temp"))
        try manager.delete(profile: "Temp")
        #expect(manager.listProfiles().contains("Temp") == false)
    }

    // MARK: - Backup ring + restore (keychain-free file logic)

    @Test func restoreBackupRewindsAndPreservesCurrent() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let profileDir = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles/P")
        let current = profileDir.appendingPathComponent("Claude")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "current".write(to: current.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        // A historical backup with distinct content.
        let backupDir = profileDir.appendingPathComponent("Claude.backup.20260101-120000")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try "old".write(to: backupDir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        let backups = manager.listBackups(for: "P")
        #expect(backups.count == 1)
        try manager.restoreBackup(backups[0], profile: "P")

        // Current now holds the backup's content…
        let restored = try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8)
        #expect(restored == "old")
        // …and the prior current was preserved as a fresh backup (undo-the-undo).
        let after = manager.listBackups(for: "P")
        #expect(after.count == 1)
        let preserved = try String(
            contentsOf: profileDir.appendingPathComponent(after[0].directoryName).appendingPathComponent("marker"),
            encoding: .utf8
        )
        #expect(preserved == "current")
    }

    @Test func listBackupsNewestFirst() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let profileDir = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles/P")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        for stamp in ["20260101-090000", "20260301-090000", "20260201-090000"] {
            try fm.createDirectory(
                at: profileDir.appendingPathComponent("Claude.backup.\(stamp)"),
                withIntermediateDirectories: true
            )
        }
        let names = manager.listBackups(for: "P").map { $0.directoryName }
        #expect(names == [
            "Claude.backup.20260301-090000",
            "Claude.backup.20260201-090000",
            "Claude.backup.20260101-090000",
        ])
    }

    @Test func sweepsOrphanedRestoreStaging() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let swivelRoot = home.appendingPathComponent("Library/Application Support/Swivel")
        let orphan = swivelRoot.appendingPathComponent(".restore-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(fm.fileExists(atPath: orphan.path))
        _ = ProfileManager(home: home)   // init runs the orphan sweep
        #expect(fm.fileExists(atPath: orphan.path) == false)
    }

    @Test func sweepsOrphanedSnapshotStaging() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let orphan = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles/P")
            .appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        _ = ProfileManager(home: home)
        #expect(fm.fileExists(atPath: orphan.path) == false)
    }

    // MARK: - Add Another Account

    @Test func validateNewProfileNameTrimsAndRejectsDuplicates() throws {
        defer { cleanup() }
        try makeProfile("Work")
        #expect(try manager.validateNewProfileName("  Personal  ") == "Personal")
        #expect(throws: ProfileError.self) { try manager.validateNewProfileName("Work") }
        #expect(throws: ProfileError.self) { try manager.validateNewProfileName("   ") }
        #expect(throws: ProfileError.self) { try manager.validateNewProfileName("../evil") }
    }

    @Test func prepareRefusesExistingNameWithoutTouchingLiveSession() throws {
        defer { cleanup() }
        try makeProfile("Personal")
        try setActive("Personal")
        try makeLiveSession()

        #expect(throws: ProfileError.self) {
            try manager.prepareForFreshSignIn(named: "Personal", previousActive: "Personal")
        }
        #expect(FileManager.default.fileExists(atPath: liveClaude.appendingPathComponent("Cookies").path))
        #expect(manager.loadPendingSetup() == nil)
    }

    @Test func addAnotherAccountPreparesFreshSignInAndCancelRestores() throws {
        defer { cleanup() }
        let fm = FileManager.default
        try makeProfile("Personal")
        try setActive("Personal")
        try makeLiveSession()

        let pending = try manager.prepareForFreshSignIn(
            named: "  Work  ",
            previousActive: "Personal"
        )
        #expect(pending.name == "Work")
        #expect(pending.previousActive == "Personal")
        #expect(manager.loadPendingSetup()?.name == "Work")
        #expect(manager.activeProfile() == "Personal")
        #expect(fm.fileExists(atPath: swivelRoot.appendingPathComponent("pending-setup.json").path))

        // The save succeeded, so its staging directory is gone.
        let profileDir = swivelRoot.appendingPathComponent("profiles/Personal")
        let profileEntries = try fm.contentsOfDirectory(atPath: profileDir.path)
        #expect(profileEntries.contains { $0.hasPrefix(".staging-") } == false)

        // Session-critical files are cleared so Claude shows its sign-in
        // screen; the transient journal is cleared too. Excluded items stay.
        #expect(!fm.fileExists(atPath: liveClaude.appendingPathComponent("Cookies").path))
        #expect(!fm.fileExists(atPath: liveClaude.appendingPathComponent("config.json").path))
        #expect(!fm.fileExists(atPath: liveClaude.appendingPathComponent("config.json.journal").path))
        #expect(fm.fileExists(atPath: liveClaude.appendingPathComponent("claude-code/session").path))
        #expect(fm.fileExists(atPath: liveClaude.appendingPathComponent("Cache/blob").path))

        // The marker survives a relaunch…
        let reopened = ProfileManager(home: home)
        #expect(reopened.loadPendingSetup()?.name == "Work")

        // Preparing refreshed the outgoing profile from the live session
        // before clearing it, so Cancel restores that state (not the older
        // marker-only snapshot). The journal stays out of both.
        let savedSnapshot = try #require(manager.snapshotClaudeDir(for: "Personal"))
        #expect(fm.fileExists(atPath: savedSnapshot.appendingPathComponent("Cookies").path))
        #expect(!fm.fileExists(atPath: savedSnapshot.appendingPathComponent("config.json.journal").path))
        #expect(manager.listBackups(for: "Personal").count == 1)

        // …and Cancel restores the saved previous profile and clears it.
        try reopened.restorePendingSetup(previousActive: "Personal")
        #expect(fm.fileExists(atPath: liveClaude.appendingPathComponent("Cookies").path))
        #expect(fm.fileExists(atPath: liveClaude.appendingPathComponent("config.json").path))
        #expect(!fm.fileExists(atPath: liveClaude.appendingPathComponent("config.json.journal").path))
        #expect(fm.fileExists(atPath: liveClaude.appendingPathComponent("claude-code/session").path))
        #expect(reopened.loadPendingSetup() == nil)
        #expect(!fm.fileExists(atPath: swivelRoot.appendingPathComponent("pending-setup.json").path))
        let leftovers = try fm.contentsOfDirectory(atPath: swivelRoot.path)
        #expect(leftovers.contains { $0.hasPrefix(".restore-staging-") } == false)
    }
}
