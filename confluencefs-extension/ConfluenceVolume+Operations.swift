import Foundation
import FSKit
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore

@available(macOS 15.4, *)
extension ConfluenceVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

@available(macOS 15.4, *)
extension ConfluenceVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = false
        caps.supportsPersistentObjectIDs = true
        caps.doesNotSupportVolumeSizes = true
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "confluencefs")
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

    /// Runs the one-time mount setup: wires the refresh handler, warms the cache,
    /// and starts the periodic refresh loop. Safe to call from both `mount()` and
    /// `activate()`; the body runs at most once per volume (guarded by
    /// `mountSetupOnce`).
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
        // Background warmup: pre-cache spaces and root-page lists so the first
        // `ls spaces/` and `ls spaces/KEY/pages/` are served from cache.
        // Tracked via makeTask so cancelAllTasks() (called on unmount) stops it.
        makeTask {
            // The refresh handler is installed synchronously in `init` (before any
            // enumeration can run), so it is already in place for any background
            // refresh that fires during warm-up below.
            do {
                let spaces = try await self.dataSource.spaces()
                self.logger.info("warmup: \(spaces.count, privacy: .public) spaces")
                await withTaskGroup(of: Void.self) { group in
                    for space in spaces {
                        let s = space
                        group.addTask {
                            _ = try? await self.dataSource.rootPageEntries(space: s)
                        }
                    }
                }
                self.logger.info("warmup complete")
            } catch {
                self.logger.debug("warmup failed: \(error, privacy: .public)")
            }
            // Start the periodic refresh loop so pages created in Confluence after
            // a directory was last enumerated appear automatically (Finder is
            // passive and only re-enumerates when the directory mtime changes,
            // which a background refresh triggers via onListingRefreshed).
            self.startPeriodicRefresh()
        }
    }

    /// Minimum interval between periodic refresh passes, regardless of the
    /// configured pages TTL, to avoid hammering the Confluence API when a user
    /// sets a very small TTL.
    private static let minPeriodicRefreshInterval: TimeInterval = 1

    /// Upper bound on the periodic refresh interval (1 day), matching the
    /// Preferences TTL slider cap, so a huge or non-finite hand-edited config
    /// value can never overflow `UInt64(interval * 1e9)` in `Task.sleep`.
    private static let maxPeriodicRefreshInterval: TimeInterval = 86_400

    /// Starts a single long-lived loop that periodically forces a background
    /// refresh of every browsed page-listing directory. Finder is passive and
    /// only re-enumerates a directory when its mtime changes, so without this
    /// loop a newly created page would never appear while the user simply waits.
    /// The loop task is tracked by `makeTask`, so `cancelAllTasks()` (called from
    /// `unmount`) cancels it. Note that this only cancels the loop itself: any
    /// per-listing background refresh already dispatched via
    /// `refreshBrowsedListings()` runs on an untracked `Task` and may finish
    /// after unmount. Such a completion only writes to the data-source cache and
    /// fires `onListingRefreshed`, whose handler captures `[weak self]` and
    /// no-ops once the volume is gone.
    func startPeriodicRefresh() {
        makeTask { [weak self] in
            guard let self else { return }
            let ttl = await self.dataSource.ttl
            // `periodicRefreshInterval` encodes the polling policy: negative
            // disables it, 0 derives from the pages TTL (disabled when caching
            // itself is off, i.e. TTL <= 0), positive sets it explicitly, and the
            // result is clamped to [min, max] so the sleep duration is always a
            // finite, in-range value.
            guard let interval = ttl.periodicRefreshInterval(
                minimum: ConfluenceVolume.minPeriodicRefreshInterval,
                maximum: ConfluenceVolume.maxPeriodicRefreshInterval
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
                let count = await self.dataSource.refreshBrowsedListings()
                self.logger.info("periodic refresh tick: \(count, privacy: .public) listing(s)")
            }
            self.logger.info("periodic refresh loop ended")
        }
    }


    func unmount(replyHandler reply: @escaping () -> Void) {
        logger.info("unmount \(self.instanceName, privacy: .public)")
        cancelAllTasks()
        // Also cancel the data source's stale-while-revalidate / periodic refresh
        // tasks, which run on untracked Tasks that `cancelAllTasks()` does not
        // reach and would otherwise keep issuing network requests after unmount.
        // Defer reply() until cancellation has been issued so unmount does not
        // report completion while background refreshes are still tearing down.
        let r = SendableBox(reply)
        Task { [dataSource] in
            await dataSource.cancelBackgroundRefreshes()
            r.value()
        }
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping (Error?) -> Void) {
        let r = SendableBox(reply)
        makeTask {
            await self.dataSource.synchronize()
            // Clear per-item payload caches so stale file contents are not served
            // after the cache is wiped. The kernel will re-trigger getAttributes/open
            // for any item that is accessed again.
            self.itemsLock.withLock {
                for item in self.items.values {
                    item.setPayload(nil, size: 0)
                }
            }
            r.value(nil)
        }
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        // fskitd drives the volume through activate() (not always mount()), so
        // the one-time mount setup is triggered here to guarantee it runs.
        performMountSetupIfNeeded()
        reply(item(for: .root), nil)
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let node = item as? ConfluenceFSItem else {
            reply(nil, FSKitError.notFound); return
        }
        // Lazily load payload so the kernel sees the real file size on stat.
        // Without this, the kernel caches size=0 and read() is clipped entirely.
        // Only load for file nodes that haven't been fetched yet; directories
        // and already-loaded nodes are returned immediately without a network call.
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
        guard let parent = directory as? ConfluenceFSItem else {
            reply(nil, nil, FSKitError.notFound); return
        }
        let lookupName = name.string ?? ""
        let r = SendableBox(reply)
        let n = SendableBox(name)
        makeTask {
            do {
                if let resolved = try await self.resolveChild(parent: parent.kind, name: lookupName) {
                    // Use the name- and salt-aware item so the fileID matches what
                    // enumerateDirectory packed for the same (kind, name, salt).
                    r.value(self.item(for: resolved.kind, displayName: lookupName, salt: resolved.salt), n.value, nil)
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
        if let node = item as? ConfluenceFSItem { release(item: node) }
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
        guard let parent = directory as? ConfluenceFSItem else {
            reply(verifier, FSKitError.notFound); return
        }
        let r = SendableBox(reply)
        let p = SendableBox(packer)
        makeTask {
            do {
                let entries = try await self.children(of: parent.kind)
                let start = min(Int(clamping: cookie.rawValue), entries.count)
                for (offset, entry) in entries[start...].enumerated() {
                    let (name, kind, salt) = entry
                    let index = UInt64(start + offset + 1)
                    // Pass the entry name (so renamed pages get a new fileID) and
                    // the salt (page version on {Title}.html, so edited pages do
                    // too); see ConfluenceFSItem.init(kind:displayName:salt:).
                    let child = self.item(for: kind, displayName: name, salt: salt)
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

    // MARK: - Hierarchy resolution

    private func resolveChild(parent: ConfluenceNodeKind, name: String) async throws -> (kind: ConfluenceNodeKind, salt: String?)? {
        if let kind = ConfluencePathResolver.staticChild(name: name, of: parent) {
            return (kind, nil)
        }
        let kids = try await children(of: parent)
        return kids.first(where: { $0.name == name }).map { ($0.kind, $0.salt) }
    }

    /// Directory entry: display name, node kind, and an optional fileID `salt`.
    /// The salt distinguishes the same (kind, name) across edits — used for the
    /// page version on `{Title}.html` so Finder regenerates its HTML preview.
    private typealias ChildEntry = (name: String, kind: ConfluenceNodeKind, salt: String?)

    private func children(of kind: ConfluenceNodeKind) async throws -> [ChildEntry] {
        // Record page-listing directories as browsed so the periodic refresh
        // loop keeps them fresh (no-op for non-listing kinds).
        await dataSource.markBrowsed(kind)
        // Entries with no meaningful salt (everything except page listings).
        func plain(_ arr: [(String, ConfluenceNodeKind)]) -> [ChildEntry] {
            arr.map { ($0.0, $0.1, nil) }
        }
        switch kind {
        case .root, .configDir:
            return plain(ConfluencePathResolver.childKinds(of: kind))
        case .spacesDir:
            let spaces = try await dataSource.spaces()
            return spaces.map { ($0.key, ConfluenceNodeKind.space(key: $0.key), nil) }
        case .space:
            return plain(ConfluencePathResolver.childKinds(of: kind))
        case .pagesDir(let spaceKey):
            let staticKids = plain(ConfluencePathResolver.childKinds(of: kind))
            guard let space = try await dataSource.space(key: spaceKey) else { return staticKids }
            let entries = try await dataSource.rootPageEntries(space: space)
            // Note: the Confluence Cloud v2 API has no endpoint to enumerate
            // root-level (parentless) folders, so only folders nested under a page
            // are surfaced (see the pageDir case below).
            var result = staticKids
            result.append(contentsOf: pageEntries(entries, spaceKey: spaceKey))
            if await dataSource.includeArchived {
                result.append((".archived", .archivedRootPagesDir(spaceKey: spaceKey), nil))
            }
            return result
        case .pageDir(let spaceKey, let pageId):
            var kids = plain(ConfluencePathResolver.childKinds(of: kind))
            let entries = try await dataSource.childPageEntries(pageId: pageId, spaceKey: spaceKey)
            kids.append(contentsOf: pageEntries(entries, spaceKey: spaceKey))
            // Folder API errors (e.g. on instances without folder support) must not
            // prevent the child-page listing from rendering. Folders are exposed as
            // direct children of a page via the v2 direct-children endpoint.
            do {
                let folderEntries = try await dataSource.pageFolderEntries(pageId: pageId, spaceKey: spaceKey)
                kids.append(contentsOf: folderDirEntries(folderEntries, spaceKey: spaceKey, existingNames: pageNames(entries, htmlEnabled: htmlEnabled)))
                logger.debug("pageDir folders pageId=\(pageId, privacy: .public) count=\(folderEntries.count, privacy: .public)")
            } catch {
                logger.debug("pageDir folders failed pageId=\(pageId, privacy: .public): \(error, privacy: .public)")
            }
            if await dataSource.includeArchived {
                kids.append((".archived", .archivedChildPagesDir(spaceKey: spaceKey, pageId: pageId), nil))
            }
            // Background: pre-cache grandchildren so the next level of ls is fast.
            // Tracked via makeTask so cancelAllTasks() (called on unmount) stops it.
            makeTask {
                await withTaskGroup(of: Void.self) { group in
                    for entry in entries {
                        let id = entry.page.id
                        group.addTask { _ = try? await self.dataSource.childPageEntries(pageId: id, spaceKey: spaceKey) }
                    }
                }
            }
            return kids
        case .folderDir(let spaceKey, let folderId):
            var result: ConfluenceFolderChildrenResult = .empty
            do {
                result = try await dataSource.folderChildren(folderId: folderId, spaceKey: spaceKey)
                logger.debug("folderDir children folderId=\(folderId, privacy: .public) pages=\(result.pages.count, privacy: .public) folders=\(result.folders.count, privacy: .public)")
            } catch {
                logger.error("folderDir children failed folderId=\(folderId, privacy: .public): \(error, privacy: .public)")
            }
            var out = pageEntries(result.pages, spaceKey: spaceKey)
            out.append(contentsOf: folderDirEntries(result.folders, spaceKey: spaceKey, existingNames: pageNames(result.pages, htmlEnabled: htmlEnabled)))
            // Background: pre-cache grandchildren of child pages.
            let resultPages = result.pages
            makeTask {
                await withTaskGroup(of: Void.self) { group in
                    for entry in resultPages {
                        let id = entry.page.id
                        group.addTask { _ = try? await self.dataSource.childPageEntries(pageId: id, spaceKey: spaceKey) }
                    }
                }
            }
            return out
        case .commentsDir(let spaceKey, let pageId):
            let comments = try await dataSource.comments(pageId: pageId)
            var taken = Set<String>()
            return comments.enumerated().map { (i, c) in
                let raw = PageFileBuilder.commentFileName(index: i + 1, comment: c)
                let name = FileNameSanitizer.deduplicate(raw, taken: &taken)
                return (name, ConfluenceNodeKind.comment(spaceKey: spaceKey, pageId: pageId, index: i + 1), nil)
            }
        case .attachmentsDir(let spaceKey, let pageId):
            let atts = try await dataSource.attachments(pageId: pageId)
            var taken = Set<String>()
            return atts.map { a in
                let cleaned = FileNameSanitizer.sanitize(a.title)
                let name = FileNameSanitizer.deduplicate(cleaned, taken: &taken)
                return (name, ConfluenceNodeKind.attachment(spaceKey: spaceKey, pageId: pageId, attachmentId: a.id), nil)
            }
        case .archivedRootPagesDir(let spaceKey):
            guard let space = try await dataSource.space(key: spaceKey) else { return [] }
            let entries = try await dataSource.archivedRootPageEntries(space: space)
            return pageEntries(entries, spaceKey: spaceKey)
        case .archivedChildPagesDir(let spaceKey, let pageId):
            let entries = try await dataSource.archivedChildPageEntries(pageId: pageId, spaceKey: spaceKey)
            return pageEntries(entries, spaceKey: spaceKey)
        default:
            return []
        }
    }

    /// Emits the directory entries for a set of page entries: a `{Title}/`
    /// folder plus an optional sibling `{Title}.html` file sharing the stem.
    /// The HTML sibling carries the page version as its fileID salt so editing a
    /// page (new version, same title) gives it a new fileID and Finder
    /// regenerates the rendered preview.
    private func pageEntries(_ entries: [ConfluencePageEntry], spaceKey: String) -> [ChildEntry] {
        var out: [ChildEntry] = []
        for entry in entries {
            let pageId = entry.page.id
            let versionSalt = entry.page.version.map { "v\($0)" }
            if htmlEnabled {
                out.append(("\(entry.folderName).html", .pageHtml(spaceKey: spaceKey, pageId: pageId), versionSalt))
            }
            out.append((entry.folderName, .pageDir(spaceKey: spaceKey, pageId: pageId), nil))
        }
        return out
    }

    /// Returns the set of names already occupied by page entries (including optional
    /// `.html` siblings). Used as the starting `taken` set for cross-type deduplication
    /// when folder entries are added to the same listing.
    private func pageNames(_ entries: [ConfluencePageEntry], htmlEnabled: Bool) -> Set<String> {
        var names = Set<String>()
        for entry in entries {
            names.insert(entry.folderName)
            if htmlEnabled { names.insert("\(entry.folderName).html") }
        }
        return names
    }

    /// Emits the directory entries for a set of folder entries, deduplicating their
    /// names against `existingNames` (the page entries already in the same listing)
    /// so that a page and a folder with the same sanitized title never collide.
    private func folderDirEntries(
        _ entries: [ConfluenceFolderEntry],
        spaceKey: String,
        existingNames: Set<String>
    ) -> [ChildEntry] {
        var taken = existingNames
        return entries.map { entry in
            let name = FileNameSanitizer.deduplicate(entry.folderName, taken: &taken)
            return (name, ConfluenceNodeKind.folderDir(spaceKey: spaceKey, folderId: entry.folder.id), nil)
        }
    }

    func makeAttributes(for node: ConfluenceFSItem) -> FSItem.Attributes {
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
