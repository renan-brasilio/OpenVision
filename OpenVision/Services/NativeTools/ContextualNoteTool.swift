// OpenVision - ContextualNoteTool.swift
// Voice notes auto-tagged with WHERE and WHEN you said them — the glasses-native productivity win.
// "Note: this cafe has great ramen" → saved with GPS + place name + timestamp; later searchable by
// content, tag, or location. Falls back gracefully to a plain note if location is unavailable.

import Foundation
import CoreLocation
import MapKit

struct ContextualNoteTool: NativeTool {
    let name = "note"
    let description = "Save, search, list, or delete quick notes. Notes are auto-tagged with your current location and time. Actions: 'save' (needs content), 'search' (needs query), 'list', 'delete' (needs query)."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "save, search, list, or delete"],
            "content": ["type": "string", "description": "The note text (for save)"],
            "tags": ["type": "string", "description": "Comma-separated tags (for save, optional)"],
            "query": ["type": "string", "description": "Keyword (for search/delete)"]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        switch (args["action"] as? String ?? "list").lowercased() {
        case "save", "note", "remember":
            guard let content = (args["content"] as? String)?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
                return "What should I note down?"
            }
            let tags = (args["tags"] as? String ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            let (loc, place) = await LocationHelper.shared.currentPlace()
            let note = ContextualNote(
                id: UUID().uuidString, content: content, tags: tags,
                latitude: loc?.latitude, longitude: loc?.longitude,
                locationName: place, createdAt: Date())
            ContextualNoteStore.shared.save(note)
            var response = "Noted"
            if let place { response += " at \(place)" }
            if !tags.isEmpty { response += " (tagged: \(tags.joined(separator: ", ")))" }
            return response + "."

        case "search", "find":
            let query = (args["query"] as? String ?? "").lowercased()
            guard !query.isEmpty else { return "What should I search your notes for?" }
            let results = ContextualNoteStore.shared.search(query)
            guard !results.isEmpty else { return "No notes match '\(query)'." }
            // Send the FULL text of the top matches so the model can actually reason over long notes
            // (not just a truncated preview). Bounded to 3 so context stays small.
            let top = results.prefix(3).map(Self.fullText).joined(separator: "\n---\n")
            let more = results.count > 3 ? "\n(plus \(results.count - 3) more match.)" : ""
            return "Found \(results.count) note\(results.count == 1 ? "" : "s"):\n\(top)\(more)"

        case "list", "recent":
            let notes = ContextualNoteStore.shared.recent(10)
            guard !notes.isEmpty else { return "No notes saved yet." }
            return "\(notes.count) recent: " + notes.prefix(5).map(Self.describe).joined(separator: "; ")

        case "delete":
            let query = (args["query"] as? String ?? args["content"] as? String ?? "").lowercased()
            guard !query.isEmpty else { return "Which note? Give me a keyword." }
            let n = ContextualNoteStore.shared.deleteMatching(query)
            return n > 0 ? "Deleted \(n) note\(n == 1 ? "" : "s")." : "No notes match '\(query)'."

        default:
            return "Use save, search, list, or delete."
        }
    }

    /// Short preview (for the recent list).
    private static func describe(_ note: ContextualNote) -> String {
        var d = String(note.content.prefix(50))
        if let loc = note.locationName { d += " (at \(loc))" }
        return d + " — \(note.timeAgo) ago"
    }

    /// Full note text + context (for search, so the model can reason over long notes).
    private static func fullText(_ note: ContextualNote) -> String {
        var d = note.content
        if let loc = note.locationName { d += " — at \(loc)" }
        return d + " (\(note.timeAgo) ago)"
    }
}

// MARK: - Model + store

struct ContextualNote: Codable, Identifiable {
    let id: String
    let content: String
    let tags: [String]
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let createdAt: Date

