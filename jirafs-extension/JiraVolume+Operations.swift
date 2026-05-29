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
        // Wrap reply so it can be captured by the async task below.
        let r = SendableBox(reply)
        makeTask {
            // Wire change notifications before warming up so that any stale-while-revalidate
            // refresh that fires during warmUp() already has the handler in place.
            await self.dataSource.setIssueKeysRefreshedHandler { [weak self] projectKey in
                guard let self else { return }
                // Update the issuesDir mtime so Finder's kqueue watcher sees the
                // change and re-enumerates the directory automatically.
                // Called after every successful background refresh (not only on
                // key-set change) to prevent stale partial listings in Finder.
                let node = self.item(for: .issuesDir(project: projectKey))
                node.cachedMTime = Date()
                // Invalidate the enumeration entries cache and bump the
                // generation so any in-flight children() call that captured
                // the old generation will not overwrite the cleared cache.
                self.itemsLock.withLock {
                    self.issueEntriesCache[projectKey] = nil
                    self.issueKeysSet[projectKey] = nil
                    self.issueEntriesGeneration[projectKey, default: 0] += 1
                }
                self.logger.info("issueKeys refreshed project=\(projectKey, privacy: .public): mtime updated, entries cache invalidated")
            }
            // Phase 1: warm from disk cache BEFORE replying to FSKit.
            // On a warm disk cache (the common case on every mount after the first),
            // this only reads disk — it completes in tens of milliseconds.
            // Delaying reply(nil) until after warmUp() ensures that Finder's very
            // first enumerateDirectory call hits a populated memory cache, preventing
            // the race condition where Finder caches an empty listing because it
            // enumerated the directory before warmUp had a chance to load any data.
            await self.dataSource.warmUp()
            // Signal FSKit that the mount is complete now that the cache is warm.
            r.value(nil)
            // Phase 2: schedule background API fetches for all projects so fresh
            // data arrives as soon as possible after mount, without blocking Finder.
            await self.dataSource.postWarmUpRefresh()
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
        let root = item(for: .root)
        reply(root, nil)
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
            // Use the pre-built Set for O(1) existence check when available.
            // Falls back to an O(N) issueKeys() scan only before the first full
            // enumeration of this project (Set is populated by children(of:)).
            if let keySet = itemsLock.withLock({ issueKeysSet[project] }) {
                return keySet.contains(name) ? .issue(key: name) : nil
            }
            // Set not yet populated — validate via issueKeys() array scan.
            // Prevents deleted/inaccessible tickets from being reachable via
            // direct path (`cd HA-1`) despite not appearing in listings.
            let keys = try await dataSource.issueKeys(forProject: project)
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
                let genBefore = itemsLock.withLock { issueEntriesGeneration[project, default: 0] }
                let keys = try await dataSource.issueKeys(forProject: project)
                // Return the pre-built tuple array if valid (O(1)) to avoid
                // rebuilding a 30,000+ element [(String, FSNodeKind)] array on
                // every enumerateDirectory pagination call (~70 calls per full ls).
                // Invalidated by onIssueKeysRefreshed when the key set changes.
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
