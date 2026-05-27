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
        makeTask {
            // Wire change notifications before warming up so that any stale-while-revalidate
            // refresh that fires during warmUp() already has the handler in place.
            await self.dataSource.setIssueKeysChangedHandler { [weak self] projectKey in
                guard let self else { return }
                // Update the issuesDir mtime so Finder's kqueue watcher sees the
                // change and re-enumerates the directory automatically.
                let node = self.item(for: .issuesDir(project: projectKey))
                node.cachedMTime = Date()
                self.logger.info("issueKeys changed project=\(projectKey, privacy: .public): mtime updated")
            }
            // Phase 1: fast pre-warm from disk cache so Finder browsing is instant.
            await self.dataSource.warmUp()
            // Phase 2: immediately schedule background API fetches for all projects
            // so fresh data arrives as soon as possible after mount, without blocking
            // the mount reply.
            await self.dataSource.postWarmUpRefresh()
        }
        reply(nil)
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
                var index: UInt64 = 0
                for (name, kind) in entries {
                    index += 1
                    if index <= cookie.rawValue { continue }
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
        // Fast path for issuesDir: the kernel only calls lookupItem with names
        // it received from enumerateDirectory, so we can construct the kind
        // directly without re-fetching and scanning the full issue list (O(N²)).
        if case .issuesDir(let project) = parent {
            if name == "AGENTS.md" {
                return .issuesAgentsGuide(project: project)
            }
            let prefix = project + "-"
            guard name.hasPrefix(prefix),
                  name.dropFirst(prefix.count).allSatisfy(\.isNumber),
                  !name.dropFirst(prefix.count).isEmpty
            else { return nil }
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
                let keys = try await dataSource.issueKeys(forProject: project)
                var kids = PathResolver.childKinds(of: kind)
                kids.append(contentsOf: keys.map { ($0, FSNodeKind.issue(key: $0)) })
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
        attrs.birthTime = node.cachedMTime.timespec
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