    var timeAgo: String {
        let s = Int(Date().timeIntervalSince(createdAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 { return "\(s/3600)h" }
        return "\(s/86400)d"
    }
}

final class ContextualNoteStore {
    static let shared = ContextualNoteStore()
    private let key = "contextualNotes"

    func all() -> [ContextualNote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notes = try? JSONDecoder().decode([ContextualNote].self, from: data) else { return [] }
        return notes
    }
    func save(_ note: ContextualNote) { var n = all(); n.append(note); persist(n) }
    func recent(_ count: Int) -> [ContextualNote] { Array(all().sorted { $0.createdAt > $1.createdAt }.prefix(count)) }
    func search(_ q: String) -> [ContextualNote] {
        all().filter { $0.content.lowercased().contains(q) || $0.tags.contains { $0.contains(q) } || ($0.locationName?.lowercased().contains(q) ?? false) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    func deleteMatching(_ q: String) -> Int {
        var notes = all(); let before = notes.count
        notes.removeAll { $0.content.lowercased().contains(q) || $0.tags.contains(q) }
        persist(notes); return before - notes.count
    }
    private func persist(_ notes: [ContextualNote]) {
        if let data = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Location + reverse geocode (never blocks a note)

/// Uses the *cached* location rather than blocking on a fresh GPS fix — a note must save instantly.
/// The delegate keeps the last fix warm; the reverse-geocode is hard-bounded to ~3s. If no recent
/// location is available yet, the note simply saves without a place (and warms up for next time).
@MainActor
final class LocationHelper: NSObject, CLLocationManagerDelegate {
    static let shared = LocationHelper()
    private let manager = CLLocationManager()
    private var lastFix: CLLocation?

    /// Only coordinate values leave the main actor; CLLocationManager and its cached fix do not.
    struct Fix: Sendable {
        let latitude: Double
        let longitude: Double
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let s = manager.authorizationStatus
        if s == .authorizedWhenInUse || s == .authorizedAlways { manager.requestLocation() }
    }

    /// Touch the singleton at launch to warm the cache. Main-actor initialization keeps the
    /// manager and its delegate callbacks on the main run loop.
    func prewarm() {}

    func currentPlace() async -> (Fix?, String?) {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()   // dialog now; this note saves without a place
            return (nil, nil)
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return (nil, nil) }
        let loc = lastFix ?? manager.location
        manager.requestLocation()   // refresh for next time (non-blocking)
        guard let loc, Date().timeIntervalSince(loc.timestamp) < 600 else { return (nil, nil) }
        let name = await Self.reverseGeocode(loc)
        return (Fix(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude), name)
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        // CLLocationManager.h specifies delegate delivery on its initialization run loop.
        // This manager is initialized on MainActor, so no location object crosses actors.
        MainActor.assumeIsolated { lastFix = locs.last }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    /// Both SDK paths use the same main-actor one-shot timeout, including late completion.
    private static func reverseGeocode(_ loc: CLLocation) async -> String? {
        if #available(iOS 26.0, *) {
            return await reverseGeocodeWithMapKit(loc)
        } else {
            return await reverseGeocodeWithCoreLocation(loc)
        }
    }

    @available(iOS 26.0, *)
    private static func reverseGeocodeWithMapKit(_ loc: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: loc) else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let once = GeocodeResume(c, cancel: { request.cancel() })
            // MKReverseGeocodingRequest.h annotates this completion NS_SWIFT_UI_ACTOR.
            request.getMapItems { items, _ in
                let item = items?.first
                once.resume(item?.name ?? item?.address?.shortAddress ?? item?.addressRepresentations?.cityName)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.timeOut() }
        }
    }

    // CoreLocation's geocoder is used only on OS versions before its iOS 26 replacement.
    @available(iOS, introduced: 5.0, obsoleted: 26.0)
    private static func reverseGeocodeWithCoreLocation(_ loc: CLLocation) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let geocoder = CLGeocoder()
            let once = GeocodeResume(c, cancel: { geocoder.cancelGeocode() })
            geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
                // The legacy SDK callback has no actor annotation. Extract a Sendable string
                // here and explicitly hop before touching the one-shot continuation.
                let name = placemarks?.first?.name ?? placemarks?.first?.subLocality ?? placemarks?.first?.locality
                Task { @MainActor in once.resume(name) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.timeOut() }
        }
    }
}

/// Completion and timeout may arrive in either order; all state is confined to MainActor.
@MainActor
private final class GeocodeResume {
    private var cont: CheckedContinuation<String?, Never>?
    private let cancel: @MainActor () -> Void

    init(_ c: CheckedContinuation<String?, Never>, cancel: @escaping @MainActor () -> Void) {
        cont = c
        self.cancel = cancel
    }

    func resume(_ name: String?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: name)
    }

    func timeOut() {
        guard cont != nil else { return }
        // Consume the continuation before cancellation, which may itself trigger completion.
        resume(nil)
        cancel()
    }
}
