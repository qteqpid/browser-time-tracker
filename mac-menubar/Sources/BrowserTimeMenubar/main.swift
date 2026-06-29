import AppKit
import Foundation
import Network
import Security
import SQLite3

struct BrowserEvent: Decodable {
    let browser: String
    let event: String
    let url: String?
    let title: String?
    let timestamp: String
}

struct SummaryItem: Encodable {
    let label: String
    let url: String?
    let seconds: Int
}

struct BarSegment: Encodable {
    let label: String
    let seconds: Int
}

struct HourBucket: Encodable {
    let hour: Int
    let seconds: Int
    let segments: [BarSegment]
}

struct DayBucket: Encodable {
    let date: String
    let label: String
    let seconds: Int
    let segments: [BarSegment]
}

struct TodaySummary: Encodable {
    let totalSeconds: Int
    let domains: [SummaryItem]
    let pages: [SummaryItem]
    let colorDomains: [SummaryItem]
    let hours: [HourBucket]
    let days: [DayBucket]
    let windowLabel: String
}

final class BrowserTimeStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "browser-time-store")

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw NSError(domain: "BrowserTimeStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open SQLite database"
            ])
        }
        try setup()
    }

    deinit {
        sqlite3_close(db)
    }

    func startSession(browser: String, url: String, title: String?, at date: Date) -> String {
        queue.sync {
            let id = UUID().uuidString
            let domain = Self.domain(from: url)
            let timestamp = date.timeIntervalSince1970
            execute(
                """
                INSERT INTO page_sessions
                (id, browser, url, domain, title, started_at, ended_at, duration_seconds)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """,
                [id, browser, url, domain, title ?? "", timestamp, timestamp]
            )
            return id
        }
    }

    func updateSession(id: String, title: String?, endedAt date: Date) {
        queue.sync {
            let timestamp = date.timeIntervalSince1970
            execute(
                """
                UPDATE page_sessions
                SET title = CASE WHEN ? = '' THEN title ELSE ? END,
                    ended_at = ?,
                    duration_seconds = MAX(0, CAST(? - started_at AS INTEGER))
                WHERE id = ?
                """,
                [title ?? "", title ?? "", timestamp, timestamp, id]
            )
        }
    }

    func closeSession(id: String, endedAt date: Date) {
        updateSession(id: id, title: nil, endedAt: date)
    }

    func todaySummary() -> TodaySummary {
        queue.sync {
            let startDate = Calendar.current.startOfDay(for: Date())
            let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? Date()
            return summaryUnlocked(start: startDate, end: endDate, windowLabel: "Today")
        }
    }

    func summary(start: Date, end: Date, windowLabel: String) -> TodaySummary {
        queue.sync {
            summaryUnlocked(start: start, end: end, windowLabel: windowLabel)
        }
    }

    func hourlyBuckets(for date: Date) -> [HourBucket] {
        queue.sync {
            hourlyBucketsUnlocked(for: date, topDomains: [])
        }
    }

    private func summaryUnlocked(start: Date, end: Date, windowLabel: String) -> TodaySummary {
        let start = start.timeIntervalSince1970
        let end = end.timeIntervalSince1970
        let overlap = "MAX(0, MIN(ended_at, ?) - MAX(started_at, ?))"
        let total = queryInt(
            "SELECT COALESCE(SUM(\(overlap)), 0) FROM page_sessions WHERE ended_at > ? AND started_at < ?",
            [end, start, start, end]
        )
        let domains = queryItems(
            """
            SELECT domain, NULL, COALESCE(SUM(\(overlap)), 0) AS total
            FROM page_sessions
            WHERE ended_at > ? AND started_at < ? AND domain != ''
            GROUP BY domain
            HAVING total > 0
            ORDER BY total DESC
            LIMIT 10
            """,
            [end, start, start, end]
        )
        let pages = queryItems(
            """
            SELECT COALESCE(NULLIF(title, ''), url), url, COALESCE(SUM(\(overlap)), 0) AS total
            FROM page_sessions
            WHERE ended_at > ? AND started_at < ? AND url != ''
            GROUP BY url
            HAVING total > 0
            ORDER BY total DESC
            LIMIT 10
            """,
            [end, start, start, end]
        )
        let selectedDate = Date(timeIntervalSince1970: start)
        let colorDomains = colorDomainsUnlocked(endingAt: selectedDate)
        let colorDomainLabels = colorDomains.map(\.label)

        return TodaySummary(
            totalSeconds: total,
            domains: domains,
            pages: pages,
            colorDomains: colorDomains,
            hours: hourlyBucketsUnlocked(for: selectedDate, topDomains: colorDomainLabels),
            days: dayBucketsUnlocked(endingAt: selectedDate, topDomains: colorDomainLabels),
            windowLabel: windowLabel
        )
    }

    private func hourlyBucketsUnlocked(for date: Date, topDomains: [String]) -> [HourBucket] {
        let dayStart = Calendar.current.startOfDay(for: date)
        return (0..<24).map { hour in
            let startDate = Calendar.current.date(byAdding: .hour, value: hour, to: dayStart) ?? dayStart
            let endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate
            let start = startDate.timeIntervalSince1970
            let end = endDate.timeIntervalSince1970
            let overlap = "MAX(0, MIN(ended_at, ?) - MAX(started_at, ?))"
            let total = queryInt(
                "SELECT COALESCE(SUM(\(overlap)), 0) FROM page_sessions WHERE ended_at > ? AND started_at < ?",
                [end, start, start, end]
            )
            return HourBucket(
                hour: hour,
                seconds: total,
                segments: segmentBucketsUnlocked(start: start, end: end, topDomains: topDomains)
            )
        }
    }

    private func dayBucketsUnlocked(endingAt date: Date, topDomains: [String]) -> [DayBucket] {
        let selectedDay = Calendar.current.startOfDay(for: date)
        let firstDay = Calendar.current.date(byAdding: .day, value: -6, to: selectedDay) ?? selectedDay
        let dateFormatter = Self.dateFormatter
        let labelFormatter = Self.dayLabelFormatter

        return (0..<7).map { offset in
            let startDate = Calendar.current.date(byAdding: .day, value: offset, to: firstDay) ?? firstDay
            let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate
            let start = startDate.timeIntervalSince1970
            let end = endDate.timeIntervalSince1970
            let overlap = "MAX(0, MIN(ended_at, ?) - MAX(started_at, ?))"
            let total = queryInt(
                "SELECT COALESCE(SUM(\(overlap)), 0) FROM page_sessions WHERE ended_at > ? AND started_at < ?",
                [end, start, start, end]
            )
            return DayBucket(
                date: dateFormatter.string(from: startDate),
                label: labelFormatter.string(from: startDate),
                seconds: total,
                segments: segmentBucketsUnlocked(start: start, end: end, topDomains: topDomains)
            )
        }
    }

    private func segmentBucketsUnlocked(start: Double, end: Double, topDomains: [String]) -> [BarSegment] {
        let overlap = "MAX(0, MIN(ended_at, ?) - MAX(started_at, ?))"
        let rows = queryDomainSeconds(
            """
            SELECT domain, COALESCE(SUM(\(overlap)), 0) AS total
            FROM page_sessions
            WHERE ended_at > ? AND started_at < ? AND domain != ''
            GROUP BY domain
            HAVING total > 0
            ORDER BY total DESC
            """,
            [end, start, start, end]
        )
        guard !rows.isEmpty else { return [] }

        guard !topDomains.isEmpty else {
            let total = rows.reduce(0) { $0 + $1.seconds }
            return total > 0 ? [BarSegment(label: "Other", seconds: total)] : []
        }

        let secondsByDomain = Dictionary(uniqueKeysWithValues: rows.map { ($0.domain, $0.seconds) })
        let knownSegments = topDomains.compactMap { domain -> BarSegment? in
            guard let seconds = secondsByDomain[domain], seconds > 0 else {
                return nil
            }
            return BarSegment(label: domain, seconds: seconds)
        }
        let knownTotal = knownSegments.reduce(0) { $0 + $1.seconds }
        let total = rows.reduce(0) { $0 + $1.seconds }
        let other = max(0, total - knownTotal)

        if other > 0 {
            return knownSegments + [BarSegment(label: "Other", seconds: other)]
        }
        return knownSegments
    }

    private func colorDomainsUnlocked(endingAt date: Date) -> [SummaryItem] {
        let selectedDay = Calendar.current.startOfDay(for: date)
        let startDate = Calendar.current.date(byAdding: .day, value: -6, to: selectedDay) ?? selectedDay
        let endDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay
        let start = startDate.timeIntervalSince1970
        let end = endDate.timeIntervalSince1970
        let overlap = "MAX(0, MIN(ended_at, ?) - MAX(started_at, ?))"

        return queryItems(
            """
            SELECT domain, NULL, COALESCE(SUM(\(overlap)), 0) AS total
            FROM page_sessions
            WHERE ended_at > ? AND started_at < ? AND domain != ''
            GROUP BY domain
            HAVING total > 0
            ORDER BY total DESC
            LIMIT 10
            """,
            [end, start, start, end]
        )
    }

    func clearAll() {
        queue.sync {
            execute("DELETE FROM page_sessions", [])
        }
    }

    func pruneData(olderThanDays days: Int) {
        queue.sync {
            let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60)).timeIntervalSince1970
            execute("DELETE FROM page_sessions WHERE ended_at < ?", [cutoff])
        }
    }

    private func setup() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS page_sessions (
            id TEXT PRIMARY KEY,
            browser TEXT NOT NULL,
            url TEXT NOT NULL,
            domain TEXT NOT NULL,
            title TEXT,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            duration_seconds INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_page_sessions_started_at ON page_sessions(started_at);
        CREATE INDEX IF NOT EXISTS idx_page_sessions_domain ON page_sessions(domain);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw NSError(domain: "BrowserTimeStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create SQLite schema"
            ])
        }
    }

    private func execute(_ sql: String, _ values: [Any]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        sqlite3_step(statement)
    }

    private func queryInt(_ sql: String, _ values: [Any]) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    private func queryItems(_ sql: String, _ values: [Any]) -> [SummaryItem] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)

        var items: [SummaryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let label = String(cString: sqlite3_column_text(statement, 0))
            let urlPointer = sqlite3_column_text(statement, 1)
            let url = urlPointer.map { String(cString: $0) }
            let seconds = Int(sqlite3_column_int(statement, 2))
            items.append(SummaryItem(label: label, url: url, seconds: seconds))
        }
        return items
    }

    private func queryDomainSeconds(_ sql: String, _ values: [Any]) -> [(domain: String, seconds: Int)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(values, to: statement)

        var items: [(domain: String, seconds: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let domain = String(cString: sqlite3_column_text(statement, 0))
            let seconds = Int(sqlite3_column_int(statement, 1))
            items.append((domain: domain, seconds: seconds))
        }
        return items
    }

    private func bind(_ values: [Any], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            case let value as Int:
                sqlite3_bind_int(statement, position, Int32(value))
            default:
                sqlite3_bind_null(statement, position)
            }
        }
    }

    private static func domain(from url: String) -> String {
        URLComponents(string: url)?.host ?? ""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class EventIngestor {
    private struct ActiveSession {
        let id: String
        let url: String
        let browser: String
    }

    private let store: BrowserTimeStore
    private let queue = DispatchQueue(label: "event-ingestor")
    private let dateFormatter = ISO8601DateFormatter()
    private var activeSessions: [String: ActiveSession] = [:]
    private var userPaused = false
    private var systemPauseReasons: Set<String> = []
    private(set) var isPaused = false

    init(store: BrowserTimeStore) {
        self.store = store
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func setPaused(_ paused: Bool) {
        queue.sync {
            userPaused = paused
            updatePausedState(endedAt: Date())
        }
    }

    func setSystemPaused(_ paused: Bool, reason: String, at date: Date = Date()) {
        queue.sync {
            if paused {
                systemPauseReasons.insert(reason)
            } else {
                systemPauseReasons.remove(reason)
            }
            updatePausedState(endedAt: date)
        }
    }

    func resetActiveSessions() {
        queue.sync {
            activeSessions.removeAll()
        }
    }

    func ingest(_ event: BrowserEvent) {
        queue.sync {
            let eventDate = parseDate(event.timestamp)
            let browser = event.browser.lowercased()

            switch event.event {
            case "page_active", "heartbeat":
                guard !isPaused, let url = event.url, isTrackable(url: url) else {
                    return
                }

                if let active = activeSessions[browser], active.url == url {
                    store.updateSession(id: active.id, title: event.title, endedAt: eventDate)
                    return
                }

                if let active = activeSessions[browser] {
                    store.closeSession(id: active.id, endedAt: eventDate)
                }

                let id = store.startSession(
                    browser: browser,
                    url: url,
                    title: event.title,
                    at: eventDate
                )
                activeSessions[browser] = ActiveSession(id: id, url: url, browser: browser)

            case "page_hidden", "page_closed", "browser_blurred", "user_idle", "tracking_paused":
                if let active = activeSessions[browser] {
                    store.closeSession(id: active.id, endedAt: eventDate)
                    activeSessions[browser] = nil
                }

            default:
                break
            }
        }
    }

    private func updatePausedState(endedAt date: Date) {
        let nextIsPaused = userPaused || !systemPauseReasons.isEmpty
        isPaused = nextIsPaused

        if nextIsPaused {
            for session in activeSessions.values {
                store.closeSession(id: session.id, endedAt: date)
            }
            activeSessions.removeAll()
        }
    }

    private func parseDate(_ value: String) -> Date {
        if let date = dateFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value) ?? Date()
    }

    private func isTrackable(url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

final class BrowserActiveTabPoller {
    private struct Snapshot {
        let url: String
        let title: String
    }

    private let browser: String
    private let ingestor: EventIngestor
    private let dateFormatter = ISO8601DateFormatter()
    private let bundleIDs: Set<String>
    private let scriptSource: String

    init(browser: String, bundleIDs: Set<String>, scriptSource: String, ingestor: EventIngestor) {
        self.browser = browser
        self.bundleIDs = bundleIDs
        self.scriptSource = scriptSource
        self.ingestor = ingestor
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func poll() {
        guard isBrowserFrontmost() else {
            closeCurrent(reason: "browser_blurred")
            return
        }

        guard let snapshot = readActiveTab(), isTrackable(url: snapshot.url) else {
            closeCurrent(reason: "page_hidden")
            return
        }

        ingestor.ingest(BrowserEvent(
            browser: browser,
            event: "page_active",
            url: snapshot.url,
            title: snapshot.title,
            timestamp: now()
        ))
    }

    private func closeCurrent(reason: String) {
        ingestor.ingest(BrowserEvent(
            browser: browser,
            event: reason,
            url: nil,
            title: nil,
            timestamp: now()
        ))
    }

    private func isBrowserFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return bundleIDs.contains(bundleID)
    }

    private func readActiveTab() -> Snapshot? {
        var errorInfo: NSDictionary?
        guard let output = NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo).stringValue,
              !output.isEmpty else {
            return nil
        }

        let pieces = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let url = pieces.first.map(String.init), !url.isEmpty else {
            return nil
        }

        let title = pieces.dropFirst().first.map(String.init) ?? ""
        return Snapshot(url: url, title: title)
    }

    private func isTrackable(url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func now() -> String {
        dateFormatter.string(from: Date())
    }
}

final class LocalHTTPServer {
    private let port: UInt16
    private let store: BrowserTimeStore
    private let ingestor: EventIngestor
    private let queue = DispatchQueue(label: "local-http-server")
    private var listener: NWListener?

    init(port: UInt16, store: BrowserTimeStore, ingestor: EventIngestor) {
        self.port = port
        self.store = store
        self.ingestor = ingestor
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let response = self.route(data: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func route(data: Data) -> Data {
        guard let request = String(data: data, encoding: .utf8) else {
            return response(status: "400 Bad Request", body: "Bad request")
        }

        let headerBody = request.components(separatedBy: "\r\n\r\n")
        let header = headerBody.first ?? ""
        let body = headerBody.dropFirst().joined(separator: "\r\n\r\n")
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")

        guard parts.count >= 2 else {
            return response(status: "400 Bad Request", body: "Bad request")
        }

        let method = String(parts[0])
        let target = String(parts[1])
        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        let queryItems = components?.queryItems ?? []

        if method == "OPTIONS" {
            return response(status: "204 No Content", body: "")
        }

        if method == "GET", path == "/health" {
            return json(["ok": true, "paused": ingestor.isPaused])
        }

        if method == "GET", path == "/api/today" {
            return encodeJSON(store.todaySummary())
        }

        if method == "GET", path == "/api/summary" {
            return summaryResponse(queryItems: queryItems)
        }

        if method == "GET", path == "/dashboard" || path == "/" {
            return html(dashboardHTML)
        }

        if method == "POST", path == "/events" {
            guard let bodyData = body.data(using: .utf8),
                  let event = try? JSONDecoder().decode(BrowserEvent.self, from: bodyData) else {
                return response(status: "400 Bad Request", body: "Invalid event")
            }
            ingestor.ingest(event)
            return json(["ok": true])
        }

        return response(status: "404 Not Found", body: "Not found")
    }

    private func summaryResponse(queryItems: [URLQueryItem]) -> Data {
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        let dateString = params["date"] ?? Self.dateFormatter.string(from: Date())
        guard let day = Self.dateFormatter.date(from: dateString) else {
            return response(status: "400 Bad Request", body: "Invalid date")
        }

        let dayStart = Calendar.current.startOfDay(for: day)
        let hourValue = params["hour"] ?? "all"

        if let hour = Int(hourValue), (0..<24).contains(hour) {
            let start = Calendar.current.date(byAdding: .hour, value: hour, to: dayStart) ?? dayStart
            let end = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start
            let label = "\(dateString) \(String(format: "%02d:00", hour))-\(String(format: "%02d:00", hour + 1))"
            return encodeJSON(store.summary(start: start, end: end, windowLabel: label))
        }

        let end = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return encodeJSON(store.summary(start: dayStart, end: end, windowLabel: "\(dateString) All day"))
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return response(
            status: "200 OK",
            contentType: "application/json; charset=utf-8",
            bodyData: data
        )
    }

    private func json(_ object: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return response(
            status: "200 OK",
            contentType: "application/json; charset=utf-8",
            bodyData: data
        )
    }

    private func html(_ value: String) -> Data {
        response(
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            bodyData: Data(value.utf8)
        )
    }

    private func response(status: String, body: String) -> Data {
        response(status: status, contentType: "text/plain; charset=utf-8", bodyData: Data(body.utf8))
    }

    private func response(status: String, contentType: String, bodyData: Data) -> Data {
        var header = ""
        header += "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Headers: content-type\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum AdminAuthenticator {
    static func authorize() -> Bool {
        var authorizationRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorizationRef)
        guard createStatus == errAuthorizationSuccess, let authorizationRef else {
            return false
        }
        defer {
            AuthorizationFree(authorizationRef, [])
        }

        return "system.privilege.admin".withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                let flags: AuthorizationFlags = [
                    .interactionAllowed,
                    .extendRights,
                    .preAuthorize
                ]
                return AuthorizationCopyRights(authorizationRef, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let dataRetentionDays = 7

    private var statusItem: NSStatusItem?
    private var totalMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var pollTimer: Timer?
    private var pruneTimer: Timer?
    private var store: BrowserTimeStore?
    private var ingestor: EventIngestor?
    private var activeTabPollers: [BrowserActiveTabPoller] = []
    private var server: LocalHTTPServer?
    private var started = false
    private let adminLockEnabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !started else { return }
        started = true

        do {
            let supportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("BrowserTimeTracker", isDirectory: true)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

            let store = try BrowserTimeStore(path: supportURL.appendingPathComponent("browser_time.sqlite").path)
            store.pruneData(olderThanDays: Self.dataRetentionDays)
            let ingestor = EventIngestor(store: store)
            let activeTabPollers = Self.makeActiveTabPollers(ingestor: ingestor)
            let server = LocalHTTPServer(port: 38888, store: store, ingestor: ingestor)
            try server.start()

            self.store = store
            self.ingestor = ingestor
            self.activeTabPollers = activeTabPollers
            self.server = server

            configureMenu()
            refreshStatus()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.refreshStatus()
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.pollActiveTabs()
            }
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
                self?.store?.pruneData(olderThanDays: Self.dataRetentionDays)
                self?.refreshStatus()
            }
            registerSystemActivityNotifications()
            activeTabPollers.forEach { $0.poll() }
        } catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private static func makeActiveTabPollers(ingestor: EventIngestor) -> [BrowserActiveTabPoller] {
        let chromeScript = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set activeTab to active tab of front window
            set tabUrl to URL of activeTab
            set tabTitle to title of activeTab
            return tabUrl & linefeed & tabTitle
        end tell
        """

        let safariScript = """
        tell application "Safari"
            if (count of windows) is 0 then return ""
            set activeTab to current tab of front window
            set tabUrl to URL of activeTab
            set tabTitle to name of activeTab
            return tabUrl & linefeed & tabTitle
        end tell
        """

        let edgeScript = """
        tell application "Microsoft Edge"
            if (count of windows) is 0 then return ""
            set activeTab to active tab of front window
            set tabUrl to URL of activeTab
            set tabTitle to title of activeTab
            return tabUrl & linefeed & tabTitle
        end tell
        """

        let firefoxScript = """
        tell application "System Events"
            tell application process "Firefox"
                if not (exists front window) then return ""
                set tabTitle to name of front window
                try
                    set tabUrl to value of combo box 1 of toolbar 1 of front window
                on error
                    try
                        set tabUrl to value of combo box 1 of toolbar "Navigation" of front window
                    on error
                        return ""
                    end try
                end try
                return tabUrl & linefeed & tabTitle
            end tell
        end tell
        """

        return [
            BrowserActiveTabPoller(
                browser: "chrome",
                bundleIDs: [
                    "com.google.Chrome",
                    "com.google.Chrome.canary"
                ],
                scriptSource: chromeScript,
                ingestor: ingestor
            ),
            BrowserActiveTabPoller(
                browser: "safari",
                bundleIDs: [
                    "com.apple.Safari",
                    "com.apple.SafariTechnologyPreview"
                ],
                scriptSource: safariScript,
                ingestor: ingestor
            ),
            BrowserActiveTabPoller(
                browser: "edge",
                bundleIDs: [
                    "com.microsoft.edgemac",
                    "com.microsoft.edgemac.Beta",
                    "com.microsoft.edgemac.Dev",
                    "com.microsoft.edgemac.Canary"
                ],
                scriptSource: edgeScript,
                ingestor: ingestor
            ),
            BrowserActiveTabPoller(
                browser: "firefox",
                bundleIDs: [
                    "org.mozilla.firefox",
                    "org.mozilla.firefoxdeveloperedition",
                    "org.mozilla.nightly"
                ],
                scriptSource: firefoxScript,
                ingestor: ingestor
            )
        ]
    }

    private func registerSystemActivityNotifications() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    private func pollActiveTabs() {
        activeTabPollers.forEach { $0.poll() }
        refreshStatus()
    }

    private func configureMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Browser Time Tracker")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "BT" : ""
            button.toolTip = "Browser Time Tracker"
        }

        let menu = NSMenu()
        let totalMenuItem = NSMenuItem(title: "Today: 0m", action: nil, keyEquivalent: "")
        menu.addItem(totalMenuItem)
        let adminLockMenuItem = NSMenuItem(title: "Admin Lock: On", action: nil, keyEquivalent: "")
        adminLockMenuItem.isEnabled = false
        menu.addItem(adminLockMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))

        let pauseMenuItem = NSMenuItem(title: "Pause Tracking", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(pauseMenuItem)

        menu.addItem(NSMenuItem(title: "Clear Data", action: #selector(clearData), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        self.statusItem = statusItem
        self.totalMenuItem = totalMenuItem
        self.pauseMenuItem = pauseMenuItem
    }

    private func refreshStatus() {
        guard let store else { return }
        let total = store.todaySummary().totalSeconds
        let text = "Today: \(Self.format(seconds: total))"
        totalMenuItem?.title = text
        statusItem?.button?.toolTip = "Browser Time Tracker\n\(text)"
        pauseMenuItem?.title = ingestor?.isPaused == true ? "Resume Tracking" : "Pause Tracking"
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:38888/dashboard")!)
    }

    @objc private func togglePause() {
        guard authorizeAdminAction() else { return }
        guard let ingestor else { return }
        ingestor.setPaused(!ingestor.isPaused)
        pollActiveTabs()
        refreshStatus()
    }

    @objc private func clearData() {
        guard authorizeAdminAction() else { return }
        store?.clearAll()
        ingestor?.resetActiveSessions()
        activeTabPollers.forEach { $0.poll() }
        refreshStatus()
    }

    @objc private func quit() {
        guard authorizeAdminAction() else { return }
        NSApplication.shared.terminate(nil)
    }

    private func authorizeAdminAction() -> Bool {
        guard adminLockEnabled else {
            return true
        }

        if AdminAuthenticator.authorize() {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Admin authentication required"
        alert.informativeText = "This action is protected by Admin Lock."
        alert.alertStyle = .warning
        alert.runModal()
        return false
    }

    @objc private func willSleep() {
        ingestor?.setSystemPaused(true, reason: "sleep")
        refreshStatus()
    }

    @objc private func didWake() {
        ingestor?.setSystemPaused(false, reason: "sleep")
        pollActiveTabs()
    }

    @objc private func screenDidLock() {
        ingestor?.setSystemPaused(true, reason: "screen_locked")
        refreshStatus()
    }

    @objc private func screenDidUnlock() {
        ingestor?.setSystemPaused(false, reason: "screen_locked")
        pollActiveTabs()
    }

    private static func format(seconds: Int) -> String {
        let minutes = max(0, seconds / 60)
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }
}

private func runSelfTest() throws {
    let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("browser-time-tracker-self-test-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let store = try BrowserTimeStore(path: dbURL.path)
    let ingestor = EventIngestor(store: store)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let start = Date()
    let heartbeat = start.addingTimeInterval(75)
    let end = start.addingTimeInterval(120)

    ingestor.ingest(BrowserEvent(
        browser: "chrome",
        event: "page_active",
        url: "https://example.com/article",
        title: "Example Article",
        timestamp: formatter.string(from: start)
    ))
    ingestor.ingest(BrowserEvent(
        browser: "chrome",
        event: "heartbeat",
        url: "https://example.com/article",
        title: "Example Article",
        timestamp: formatter.string(from: heartbeat)
    ))
    ingestor.ingest(BrowserEvent(
        browser: "chrome",
        event: "page_hidden",
        url: "https://example.com/article",
        title: "Example Article",
        timestamp: formatter.string(from: end)
    ))

    let summary = store.todaySummary()
    guard summary.totalSeconds == 120,
          summary.domains.first?.label == "example.com",
          summary.pages.first?.url == "https://example.com/article" else {
        throw NSError(domain: "BrowserTimeSelfTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Self-test failed: \(summary)"
        ])
    }

    let oldStart = start.addingTimeInterval(-8 * 24 * 60 * 60)
    let oldEnd = oldStart.addingTimeInterval(60)
    let oldID = store.startSession(
        browser: "safari",
        url: "https://old.example.com",
        title: "Old Page",
        at: oldStart
    )
    store.closeSession(id: oldID, endedAt: oldEnd)
    store.pruneData(olderThanDays: 7)

    let oldDayStart = Calendar.current.startOfDay(for: oldStart)
    let oldDayEnd = Calendar.current.date(byAdding: .day, value: 1, to: oldDayStart) ?? oldDayStart
    let oldSummary = store.summary(start: oldDayStart, end: oldDayEnd, windowLabel: "Old")
    guard oldSummary.totalSeconds == 0 else {
        throw NSError(domain: "BrowserTimeSelfTest", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Retention self-test failed: \(oldSummary)"
        ])
    }

    print("Self-test passed: totalSeconds=\(summary.totalSeconds)")
}

private let dashboardHTML = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Browser Time Tracker</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f7f4;
      --surface: rgba(255, 255, 252, 0.88);
      --surface-strong: #ffffff;
      --ink: #20231f;
      --muted: #6d756c;
      --line: rgba(38, 48, 35, 0.12);
      --line-strong: rgba(38, 48, 35, 0.18);
      --accent: #0f766e;
      --accent-ink: #064e49;
      --control: #fbfcf8;
      --shadow: 0 16px 42px rgba(38, 48, 35, 0.09), 0 2px 7px rgba(38, 48, 35, 0.05);
      font-family: "Avenir Next", "SF Pro Text", -apple-system, BlinkMacSystemFont, sans-serif;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      background:
        linear-gradient(rgba(32, 35, 31, 0.035) 1px, transparent 1px),
        linear-gradient(90deg, rgba(32, 35, 31, 0.03) 1px, transparent 1px),
        radial-gradient(circle at 10% 0%, rgba(15, 118, 110, 0.09), transparent 34%),
        var(--bg);
      background-size: 28px 28px, 28px 28px, auto, auto;
      color: var(--ink);
      font-size: 14px;
    }

    main { max-width: 1120px; margin: 0 auto; padding: 34px 22px 42px; }

    header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 18px;
      margin-bottom: 22px;
      padding-bottom: 18px;
      border-bottom: 1px solid var(--line);
    }

    h1 {
      font-size: 28px;
      line-height: 1;
      margin: 0;
      font-weight: 760;
      letter-spacing: 0;
    }

    .subtitle {
      color: var(--muted);
      margin-top: 8px;
      font-size: 13px;
      font-variant-numeric: tabular-nums;
    }

    .controls {
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      justify-content: flex-end;
      padding: 6px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: rgba(255, 255, 252, 0.7);
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.85);
    }

    input, select, button {
      height: 34px;
      border-radius: 6px;
      border: 1px solid var(--line-strong);
      background: var(--control);
      color: var(--ink);
      font: inherit;
      padding: 0 10px;
      font-variant-numeric: tabular-nums;
    }

    button { cursor: pointer; }
    input:focus, select:focus, button:focus-visible { outline: 2px solid rgba(15, 118, 110, 0.28); outline-offset: 2px; }

    #today {
      background: var(--ink);
      color: #fff;
      border-color: var(--ink);
      font-weight: 650;
    }

    .summary {
      display: grid;
      grid-template-columns: minmax(190px, 270px) minmax(0, 1fr);
      gap: 18px;
      margin-bottom: 18px;
    }

    .metric, .chart, section {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      box-shadow: var(--shadow);
      backdrop-filter: blur(18px);
    }

    .metric {
      min-height: 222px;
      padding: 20px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      position: relative;
      overflow: hidden;
    }

    .metric::after {
      content: "";
      position: absolute;
      inset: auto 18px 18px 18px;
      height: 5px;
      border-radius: 999px;
      background: linear-gradient(90deg, var(--accent), #1a73e8, #f59e0b);
      opacity: 0.84;
    }

    .metric-label {
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }

    .total {
      font-size: clamp(38px, 7vw, 58px);
      color: var(--accent-ink);
      font-weight: 780;
      line-height: 0.95;
      margin: 8px 0 24px;
      font-variant-numeric: tabular-nums;
    }

    .chart {
      padding: 18px 18px 12px;
      position: relative;
    }

    .chart-title, h2 {
      font-size: 12px;
      margin: 0 0 14px;
      color: var(--muted);
      font-weight: 760;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }

    .day-chart { margin-bottom: 18px; }

    .bars {
      display: grid;
      grid-template-columns: repeat(24, minmax(0, 1fr));
      gap: 4px;
      height: 146px;
      align-items: end;
      padding-top: 4px;
      border-bottom: 1px solid var(--line);
    }

    .day-bars {
      display: grid;
      grid-template-columns: repeat(7, minmax(0, 1fr));
      gap: 10px;
      height: 162px;
      align-items: stretch;
      padding-top: 2px;
      border-bottom: 1px solid var(--line);
    }

    .day-column {
      min-width: 0;
      display: grid;
      grid-template-rows: 20px 1fr;
      gap: 8px;
      text-align: center;
    }

    .day-date {
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }

    .day-bar-wrap { display: flex; align-items: end; min-height: 0; }

    .bar, .day-bar {
      min-width: 0;
      width: 100%;
      height: var(--height);
      border-radius: 5px 5px 0 0;
      background: rgba(38, 48, 35, 0.08);
      border: 0;
      padding: 0;
      cursor: pointer;
      overflow: hidden;
      display: flex;
      flex-direction: column-reverse;
      box-shadow: inset 0 0 0 1px rgba(255,255,255,0.28);
      transition: transform 160ms ease, filter 160ms ease, outline-color 160ms ease;
    }

    .bar:hover, .day-bar:hover { transform: translateY(-2px); filter: saturate(1.08); }
    .bar.active, .day-bar.active { outline: 2px solid rgba(26, 115, 232, 0.58); outline-offset: 2px; }
    .bar.empty, .day-bar.empty { background: rgba(38, 48, 35, 0.08); cursor: default; box-shadow: none; }
    .bar.empty:hover, .day-bar.empty:hover { transform: none; }

    .segment {
      width: 100%;
      min-height: 2px;
      background: var(--color);
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.16);
    }

    .ticks {
      display: grid;
      grid-template-columns: repeat(24, minmax(0, 1fr));
      gap: 4px;
      margin-top: 9px;
      color: var(--muted);
      font-size: 11px;
      text-align: center;
      font-variant-numeric: tabular-nums;
    }

    .day-ticks {
      display: grid;
      grid-template-columns: repeat(7, minmax(0, 1fr));
      gap: 10px;
      margin-top: 9px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
      text-align: center;
    }

    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; }
    section { padding: 18px; min-height: 0; }

    .scroll-list {
      max-height: 360px;
      overflow-y: auto;
      padding-right: 6px;
      scrollbar-color: rgba(38, 48, 35, 0.3) transparent;
    }

    .row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: 14px;
      min-height: 44px;
      padding: 10px 8px;
      border-top: 1px solid var(--line);
      border-radius: 6px;
    }

    .row:first-of-type { border-top: 0; }
    .row:hover { background: rgba(15, 118, 110, 0.055); }
    .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .label-wrap { min-width: 0; display: flex; align-items: center; gap: 9px; }
    .swatch { width: 10px; height: 10px; border-radius: 3px; background: var(--color); flex: 0 0 auto; box-shadow: 0 0 0 1px rgba(0,0,0,0.08); }
    .time { font-variant-numeric: tabular-nums; color: var(--accent-ink); font-weight: 760; }
    a { color: inherit; text-decoration: none; }
    a:hover { text-decoration: underline; text-underline-offset: 3px; }

    @media (prefers-color-scheme: dark) {
      :root {
        color-scheme: dark;
        --bg: #11140f;
        --surface: rgba(25, 29, 23, 0.88);
        --surface-strong: #191d17;
        --ink: #f3f5ef;
        --muted: #a6afa2;
        --line: rgba(243, 245, 239, 0.12);
        --line-strong: rgba(243, 245, 239, 0.18);
        --accent: #2dd4bf;
        --accent-ink: #a7f3d0;
        --control: #171b15;
        --shadow: 0 18px 44px rgba(0,0,0,0.28), 0 2px 8px rgba(0,0,0,0.22);
      }
      body {
        background:
          linear-gradient(rgba(243,245,239,0.035) 1px, transparent 1px),
          linear-gradient(90deg, rgba(243,245,239,0.028) 1px, transparent 1px),
          radial-gradient(circle at 10% 0%, rgba(45, 212, 191, 0.08), transparent 34%),
          var(--bg);
        background-size: 28px 28px, 28px 28px, auto, auto;
      }
      #today { background: #eef2ea; color: #11140f; border-color: #eef2ea; }
    }

    @media (max-width: 760px) {
      main { padding: 22px 14px 30px; }
      .grid, .summary { grid-template-columns: 1fr; }
      header { display: block; }
      .controls { justify-content: flex-start; margin-top: 14px; }
      .metric { min-height: 150px; }
      .bars { gap: 3px; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Browser Time Tracker</h1>
        <div class="subtitle" id="window">Today</div>
      </div>
      <div class="controls">
        <input id="date" type="date">
        <select id="hour"></select>
        <button id="today" type="button">Today</button>
      </div>
    </header>
    <div class="summary">
      <div class="metric">
        <div class="metric-label">Tracked browser time</div>
        <div class="total" id="total">0m</div>
      </div>
      <div class="chart">
        <div class="chart-title">Daily usage</div>
        <div class="day-bars" id="dayBars"></div>
        <div class="day-ticks" id="dayTicks"></div>
      </div>
    </div>
    <div class="chart day-chart">
      <div class="chart-title">Hourly usage</div>
      <div class="bars" id="bars"></div>
      <div class="ticks" id="hourTicks"></div>
    </div>
    <div class="grid">
      <section>
        <h2>Top Websites</h2>
        <div id="domains" class="scroll-list"></div>
      </section>
      <section>
        <h2>Top Pages</h2>
        <div id="pages" class="scroll-list"></div>
      </section>
    </div>
  </main>
  <script>
    const format = (seconds) => {
      const minutes = Math.floor(seconds / 60);
      if (minutes < 60) return `${minutes}m`;
      return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
    };

    const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;'
    }[char]));

    const localDateValue = (date) => {
      const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
      return local.toISOString().slice(0, 10);
    };

    const dateInput = document.getElementById('date');
    const hourSelect = document.getElementById('hour');
    const todayButton = document.getElementById('today');
    const colors = ['#1a73e8', '#0a7a5b', '#f59e0b', '#8b5cf6', '#dc2626', '#0891b2', '#be185d', '#65a30d', '#7c3aed', '#c2410c', '#7a8699'];

    hourSelect.innerHTML = '<option value="all">All day</option>' + Array.from({ length: 24 }, (_, hour) => {
      const start = String(hour).padStart(2, '0');
      const end = String(hour + 1).padStart(2, '0');
      return `<option value="${hour}">${start}:00-${end}:00</option>`;
    }).join('');
    dateInput.value = localDateValue(new Date());
    document.getElementById('hourTicks').innerHTML = Array.from({ length: 24 }, (_, hour) => {
      return `<span>${hour % 3 === 0 ? String(hour).padStart(2, '0') : ''}</span>`;
    }).join('');

    const colorMapFor = (domains) => {
      const map = new Map();
      domains.slice(0, 10).forEach((item, index) => map.set(item.label, colors[index]));
      map.set('Other', colors[10]);
      return map;
    };

    const colorFor = (label, colorMap) => colorMap.get(label) || colorMap.get('Other') || colors[5];

    const renderList = (id, items, colorMap = null) => {
      const node = document.getElementById(id);
      if (!items.length) {
        node.innerHTML = '<div class="row"><span class="label">No data yet</span><span class="time">0m</span></div>';
        return;
      }
      node.innerHTML = items.map((item) => {
        const itemLabel = item.url
          ? `<a class="label" href="${escapeHtml(item.url)}" target="_blank" rel="noreferrer">${escapeHtml(item.label)}</a>`
          : `<span class="label">${escapeHtml(item.label)}</span>`;
        const swatch = colorMap
          ? `<span class="swatch" style="--color:${colorFor(item.label, colorMap)}"></span>`
          : '';
        return `<div class="row"><span class="label-wrap">${swatch}${itemLabel}</span><span class="time">${format(item.seconds)}</span></div>`;
      }).join('');
    };

    const renderSegments = (item, colorMap) => {
      const segments = item.segments?.length ? item.segments : (item.seconds > 0 ? [{ label: 'Other', seconds: item.seconds }] : []);
      return segments.map((segment) => {
        const percent = item.seconds > 0 ? Math.max(2, segment.seconds / item.seconds * 100) : 0;
        return `<span class="segment" title="${escapeHtml(segment.label)} ${format(segment.seconds)}" style="--color:${colorFor(segment.label, colorMap)}; height:${percent}%"></span>`;
      }).join('');
    };

    const renderBars = (hours, colorMap) => {
      const selectedHour = hourSelect.value;
      const maxSeconds = Math.max(...hours.map((item) => item.seconds), 0);
      document.getElementById('bars').innerHTML = hours.map((item) => {
        const percent = maxSeconds > 0 ? Math.max(4, Math.round(item.seconds / maxSeconds * 100)) : 0;
        const active = selectedHour !== 'all' && Number(selectedHour) === item.hour;
        const className = `bar ${item.seconds === 0 ? 'empty' : ''} ${active ? 'active' : ''}`;
        const label = `${String(item.hour).padStart(2, '0')}:00 ${format(item.seconds)}`;
        return `<button class="${className}" data-hour="${item.hour}" title="${label}" style="--height:${percent}%">${renderSegments(item, colorMap)}</button>`;
      }).join('');

      document.querySelectorAll('.bar').forEach((bar) => {
        bar.addEventListener('click', () => {
          hourSelect.value = bar.dataset.hour;
          refresh();
        });
      });
    };

    const renderDayBars = (days, colorMap) => {
      const maxSeconds = Math.max(...days.map((item) => item.seconds), 0);
      document.getElementById('dayBars').innerHTML = days.map((item) => {
        const percent = maxSeconds > 0 ? Math.max(4, Math.round(item.seconds / maxSeconds * 100)) : 0;
        const active = dateInput.value === item.date;
        const className = `day-bar ${item.seconds === 0 ? 'empty' : ''} ${active ? 'active' : ''}`;
        const dateLabel = item.date.slice(5);
        return `<div class="day-column"><div class="day-date">${escapeHtml(dateLabel)}</div><div class="day-bar-wrap"><button class="${className}" data-date="${item.date}" title="${item.date} ${format(item.seconds)}" style="--height:${percent}%">${renderSegments(item, colorMap)}</button></div></div>`;
      }).join('');
      document.getElementById('dayTicks').innerHTML = days.map((item) => `<span>${escapeHtml(item.label)}</span>`).join('');

      document.querySelectorAll('.day-bar').forEach((bar) => {
        bar.addEventListener('click', () => {
          dateInput.value = bar.dataset.date;
          hourSelect.value = 'all';
          refresh();
        });
      });
    };

    const refresh = async () => {
      const params = new URLSearchParams({
        date: dateInput.value,
        hour: hourSelect.value
      });
      const response = await fetch(`/api/summary?${params}`);
      const data = await response.json();
      const colorMap = colorMapFor(data.colorDomains || data.domains);
      document.getElementById('window').textContent = data.windowLabel;
      document.getElementById('total').textContent = format(data.totalSeconds);
      renderBars(data.hours, colorMap);
      renderDayBars(data.days, colorMap);
      renderList('domains', data.domains, colorMap);
      renderList('pages', data.pages);
    };

    dateInput.addEventListener('change', refresh);
    hourSelect.addEventListener('change', refresh);
    todayButton.addEventListener('click', () => {
      dateInput.value = localDateValue(new Date());
      hourSelect.value = 'all';
      refresh();
    });

    refresh();
    setInterval(refresh, 30000);
  </script>
</body>
</html>
"""

if CommandLine.arguments.contains("--self-test") {
    do {
        try runSelfTest()
        exit(0)
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
delegate.start()
app.run()
