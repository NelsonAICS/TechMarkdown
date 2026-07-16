import Foundation

/// 线程安全的文档批注存储。
///
/// 读写在锁内完成，持久化只处理不可变快照，避免后台编码与前台修改同一字典。
/// 所有成功修改都会在这里统一广播，调用方不需要重复发送刷新通知。
final class AnnotationService {
    static let shared = AnnotationService()

    private let storageKey = "techmarkdown.annotations.v2"
    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "com.techmarkdown.annotation-service.persistence",
        qos: .utility
    )
    private var storage: [String: [Annotation]] = [:]

    private init() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: [Annotation]].self, from: data)
        else {
            return
        }
        storage = decoded
    }

    // MARK: - Read

    func annotations(for path: String?) -> [Annotation] {
        guard let path, !path.isEmpty else { return [] }

        lock.lock()
        let values = storage[path] ?? []
        lock.unlock()

        return values.sorted {
            if $0.resolved != $1.resolved { return !$0.resolved }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func unresolvedAnnotations(for path: String?) -> [Annotation] {
        annotations(for: path).filter { !$0.resolved }
    }

    /// 查询仍未解决、且与新选区重叠的批注。
    func existingOverlappingAnnotation(
        selectedText: String,
        context: String,
        rangeSnapshot: AnnotationRangeSnapshot? = nil,
        for path: String?
    ) -> Annotation? {
        guard let path, !path.isEmpty else { return nil }
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return nil }

        lock.lock()
        let existing = storage[path]?.first {
            Self.overlaps(
                existing: $0,
                selectedText: selected,
                context: normalizedContext,
                rangeSnapshot: rangeSnapshot
            )
        }
        lock.unlock()
        return existing
    }

    // MARK: - Write

    @discardableResult
    func addAnnotation(
        _ text: String,
        selectedText: String = "",
        context: String = "",
        rangeSnapshot: AnnotationRangeSnapshot? = nil,
        for path: String?
    ) -> Annotation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, !trimmed.isEmpty else { return nil }

        lock.lock()
        if !selected.isEmpty,
           let overlap = storage[path]?.first(where: {
               Self.overlaps(
                   existing: $0,
                   selectedText: selected,
                   context: normalizedContext,
                   rangeSnapshot: rangeSnapshot
               )
           }) {
            lock.unlock()
            return overlap
        }

        let annotation = Annotation(
            text: trimmed,
            selectedText: selected,
            context: normalizedContext,
            rangeSnapshot: rangeSnapshot
        )
        storage[path, default: []].append(annotation)
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        notifyChanged(path: path, annotationID: annotation.id)
        return annotation
    }

    func updateAnnotation(_ annotation: Annotation, for path: String?) {
        guard let path, !path.isEmpty else { return }

        lock.lock()
        guard let index = storage[path]?.firstIndex(where: { $0.id == annotation.id }) else {
            lock.unlock()
            return
        }
        var updated = annotation
        updated.updatedAt = Date()
        storage[path]?[index] = updated
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        notifyChanged(path: path, annotationID: annotation.id)
    }

    func updateAnnotationText(id: UUID, newText: String, for path: String?) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, !trimmed.isEmpty else { return }

        lock.lock()
        guard let index = storage[path]?.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        storage[path]?[index].text = trimmed
        storage[path]?[index].updatedAt = Date()
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        notifyChanged(path: path, annotationID: id)
    }

    func toggleResolved(id: UUID, for path: String?) {
        guard let path, !path.isEmpty else { return }

        lock.lock()
        guard let index = storage[path]?.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        storage[path]?[index].resolved.toggle()
        storage[path]?[index].updatedAt = Date()
        let snapshot = storage
        lock.unlock()

        persist(snapshot)
        notifyChanged(path: path, annotationID: id)
    }

    func deleteAnnotation(id: UUID, for path: String?) {
        guard let path, !path.isEmpty else { return }

        lock.lock()
        let previousCount = storage[path]?.count ?? 0
        storage[path]?.removeAll { $0.id == id }
        let changed = (storage[path]?.count ?? 0) != previousCount
        if storage[path]?.isEmpty == true {
            storage.removeValue(forKey: path)
        }
        let snapshot = storage
        lock.unlock()

        guard changed else { return }
        persist(snapshot)
        notifyChanged(path: path, annotationID: id)
    }

    // MARK: - Persistence and events

    private func persist(_ snapshot: [String: [Annotation]]) {
        let key = storageKey
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func notifyChanged(path: String, annotationID: UUID) {
        let post = {
            NotificationCenter.default.post(
                name: .annotationListChanged,
                object: nil,
                userInfo: ["path": path, "annotationID": annotationID]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - Overlap

    private static func overlaps(
        existing: Annotation,
        selectedText: String,
        context: String,
        rangeSnapshot: AnnotationRangeSnapshot?
    ) -> Bool {
        guard !existing.resolved, !existing.selectedText.isEmpty, !selectedText.isEmpty else {
            return false
        }

        if
            let existingRange = existing.rangeSnapshot,
            let incomingRange = rangeSnapshot,
            snapshotRangesOverlap(existingRange, incomingRange)
        {
            return true
        }

        return existing.context == context &&
            (existing.selectedText.contains(selectedText) ||
                selectedText.contains(existing.selectedText))
    }

    private static func snapshotRangesOverlap(
        _ lhs: AnnotationRangeSnapshot,
        _ rhs: AnnotationRangeSnapshot
    ) -> Bool {
        let lhsStart = (lhs.startLine, lhs.startColumn)
        let lhsEnd = (lhs.endLine, lhs.endColumn)
        let rhsStart = (rhs.startLine, rhs.startColumn)
        let rhsEnd = (rhs.endLine, rhs.endColumn)

        return compare(lhsStart, rhsEnd) < 0 && compare(rhsStart, lhsEnd) < 0
    }

    private static func compare(_ lhs: (Int, Int), _ rhs: (Int, Int)) -> Int {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 ? -1 : 1 }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 ? -1 : 1 }
        return 0
    }
}
