import Foundation
import FSKit
import JiraAPI
import JiraFSCore

@available(macOS 15.4, *)
extension JiraVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

@available(macOS 15.4, *)
extension JiraVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = false
        caps.supportsPersistentObjectIDs = true
        caps.doesNotSupportVolumeSizes = true
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "jirafs")
        result.blockSize = 4096
        result.ioSize = 4096
        result.totalBlocks = 0
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.totalFiles = 0
        result.freeFiles = 0
        return result
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        logger.info("mount instance=\(self.instanceName, privacy: .public) ro=\(self.isReadOnly)")
        performMountSetupIfNeeded()
        reply(nil)
    }

    /// Runs the one-time mount setup: wires the refresh handler, warms the cache
    /// from disk, schedules a post-warm-up network refresh, and starts the
    /// periodic refresh loop. Safe to call from both `mount()` and `activate()`;
    /// the body runs at most once per volume (guarded by `mountSetupOnce`).
    ///
    /// fskitd drives `FSUnaryFileSystem` volumes through `activate()`, and may
    /// never call `mount()` — so this setup must not live solely in `mount()`,
    /// or the periodic refresh (and even the initial warm-up) would never run.
    func performMountSetupIfNeeded() {
        let shouldRun = mountSetupOnce.withLock { alreadyRan -> Bool in
            if alreadyRan { return false }
            alreadyRan = true
            return true
        }
        guard shouldRun else { return }
        logger.info("performMountSetup instance=\(self.instanceName, privacy: .public)")
        makeTask {
            // The refresh handler is installed synchronously in `init` (before any
            // enumeration can run), so it is already in place for any
            // stale-while-revalidate refresh that fires during warm-up below.
            // Phase 1: warm the in-memory cache from disk so Finder browsing is fast.
            await self.dataSource.warmUp()
            // Phase 2: schedule background API fetches for all projects so fresh
            // data arrives as soon as possible after mount, without blocking Finder.
            await self.dataSource.postWarmUpRefresh()
            // Phase 3: start the periodic refresh loop so issues created in JIRA
            // after a directory was last enumerated appear automatically (Finder
            // is passive and only re-enumerates when the directory mtime changes,
            // which a background refresh triggers via onIssueKeysRefreshed).
            self.startPeriodicRefresh()
        }
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        logger.info("unmount \(self.instanceName, privacy: .public)")
        // Cancel all in-flight Tasks (network fetches, directory enumeration, etc.)
        // BEFORE calling reply(), so FSKit doesn't destroy the volume while Tasks
        // are still holding references to packer/reply handlers.
        cancelAllTasks()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping (Error?) -> Void) {
        let r = SendableBox(reply)
        makeTask {
            await self.dataSource.synchronize()
            // issueEntriesCache is separate from CacheManager, so it must be
            // cleared here too; otherwise stale directory listings survive a sync.
            // Bump all generations so in-flight children() calls don't overwrite.
            self.itemsLock.withLock {
                self.issueEntriesCache.removeAll()
                self.issueKeysSet.removeAll()
                for key in self.issueEntriesGeneration.keys {
                    self.issueEntriesGeneration[key, default: 0] += 1
                }
            }
            r.value(nil)
        }
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        // fskitd drives the volume through activate() (not always mount()), so
        // the one-time mount setup is triggered here to guarantee it runs.
        performMountSetupIfNeeded()
        let root = item(for: .root)
        reply(root, nil)
    }

    /// Minimum interval between periodic refresh passes, regardless of the
    /// configured issues TTL, to avoid hammering the JIRA API when a user sets a
    /// very small TTL.
    private static let minPeriodicRefreshInterval: TimeInterval = 1

    /// Upper bound on the periodic refresh interval (1 day), matching the
    /// Preferences TTL slider cap, so a huge or non-finite hand-edited config
    /// value can never overflow `UInt64(interval * 1e9)` in `Task.sleep`.
    private static let maxPeriodicRefreshInterval: TimeInterval = 86_400

    /// Starts a single long-lived loop that periodically forces a background
    /// refresh of every browsed project's issue-key list. Finder is passive and
    /// only re-enumerates a directory when its mtime changes, so without this
    /// loop a newly created issue would never appear while the user simply waits.
    /// The refresh fires `onIssueKeysRefreshed`, which bumps the directory mtime
    /// and triggers Finder's kqueue watcher to re-enumerate.
    ///
    /// The loop task is tracked by `makeTask`, so `cancelAllTasks()` (called from
    /// `unmount`) cancels it. Note that this only cancels the loop itself: any
    /// per-project background refresh already dispatched via
    /// `IssueDataSource.scheduleRefresh` runs on an untracked `Task` and may
    /// finish after unmount. Such a completion only writes to the data-source
    /// cache and fires `onIssueKeysRefreshed`, whose handler captures `[weak
    /// self]` and no-ops once the volume is gone.
    func startPeriodicRefresh() {
        makeTask { [weak self] in
            guard let self else { return }
            let ttl = await self.dataSource.ttl
            // `periodicRefreshInterval` encodes the polling policy: negative
            // disables it, 0 derives from the issues TTL (disabled when caching
            // itself is off, i.e. TTL <= 0), positive sets it explicitly, and the
            // result is clamped to [min, max] so the sleep duration is always a
            // finite, in-range value.
            guard let interval = ttl.periodicRefreshInterval(
                minimum: JiraVolume.minPeriodicRefreshInterval,
                maximum: JiraVolume.maxPeriodicRefreshInterval
            ) else {
                self.logger.info("periodic refresh disabled")
                return
            }
            self.logger.info("periodic refresh loop started interval=\(interval, privacy: .public)s")
            let nanos = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    break  // cancelled
                }
                if Task.isCancelled { break }
                let count = await self.dataSource.refreshBrowsedProjects()
                self.logger.info("periodic refresh tick: \(count, privacy: .public) project(s)")
            }
            self.logger.info("periodic refresh loop ended")
        }
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let node = item as? JiraFSItem else {
            reply(nil, FSKitError.notFound); return
        }
        // Lazily load payload so the kernel sees the real file size on stat.
        // Without this, the kernel caches a wrong size and read() is clipped.
        if !node.kind.isDirectory && node.cachedData == nil {
            let r = SendableBox(reply)
            makeTask {
                try? await self.loadPayload(for: node)
                r.value(self.makeAttributes(for: node), nil)
            }
            return
        }
        reply(makeAttributes(for: node), nil)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        reply(nil, FSKitError.readOnly)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        guard let parent = directory as? JiraFSItem else {
            reply(nil, nil, FSKitError.notFound); return
        }
        let lookupName = name.string ?? ""
        let r = SendableBox(reply)
        let n = SendableBox(name)
        makeTask {
            do {
                if let kind = try await self.resolveChild(parent: parent.kind, name: lookupName) {
                    let child = self.item(for: kind)
                    r.value(child, n.value, nil)
                } else {
                    r.value(nil, nil, FSKitError.notFound)
                }
            } catch {
                self.logger.error("lookupItem failed parent=\(String(describing: parent.kind), privacy: .public) name=\(lookupName, privacy: .public) error=\(error, privacy: .public)")
                r.value(nil, nil, FSKitError.from(error))
            }
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        if let node = item as? JiraFSItem { release(item: node) }
        reply(nil)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let parent = directory as? JiraFSItem else {
            reply(verifier, FSKitError.notFound); return
        }
        let r = SendableBox(reply)
        let p = SendableBox(packer)
        logger.info("enumerateDirectory start kind=\(String(describing: parent.kind), privacy: .public) cookie=\(cookie.rawValue)")

        makeTask {
            do {
                let entries = try await self.children(of: parent.kind)
                self.logger.info("enumerateDirectory got \(entries.count) entries for kind=\(String(describing: parent.kind), privacy: .public)")
                // Use O(1) array slicing to jump to the cookie position instead of
                // iterating and skipping, which is O(N) per call and O(N²) total
                // when FSKit paginates a large directory (e.g. 30,000 issues require
                // ~70 enumerateDirectory calls at ~430 entries/buffer).
                // Int(clamping:) avoids a trap when FSKit passes a cookie whose
                // rawValue exceeds Int.max — the result is clamped to entries.count,
                // returning an empty slice rather than crashing the extension.
                let start = min(Int(clamping: cookie.rawValue), entries.count)
                for (offset, (name, kind)) in entries[start...].enumerated() {
                    let index = UInt64(start + offset + 1)
                    let child = self.item(for: kind)
                    let itemType: FSItem.ItemType = kind.isDirectory ? .directory : .file
                    let nextCookie = FSDirectoryCookie(rawValue: index)
                    let cont = p.value.packEntry(name: FSFileName(string: name), itemType: itemType, itemID: child.identifier, nextCookie: nextCookie, attributes: self.makeAttributes(for: child))
                    if !cont { break }
                }
                r.value(verifier, nil)
            } catch {
                self.logger.error("enumerateDirectory failed kind=\(String(describing: parent.kind), privacy: .public) error=\(error, privacy: .public)")
                r.value(verifier, FSKitError.from(error))
            }
        }
    }

    // MARK: - Read-only stubs for write operations

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        reply(nil, nil, FSKitError.readOnly)
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        reply(FSKitError.readOnly)
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, FSKitError.readOnly)
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        reply(nil, nil, FSKitError.notSupported)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, FSKitError.notSupported)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, FSKitError.notSupported)
    }

    // MARK: - Helpers

    private func resolveChild(parent: FSNodeKind, name: String) async throws -> FSNodeKind? {
        if case .issuesDir(let project) = parent {
            if name == "AGENTS.md" {
                return .issuesAgentsGuide(project: project)
            }
            // Quick reject: must match PROJECT-NNN before hitting the cache.
            let prefix = project + "-"
            guard name.hasPrefix(prefix),
                  name.dropFirst(prefix.count).allSatisfy(\.isNumber),
                  !name.dropFirst(prefix.count).isEmpty
            else { return nil }
            // Always call through the TTL-aware issueKeys() so the
            // stale-while-revalidate chain fires even for direct-path lookups
            // (e.g. `cd KEY-123` without a preceding `ls`). The in-memory cache
            // makes this O(1) when hot; bypassing it would leave issueKeysSet
            // stale indefinitely if the directory is never re-enumerated.
            let keys = try await dataSource.issueKeys(forProject: project)
            // Use the pre-built Set for O(1) membership test when available.
            // issueKeysSet is invalidated alongside issueEntriesCache by
            // onIssueKeysRefreshed, so it always reflects the same snapshot as
            // the keys array we just received. If it was cleared by a concurrent
            // refresh, fall back to an O(N) scan of the fresh array.
            if let keySet = itemsLock.withLock({ issueKeysSet[project] }) {
                return keySet.contains(name) ? .issue(key: name) : nil
            }
            guard keys.contains(name) else { return nil }
            return .issue(key: name)
        }
        let kids = try await children(of: parent)
        return kids.first(where: { $0.0 == name })?.1
    }

    private func children(of kind: FSNodeKind) async throws -> [(String, FSNodeKind)] {
        switch kind {
        case .root, .configDir:
            return PathResolver.childKinds(of: kind)
        case .projectsDir:
            let projects = try await dataSource.projects()
            return projects.map { ($0.key, FSNodeKind.project(key: $0.key)) }
        case .project:
            return PathResolver.childKinds(of: kind)
        case .issuesDir(let project):
            do {
                // Always call dataSource.issueKeys() so the stale-while-revalidate
                // chain remains active: once the TTL elapses, the call detects stale
                // data, schedules bgRefreshIssueKeys, which fires onIssueKeysRefreshed
                // and invalidates issueEntriesCache. Without this call, issueEntriesCache
                // would short-circuit the refresh chain and issue listings would grow
                // stale indefinitely after the first TTL period.
                // Capture the current invalidation generation before the async
                // issueKeys() call. If a background refresh fires onIssueKeysRefreshed
                // while we await, the generation will have advanced and we must
                // not store the entry array built from the now-stale key snapshot.
                //
                // We must also *register* the key in issueEntriesGeneration here
                // (under the lock) so that a concurrent synchronize() — which
                // bumps only keys already present in the dict — will bump this
                // project even if it has never been enumerated before. Without
                // this, synchronize() can clear the caches and return while
                // genBefore is still 0 and issueEntriesGeneration[project] is
                // still absent, so the post-await generation check compares
                // 0 == 0 and stores stale data.
                let genBefore = itemsLock.withLock { () -> Int in
                    if issueEntriesGeneration[project] == nil {
                        issueEntriesGeneration[project] = 0
                    }
                    return issueEntriesGeneration[project]!
                }
                let keys = try await dataSource.issueKeys(forProject: project)
                // Return the pre-built tuple array if valid (O(1)) to avoid
                // rebuilding a 30,000+ element [(String, FSNodeKind)] array on
                // every enumerateDirectory pagination call (~70 calls per full ls).
                // Invalidated by onIssueKeysRefreshed after each successful
                // background refresh.
                if let cached = itemsLock.withLock({ issueEntriesCache[project] }) {
                    return cached
                }
                var kids = PathResolver.childKinds(of: kind)
                kids.append(contentsOf: keys.map { ($0, FSNodeKind.issue(key: $0)) })
                // Only store if the generation has not advanced (i.e. no refresh
                // invalidated the cache while issueKeys() was in flight).
                itemsLock.withLock {
                    if issueEntriesGeneration[project, default: 0] == genBefore {
                        issueEntriesCache[project] = kids
                        issueKeysSet[project] = Set(keys)
                    }
                }
                return kids
            } catch {
                // API failure (e.g. invalid JSON, network error, permission denied).
                // Return an empty listing so Finder shows the directory as empty
                // rather than making FSKit propagate an error that causes the
                // issues/ directory to appear missing in the parent listing.
                logger.error("issueKeys failed project=\(project, privacy: .public) error=\(error, privacy: .public)")
                return []
            }
        case .issue(let key):
            // Always include all children. Previously we checked whether comments
            // and attachments were non-empty before showing those directories, but
            // that required 2 API calls per issue directory — O(N) API calls when
            // Finder enumerates N issues. Now we unconditionally show comments/ and
            // attachments/ (they appear empty if there is no data), eliminating the
            // per-issue API round-trips on directory listing.
            var kids = PathResolver.childKinds(of: kind)
            if htmlEnabled {
                kids.append(("issue.html", .issueHtml(issueKey: key)))
            }
            return kids
        case .commentsDir(let issueKey):
            do {
                let comments = try await dataSource.comments(issueKey: issueKey)
                var taken = Set<String>()
                return comments.enumerated().map { (i, c) in
                    let raw = IssueFileBuilder.commentFileName(index: i + 1, comment: c)
                    let name = FileNameSanitizer.deduplicate(raw, taken: &taken)
                    // Store the 1-based index as the stable identifier so that
                    // loadPayload can resolve comments[index-1] regardless of
                    // whether the filename was deduplicated.
                    return (name, FSNodeKind.comment(issueKey: issueKey, index: i + 1))
                }
            } catch {
                logger.error("comments failed issueKey=\(issueKey, privacy: .public) error=\(error, privacy: .public)")
                return []
            }
        case .attachmentsDir(let issueKey):
            do {
                let atts = try await dataSource.attachments(issueKey: issueKey)
                var taken = Set<String>()
                return atts.map { a in
                    let cleaned = FileNameSanitizer.sanitize(a.filename)
                    let name = FileNameSanitizer.deduplicate(cleaned, taken: &taken)
                    // Store the attachment id as the stable identifier so that
                    // loadPayload can resolve by id regardless of deduplication.
                    return (name, FSNodeKind.attachment(issueKey: issueKey, attachmentId: a.id))
                }
            } catch {
                logger.error("attachments failed issueKey=\(issueKey, privacy: .public) error=\(error, privacy: .public)")
                return []
            }
        default:
            return []
        }
    }

    func makeAttributes(for node: JiraFSItem) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = node.identifier
        attrs.parentID = .invalid
        attrs.linkCount = 1
        attrs.flags = 0
        attrs.size = node.cachedSize
        attrs.allocSize = node.cachedSize
        attrs.modifyTime = node.cachedMTime.timespec
        attrs.changeTime = node.cachedMTime.timespec
        attrs.accessTime = node.cachedMTime.timespec
        attrs.birthTime = node.cachedBirthTime.timespec
        attrs.mode = node.kind.isDirectory ? 0o040555 : 0o100444
        attrs.type = node.kind.isDirectory ? .directory : .file
        return attrs
    }

}

@available(macOS 15.4, *)
private extension Date {
    var timespec: timespec {
        let interval = timeIntervalSince1970
        var ts = Foundation.timespec()
        ts.tv_sec = Int(interval)
        ts.tv_nsec = Int((interval - Double(Int(interval))) * 1_000_000_000)
        return ts
    }
}
