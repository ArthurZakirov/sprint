import AppKit
import SwiftUI
import Carbon
import UserNotifications

enum BudgetMode: UInt32, CaseIterable {
    case ticket = 1, daily, planning, unplanned, settings = 6

    static let navigation: [Self] = [.daily, .ticket, .unplanned, .planning, .settings]

    var title: String {
        switch self {
        case .ticket: "Ticket Decision"
        case .daily: "Daily Standup"
        case .planning: "Planning"
        case .unplanned: "Unplanned Work"
        case .settings: "Settings"
        }
    }

    var key: (code: Int, letter: String) {
        switch self {
        case .ticket: (kVK_ANSI_J, "J")
        case .daily: (kVK_ANSI_D, "D")
        case .planning: (kVK_ANSI_P, "P")
        case .unplanned: (kVK_ANSI_U, "U")
        case .settings: (kVK_ANSI_Comma, ",")
        }
    }
}

enum SprintPreferences {
    static let store = UserDefaults(suiteName: "local.sprint.settings")!

    static func referenceKey(_ story: String, _ field: String) -> String {
        "story.\(story).\(field)"
    }

    static func addReference(_ args: [String]) throws {
        guard args.count == 4, ["prs", "chats", "codex", "worktrees"].contains(args[2]),
              TicketStore.registry().contains(where: { $0.ticket.key == args[1] }) else {
            throw TicketStore.failure("Unknown story or reference type.")
        }
        let value = args[3].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline) else {
            throw TicketStore.failure("Provide one reference per command.")
        }
        let key = referenceKey(args[1], args[2])
        var lines = (store.string(forKey: key) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        if !lines.contains(value) {
            lines.append(value)
            store.set(lines.joined(separator: "\n"), forKey: key)
        }
        print(value)
    }
}

struct TicketTask: Codable {
    var description: String? = nil
    var id: String
    var title: String
    var minutes: Int
    var done: Bool
    var included: Bool
    var completedAt: String? = nil
    var startedAt: String? = nil
    var runningSince: String? = nil
    var spentCorrection: Int? = nil
    var status: String {
        if done { return "Finished" }
        if runningSince != nil { return "In Progress" }
        if startedAt != nil { return "Paused" }
        return included ? "Planned" : "Backlog"
    }
    var correctedAt: String? = nil
}

struct WorkBlock: Codable {
    let id: String
    let taskId: String
    let minutes: Int
    let note: String
    let at: String
    var unplanned: Bool?

    var date: Date? { ISO8601DateFormatter().date(from: at) }
}

struct CriterionComment: Codable, Identifiable {
    let id: String
    let criterion: String
    let original: String
    let quote: String
    let kind: String
    let body: String
}

struct LocalTicket: Codable {
    var key: String
    var title: String
    var storyPoints: Int?
    var description: String?
    var why: String?
    var remarks: String?
    var acceptanceCriteria: [String]
    var criterionComments: [CriterionComment]?
    var unplannedReserveMinutes: Int?
    var sprintPointTarget: Int?
    var tasks: [TicketTask]?
    var workBlocks: [WorkBlock]?
    var storyStatus: String?
    var sprint: String?
    var lastWorkedAt: String?
    var budgetStartedAt: String?

    var stage: String {
        storyStatus ?? ((tasks ?? []).contains { $0.startedAt != nil } ? "in-progress" : "planned")
    }
    var hasTimer: Bool { (tasks ?? []).contains { $0.runningSince != nil } }

    static let workweek = 40 * 60
    static let meetings = [("Daily standups", 75, "Five 15-minute meetings."),
                           ("Refinement", 90, "Weekly refinement."),
                           ("Sprint planning", 60, "Weekly planning.")]
    static var meetingMinutes: Int { meetings.reduce(0) { $0 + $1.1 } }
    static var available: Int { workweek - meetingMinutes }

    var reserve: Int { unplannedReserveMinutes ?? 480 }
    var capacity: Int { Self.available - reserve }
    var target: Int { (SprintPreferences.store.object(forKey: "sprintPointTarget") as? Int) ?? sprintPointTarget ?? 4 }
    var factor: Double { Double(capacity) / Double(max(1, target)) }
    var planned: Int { Int((Double(storyPoints ?? 0) * factor).rounded()) }
    func liveBlock(at now: Date = .now) -> WorkBlock? {
        guard let task = tasks?.first(where: { $0.runningSince != nil }),
              let raw = task.runningSince,
              let start = ISO8601DateFormatter().date(from: raw) else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        return WorkBlock(id: "active-" + task.id, taskId: task.id, minutes: minutes,
                         note: "Active work session", at: ISO8601DateFormatter().string(from: now))
    }

    mutating func pause(at now: Date) {
        if let block = liveBlock(at: now) {
            workBlocks = (workBlocks ?? []) + [WorkBlock(id: UUID().uuidString, taskId: block.taskId,
                minutes: block.minutes, note: "Timed work session", at: block.at)]
        }
        for index in (tasks ?? []).indices { tasks?[index].runningSince = nil }
    }

    mutating func setTimer(_ id: String, running: Bool) throws {
        guard let index = tasks?.firstIndex(where: { $0.id == id }),
              let task = tasks?[index], !task.done else {
            throw TicketStore.failure("Timer requires an open task.")
        }
        guard running != (task.runningSince != nil) else { return }
        let now = Date()
        pause(at: now)
        if running {
            let stamp = ISO8601DateFormatter().string(from: now)
            tasks?[index].startedAt = task.startedAt ?? stamp
            tasks?[index].runningSince = stamp
            tasks?[index].included = true
            storyStatus = "in-progress"
            lastWorkedAt = stamp
            budgetStartedAt = budgetStartedAt ?? stamp
        }
    }

    func minutesSpent(on task: TicketTask) -> Int {
        let blocks = (workBlocks ?? []).filter { $0.taskId == task.id }
        let booked = blocks.isEmpty ? (task.done ? task.minutes : 0) : blocks.reduce(0) { $0 + $1.minutes }
        let live = liveBlock()
        return booked + (task.spentCorrection ?? 0) + (live?.taskId == task.id ? live?.minutes ?? 0 : 0)
    }

    mutating func setSpent(_ value: Int, at index: Int) throws {
        guard (0...599999).contains(value), let task = tasks?[index] else {
            throw TicketStore.failure("Spent must be a nonnegative duration.")
        }
        let correction = value - minutesSpent(on: task) + (task.spentCorrection ?? 0)
        tasks?[index].spentCorrection = correction
        tasks?[index].correctedAt = ISO8601DateFormatter().string(from: Date())
    }

    var completed: [TicketTask] { (tasks ?? []).filter(\.done) }
    var open: [TicketTask] {
        (tasks ?? []).filter { !$0.done && ($0.included || $0.startedAt != nil || $0.runningSince != nil) }
            .map { task in
                var remaining = task
                remaining.minutes = max(0, task.minutes - minutesSpent(on: task))
                return remaining
            }
    }
    var spent: Int { investedTasks.reduce(0) { $0 + $1.minutes } }
    var investedTasks: [TicketTask] {
        (tasks ?? []).compactMap { task in
            var entry = task
            entry.minutes = minutesSpent(on: task)
            return entry.minutes > 0 ? entry : nil
        }
    }
    var effort: Int { open.reduce(0) { $0 + $1.minutes } }
    var remaining: Int { planned - spent }
}

enum TicketStore {
    static var selectedFile: URL?
    static let root: URL = {
        let support = URL.applicationSupportDirectory
        let destination = support.appendingPathComponent("Sprint")
        let legacy = support.appendingPathComponent("Time Budget")
        let files = FileManager.default
        if files.fileExists(atPath: legacy.path), !files.fileExists(atPath: destination.path) {
            do {
                try files.moveItem(at: legacy, to: destination)
            } catch {
                if !files.fileExists(atPath: destination.path) {
                    NSLog("Sprint could not migrate its local data: %@", error.localizedDescription)
                    return legacy
                }
            }
        }
        return destination
    }()

    static func storyFile(_ key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent("stories/" + name + ".json")
    }

    static func registry() -> [(url: URL, ticket: LocalTicket)] {
        let directory = root.appendingPathComponent("stories")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        return ([root.appendingPathComponent("ticket.json")] + files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }).compactMap { url in
            guard let ticket = try? JSONDecoder().decode(LocalTicket.self, from: Data(contentsOf: url)),
                  seen.insert(ticket.key).inserted else { return nil }
            return (url, ticket)
        }
    }

    static func preferred(_ entries: [(url: URL, ticket: LocalTicket)]) -> (url: URL, ticket: LocalTicket)? {
        entries.first { $0.ticket.hasTimer } ?? entries.filter { $0.ticket.stage == "in-progress" }.max {
            ($0.ticket.lastWorkedAt ?? "") < ($1.ticket.lastWorkedAt ?? "")
        } ?? entries.first { $0.ticket.stage == "planned" } ?? entries.first
    }

    static var file: URL {
        selectedFile ?? ProcessInfo.processInfo.environment["SPRINT_FILE"].map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("ticket.json")
    }

    static func read() throws -> LocalTicket {
        try JSONDecoder().decode(LocalTicket.self, from: Data(contentsOf: file))
    }

    static func change(_ update: (inout LocalTicket?) throws -> Void) throws -> LocalTicket {
        let path = file
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(path.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw failure("Could not open the ticket lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw failure("Could not lock the ticket.") }
        var ticket: LocalTicket?
        do { ticket = try read() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        try update(&ticket)
        guard let ticket else { throw failure("No ticket. Run ticket-set first.") }
        try validate(ticket)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ticket).write(to: path, options: .atomic)
        return ticket
    }

    static func validate(_ ticket: LocalTicket) throws {
        let tasks = ticket.tasks ?? []
        guard !ticket.key.isEmpty, !ticket.title.isEmpty,
              (0...LocalTicket.available).contains(ticket.reserve), (1...10000).contains(ticket.target), (0...10000).contains(ticket.storyPoints ?? 0),
              tasks.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && (0...599999).contains($0.minutes) }),
              Set(tasks.map(\.id)).count == tasks.count else {
            throw failure("Invalid ticket fields, task IDs, or duration.")
        }
        try tasks.forEach(validateCompletion)
    }

    static func validateCompletion(_ task: TicketTask) throws {
        if task.done && (task.startedAt == nil || task.completedAt == nil) {
            throw failure("A completed task requires both a start and finish. Set --started-at if the start is unknown.")
        }
        if let timestamp = task.startedAt {
            guard let start = ISO8601DateFormatter().date(from: timestamp) else {
                throw failure("Start time must be an ISO 8601 timestamp.")
            }
            if let end = task.completedAt.flatMap({ ISO8601DateFormatter().date(from: $0) }), end < start {
                throw failure("Completion cannot precede the start.")
            }
        }
        if let date = task.completedAt,
           !task.done || ISO8601DateFormatter().date(from: date) == nil {
            throw failure("Completion requires a done task and an ISO 8601 timestamp.")
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Sprint", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func cli(_ args: [String]) throws {
        guard let command = args.first else { return }
        if command == "notes-show" || command == "notes-set" { try ReportNotes.cli(args); return }
        if ProcessInfo.processInfo.environment["SPRINT_FILE"] == nil {
            let entries = registry()
            if command == "story-list" {
                print(String(decoding: try JSONEncoder().encode(entries.map(\.ticket)), as: UTF8.self))
                return
            }
            if args.count >= 3 && args[1] == "--ticket" {
                let key = args[2]
                if let entry = entries.first(where: { $0.ticket.key == key }) {
                    selectedFile = entry.url
                } else if command == "ticket-create" {
                    selectedFile = storyFile(key)
                } else { throw failure("Unknown story.") }
            } else {
                selectedFile = preferred(entries)?.url
            }
        }
        if command == "--help" || command == "help" {
            print("Commands: show | ticket-set | task-add | task-update. Writes accept a JSON object on stdin. Durations are integer minutes.")
            return
        }
        let ticket: LocalTicket
        if command == "show" {
            ticket = try read()
        } else {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let decoder = JSONDecoder()
            ticket = try change { existing in
                if command == "ticket-create" {
                    guard existing == nil else { throw failure("An active ticket already exists. Use sprint ticket edit.") }
                    var incoming = try decoder.decode(LocalTicket.self, from: input)
                    incoming.tasks = []
                    if incoming.stage == "in-progress" {
                        incoming.budgetStartedAt = ISO8601DateFormatter().string(from: Date())
                    }
                    existing = incoming
                    return
                }
                if command == "ticket-set" {
                    var incoming = try decoder.decode(LocalTicket.self, from: input)
                    if let old = existing, old.key == incoming.key {
                        incoming.tasks = incoming.tasks ?? old.tasks
                        incoming.workBlocks = incoming.workBlocks ?? old.workBlocks
                        incoming.criterionComments = incoming.criterionComments ?? old.criterionComments
                        incoming.unplannedReserveMinutes = incoming.unplannedReserveMinutes ?? old.unplannedReserveMinutes
                        incoming.sprintPointTarget = incoming.sprintPointTarget ?? old.sprintPointTarget
                    }
                    guard existing == nil || existing?.key == incoming.key || args == ["ticket-set", "--replace"] else {
                        throw failure("This file already holds a different ticket. Use ticket-set --replace to replace it explicitly.")
                    }
                    incoming.budgetStartedAt = incoming.budgetStartedAt ?? (existing?.key == incoming.key ? existing?.budgetStartedAt : nil)
                    incoming.tasks = incoming.tasks ?? []
                    existing = incoming
                    return
                }
                guard var current = existing else { throw failure("No ticket. Run ticket-set first.") }
                switch command {
                case "criterion-comment-add":
                    struct Input: Decodable {
                        let criterion: String
                        let quote: String
                        let kind: String
                        let body: String
                    }
                    let comment = try decoder.decode(Input.self, from: input)
                    let quote = comment.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard comment.criterion.hasPrefix("AC-"), let number = Int(comment.criterion.dropFirst(3)),
                          number > 0, number <= current.acceptanceCriteria.count,
                          !quote.isEmpty, ["question", "definition"].contains(comment.kind),
                          !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw failure("Provide an AC number, quote, kind and comment body.")
                    }
                    let criterion = current.acceptanceCriteria[number - 1]
                    guard criterion.components(separatedBy: quote).count == 2 else {
                        throw failure("Quote must occur exactly once in the criterion. Use more context if it repeats.")
                    }
                    let entry = CriterionComment(id: UUID().uuidString, criterion: "AC-\(number)", original: criterion,
                                                 quote: quote, kind: comment.kind, body: comment.body)
                    current.criterionComments = (current.criterionComments ?? []) + [entry]
                case "ticket-edit":
                    struct Patch: Decodable {
                        let title: String?
                        let description: String?
                        let why: String?
                        let remarks: String?
                        let storyPoints: Int?
                        let acceptanceCriteria: [String]?
                        let unplannedReserveMinutes: Int?
                        let sprintPointTarget: Int?
                        let storyStatus: String?
                        let sprint: String?
                    }
                    let patch = try decoder.decode(Patch.self, from: input)
                    if let stage = patch.storyStatus {
                        guard ["planned", "in-progress", "done"].contains(stage) else { throw failure("Invalid story status.") }
                        if stage != "in-progress" { current.pause(at: Date()) }
                        else {
                            let stamp = ISO8601DateFormatter().string(from: Date())
                            current.lastWorkedAt = stamp
                            current.budgetStartedAt = current.budgetStartedAt ?? stamp
                        }
                        current.storyStatus = stage
                    }
                    current.sprint = patch.sprint ?? current.sprint
                    current.title = patch.title ?? current.title
                    current.description = patch.description ?? current.description
                    current.why = patch.why ?? patch.description ?? current.why
                    current.remarks = patch.remarks ?? current.remarks
                    current.storyPoints = patch.storyPoints ?? current.storyPoints
                    current.acceptanceCriteria = patch.acceptanceCriteria ?? current.acceptanceCriteria
                    current.unplannedReserveMinutes = patch.unplannedReserveMinutes ?? current.unplannedReserveMinutes
                    current.sprintPointTarget = patch.sprintPointTarget ?? current.sprintPointTarget
                case "work-log":
                    let block = try decoder.decode(WorkBlock.self, from: input)
                    guard current.tasks?.contains(where: { $0.id == block.taskId }) == true,
                          block.date != nil, (1...599999).contains(block.minutes),
                          !block.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !(current.workBlocks ?? []).contains(where: { $0.id == block.id }) else {
                        throw failure("Invalid work block, duplicate ID, or unknown task.")
                    }
                    if let index = current.tasks?.firstIndex(where: { $0.id == block.taskId }),
                       current.tasks?[index].startedAt == nil {
                        current.tasks?[index].startedAt = block.at
                    }
                    current.workBlocks = (current.workBlocks ?? []) + [block]
                case "task-start", "task-resume", "task-pause":
                    struct Input: Decodable { let id: String }
                    let id = try decoder.decode(Input.self, from: input).id
                    try current.setTimer(id, running: command != "task-pause")
                case "task-add":
                    var task = try decoder.decode(TicketTask.self, from: input)
                    if task.done {
                        task.completedAt = task.completedAt ?? ISO8601DateFormatter().string(from: Date())
                    }
                    try validateCompletion(task)
                    current.tasks = (current.tasks ?? []) + [task]
                case "task-update":
                    struct Patch: Decodable {
                        let id: String
                        let title: String?
                        let description: String?
                        let minutes: Int?
                        let spentMinutes: Int?
                        let done: Bool?
                        let completedAt: String?
                        let startedAt: String?
                        let included: Bool?
                    }
                    let patch = try decoder.decode(Patch.self, from: input)
                    guard let index = current.tasks?.firstIndex(where: { $0.id == patch.id }),
                          var task = current.tasks?[index] else { throw failure("Unknown task ID.") }
                    if patch.done == true && task.runningSince != nil {
                        current.pause(at: Date())
                        task.runningSince = nil
                    }
                    task.startedAt = patch.startedAt ?? task.startedAt
                    task.title = patch.title ?? task.title
                    task.description = patch.description ?? task.description
                    task.minutes = patch.minutes ?? task.minutes
                    task.done = patch.done ?? task.done
                    if task.done {
                        task.completedAt = patch.completedAt ?? task.completedAt
                        if task.completedAt == nil && patch.done == true {
                            task.completedAt = ISO8601DateFormatter().string(from: Date())
                        }
                    } else {
                        guard patch.completedAt == nil else { throw failure("Set status to done before recording a completion.") }
                        task.completedAt = nil
                    }
                    try validateCompletion(task)
                    if let included = patch.included, included != task.included {
                        guard !task.done, task.startedAt == nil else {
                            throw failure("Only tasks that have not started can switch between Planned and Backlog.")
                        }
                        task.included = included
                    }
                    current.tasks?[index] = task
                    if let value = patch.spentMinutes { try current.setSpent(value, at: index) }
                default: throw failure("Unknown command. Run --help.")
                }
                existing = current
            }
        }
        try validate(ticket)
        let encoded = try JSONEncoder().encode(ticket)
        let balance = ticket.remaining - ticket.effort
        let output: [String: Any] = [
            "ticket": try JSONSerialization.jsonObject(with: encoded),
            "taskStates": (ticket.tasks ?? []).map { task in
                ["id": task.id, "status": task.status, "spentMinutes": ticket.minutesSpent(on: task),
                 "remainingEffortMinutes": ticket.open.first(where: { $0.id == task.id })?.minutes ?? 0]
            },
            "minutesPerPoint": ticket.factor,
            "unplannedReserveMinutes": ticket.reserve,
            "sprintMinutes": ticket.capacity,
            "sprintPointTarget": ticket.target,
            "balanceMinutes": [
                "planned": ticket.planned, "spent": ticket.spent, "remainingBudget": ticket.remaining,
                "remainingEffort": ticket.effort, "balance": balance,
                "overrun": max(0, -balance), "buffer": max(0, balance)
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

struct UnplannedItem: Codable, Identifiable {
    enum Status: String, Codable, CaseIterable {
        case open = "Open"
        case inProgress = "In Progress"
        case completed = "Completed"
    }

    let id: Int
    var date: Date
    var title: String
    var description: String
    var status: Status
    var completedAt: Date? = nil
}

enum UnplannedStore {
    static var file: URL {
        ProcessInfo.processInfo.environment["SPRINT_UNPLANNED_FILE"].map { URL(fileURLWithPath: $0) }
            ?? TicketStore.root.appendingPathComponent("unplanned-work.json")
    }

    static func read() throws -> [UnplannedItem] {
        do { return try JSONDecoder().decode([UnplannedItem].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    static func save(id: Int?, update: (inout UnplannedItem) -> Void) throws -> (items: [UnplannedItem], saved: UnplannedItem) {
        let path = file
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(path.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw TicketStore.failure("Could not open unplanned work lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TicketStore.failure("Could not lock unplanned work.") }
        var items = try read()
        let index = items.firstIndex { $0.id == id }
        if id != nil && index == nil { throw TicketStore.failure("Unknown unplanned work ID.") }
        let previous = index.map { items[$0] }
        var item = previous ?? UnplannedItem(id: (items.map(\.id).max() ?? 0) + 1, date: .now,
                                             title: "", description: "", status: .open)
        update(&item)
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.title.isEmpty else { throw TicketStore.failure("Provide an item title.") }
        item.completedAt = item.status == .completed
            ? (previous?.status == .completed ? previous?.completedAt ?? previous?.date : .now)
            : nil
        if let index { items[index] = item }
        else { items.append(item) }
        try JSONEncoder().encode(items).write(to: path, options: .atomic)
        return (sorted(items), item)
    }

    static func sorted(_ items: [UnplannedItem]) -> [UnplannedItem] {
        items.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
    }

    static func cli(_ command: String) throws {
        struct Patch: Decodable {
            let id: Int?
            let title: String?
            let description: String?
            let date: String?
            let status: UnplannedItem.Status?
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if command == "unplanned-list" {
            print(String(decoding: try encoder.encode(sorted(read())), as: UTF8.self))
            return
        }
        let patch = try JSONDecoder().decode(Patch.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard command == "unplanned-add" ? patch.id == nil : patch.id != nil else {
            throw TicketStore.failure("Provide an ID only when editing.")
        }
        let date: Date?
        if let raw = patch.date {
            let formatter = ISO8601DateFormatter()
            guard let parsed = formatter.date(from: raw) else {
                throw TicketStore.failure("Use an ISO 8601 date and time with an offset.")
            }
            date = parsed
        } else {
            date = nil
        }
        let result = try save(id: patch.id) { item in
            item.title = patch.title ?? item.title
            item.description = patch.description ?? item.description
            item.date = date ?? item.date
            item.status = patch.status ?? item.status
        }
        print(String(decoding: try encoder.encode(result.saved), as: UTF8.self))
    }

}

enum ReportNotes {
    static var file: URL {
        ProcessInfo.processInfo.environment["SPRINT_NOTES_FILE"].map { URL(fileURLWithPath: $0) }
            ?? TicketStore.root.appendingPathComponent("speaking-notes.json")
    }

    static func read() throws -> [String: String] {
        do { return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }

    static func update(_ changes: [String: String], preserveExisting: Bool = false) throws -> [String: String] {
        let path = file
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(path.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw TicketStore.failure("Could not open notes lock.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TicketStore.failure("Could not lock notes.") }
        var notes = try read()
        notes.merge(changes) { old, new in preserveExisting ? old : new }
        try JSONEncoder().encode(notes).write(to: path, options: .atomic)
        return notes
    }

    static func scope(weekly: Bool, end: Date) -> String {
        (weekly ? "planning:" : "daily:") + ISO8601DateFormatter().string(from: end)
    }

    static func cli(_ args: [String]) throws {
        struct Input: Decodable {
            let mode: String
            let ticket: String?
            let offset: Int?
            let body: String?
        }
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard ["daily", "planning"].contains(input.mode), (-3650...0).contains(input.offset ?? 0),
              input.mode == "daily" || (input.offset ?? 0) == 0 else {
            throw TicketStore.failure("Invalid report or offset.")
        }
        if let key = input.ticket, !TicketStore.registry().contains(where: { $0.ticket.key == key }) {
            throw TicketStore.failure("Unknown story: " + key)
        }
        let weekly = input.mode == "planning"
        let end = period(weekly: weekly, offset: input.offset ?? 0).end
        let key = scope(weekly: weekly, end: end) + (input.ticket.map { ":story:" + $0 } ?? ":general")
        var notes = try read()
        if args.first == "notes-set" {
            guard let body = input.body else { throw TicketStore.failure("Provide a note body.") }
            notes = try update([key: body])
        }
        let result = ["report": input.mode, "end": ISO8601DateFormatter().string(from: end),
                      "ticket": input.ticket ?? "", "body": notes[key, default: ""]]
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }

    static func period(weekly: Bool, offset: Int = 0) -> (start: Date, end: Date, now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let now = Date()
        func meetingDay(_ day: Date) -> Bool {
            let weekday = calendar.component(.weekday, from: day)
            return weekly ? weekday == 4 : (2...6).contains(weekday)
        }
        var end = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        while !meetingDay(end) || end <= now {
            end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        }
        if !weekly {
            for _ in 0..<(-offset) {
                repeat {
                    end = calendar.date(byAdding: .day, value: -1, to: end) ?? end
                } while !meetingDay(end)
            }
        }
        var start = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        while !meetingDay(start) {
            start = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        }
        return (start, end, now)
    }

}

enum StoryFocus { case criteria, budget, progress }

enum DailyActionStage: Equatable { case actions, draft, destination }

final class Scenario: ObservableObject {
    @Published var dailyActionStage: DailyActionStage?
    @Published var dailyPrompt = ""
    @Published var dailyDestination = 0
    @Published var dailyDestinationConfirmed = false

    @Published var speakingNotes: [String: String] = [:]
    @Published var notesError: String?

    func reloadNotes() {
        do {
            if let old = UserDefaults.standard.dictionary(forKey: "speakingNotes") as? [String: String], !old.isEmpty {
                speakingNotes = try ReportNotes.update(old, preserveExisting: true)
                UserDefaults.standard.removeObject(forKey: "speakingNotes")
            } else {
                speakingNotes = try ReportNotes.read()
            }
            notesError = nil
        } catch {
            notesError = error.localizedDescription
        }
    }

    func setNote(_ body: String, key: String) {
        speakingNotes[key] = body
        do {
            speakingNotes = try ReportNotes.update([key: body])
            notesError = nil
        } catch {
            notesError = error.localizedDescription
        }
    }
    @Published var unplannedItems: [UnplannedItem] = []
    @Published var selectedUnplanned: Int?
    @Published var unplannedDraft: UnplannedItem?
    @Published var unplannedError: String?
    @Published var selectedReportRow: ReportRowID?

    func reloadUnplanned() {
        do {
            unplannedItems = try UnplannedStore.read().sorted {
                $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date
            }
            if !unplannedItems.contains(where: { $0.id == selectedUnplanned }) {
                selectedUnplanned = unplannedItems.first?.id
            }
            unplannedError = nil
        } catch {
            unplannedError = error.localizedDescription
        }
    }

    func saveUnplanned() {
        guard let draft = unplannedDraft else { return }
        do {
            let result = try UnplannedStore.save(id: draft.id == 0 ? nil : draft.id) { item in
                item.title = draft.title
                item.description = draft.description
                item.date = draft.date
                item.status = draft.status
            }
            unplannedItems = result.items
            selectedUnplanned = result.saved.id
            unplannedDraft = nil
            unplannedError = nil
        } catch {
            unplannedError = error.localizedDescription
        }
    }

    @Published var actionIndex: Int?
    @Published var actionWorktrees: [URL]?
    @Published var actionMessage: String?
    @Published var jiraURL = SprintPreferences.store.string(forKey: "jiraURL") ?? "" {
        didSet { SprintPreferences.store.set(jiraURL, forKey: "jiraURL") }
    }
    @Published var ticketsDirectory = SprintPreferences.store.string(forKey: "ticketsDirectory") ?? "" {
        didSet { SprintPreferences.store.set(ticketsDirectory, forKey: "ticketsDirectory") }
    }
    @Published var pointTarget = SprintPreferences.store.integer(forKey: "sprintPointTarget")

    func setPointTarget(_ value: Int) {
        pointTarget = value
        SprintPreferences.store.set(value, forKey: "sprintPointTarget")
    }

    @Published var storyFocus: StoryFocus?
    @Published var selectedBudget: String?
    @Published var selectedCriterion: Int?
    @Published var expandedComments: Set<String> = []
    @Published var selectedTask: String?
    @Published var taskDetailsID: String?
    @Published var ticket: LocalTicket?
    @Published var ticketReadError: String?

    @Published var stories: [LocalTicket] = []
    var ticketURL: URL?

    func reloadTicket(preferActive: Bool = false, key: String? = nil) {
        let entries = TicketStore.registry()
        stories = entries.map(\.ticket)
        let requested = key ?? (preferActive ? nil : ticket?.key)
        guard let entry = entries.first(where: { $0.ticket.key == requested }) ?? TicketStore.preferred(entries) else {
            ticket = nil
            ticketURL = nil
            ticketReadError = "No local stories. Create one with sprint ticket create."
            return
        }
        let changedStory = ticket?.key != entry.ticket.key
        if changedStory {
            editingTask = nil
            expandedComments = []
        }
        if changedStory || preferActive {
            selectedTask = nil
            taskDetailsID = nil
            selectedCriterion = nil
            selectedBudget = entry.ticket.stage == "done"
                ? (entry.ticket.remaining < 0 ? "Overrun" : "Unused Budget")
                : "Remaining budget"
        }
        ticketURL = entry.url
        ticket = entry.ticket
        ticketReadError = nil
    }

    @Published var dailyOffset = 0

    func switchTab(_ step: Int) {
        if mode == .daily {
            guard dailyActionStage == nil else { return }
            selectedReportRow = nil
            dailyOffset = max(-3650, min(0, dailyOffset + step))
            reloadNotes()
            return
        }
        guard mode == .ticket, let key = ticket?.key else { return }
        let keys = TicketStore.registry().map(\.ticket.key)
        guard keys.count > 1, let index = keys.firstIndex(of: key) else { return }
        storyFocus = nil
        reloadTicket(key: keys[(index + step + keys.count) % keys.count])
    }

    @Published var mode: BudgetMode = .ticket
    @Published var editingTask: String?
    @Published var draft = ""
    @Published var invalidDuration = false
}

enum ReportRowID: Hashable {
    case jira(story: String, task: String)
    case unplanned(Int)
}

struct BudgetView: View {
    @ObservedObject var scenario = Scenario()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let planned = scenario.ticket?.planned ?? 0
            let tasks = currentTasks
            let remaining = scenario.ticket?.remaining ?? 0
            let openTasks = scenario.ticket?.stage == "done" ? [] : scenario.ticket?.open ?? []
            let effort = openTasks.reduce(0) { $0 + $1.minutes }

            if scenario.mode == .daily {
                dailyView()
            } else if scenario.mode == .planning {
                weeklyView()
            } else if scenario.mode == .unplanned {
                unplannedView()
            } else if scenario.mode == .settings {
                settingsView()
            } else {
            let forecast = scenario.ticket.map(storyForecast)
            let atRisk = forecast.map { $0.margin < 0 } ?? false
            let tone: Color = atRisk ? .red : .green
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    Text("Story").font(viewTitleFont)
                    Button("Close") { NSApp.keyWindow?.orderOut(nil) }
                        .help("Close Sprint window (⌘W). Quit Sprint with ⌘Q.")
                    storyBar
                        .padding(.horizontal, 10)
                        .frame(height: 106)
                        .background(Color(red: 0.15, green: 0.18, blue: 0.23), in: RoundedRectangle(cornerRadius: 6))
                }
                GeometryReader { layout in
                let focus = scenario.storyFocus
                let columnWidth = focus == nil ? max(1, (layout.size.width - 65) / 2) : min(layout.size.width, 1050)
                HStack(alignment: .top, spacing: 32) {
                if focus == nil || focus == .budget {
                ScrollViewReader { proxy in
                ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    if let ticket = scenario.ticket, let forecast {
                        Text(storyLabel(ticket, forecast: forecast))
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(ticket.stage == "done" || forecast.eligible ? tone : .secondary)

                    }
                }
                .frame(height: 24, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ticket Budget").font(storyCardTitle)
                    if let error = scenario.ticketReadError {
                        Text(error).foregroundStyle(.orange).font(.system(size: 15))
                    }
                    budgetTimeline(planned: planned, remaining: remaining, effort: effort, openTasks: openTasks, completed: scenario.ticket?.investedTasks ?? [], showForecast: scenario.ticket?.stage != "done")
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        budgetDefinition("📅", "Planned", clock(planned), "Story points × developer time per point.")
                        budgetDefinition("⏱️", "Spent", "−" + clock(planned - remaining), "Time already spent on the ticket.")
                        Divider()
                        if scenario.ticket?.stage == "done" {
                            budgetDefinition(remaining < 0 ? "❗" : "✅", remaining < 0 ? "Overrun" : "Unused Budget",
                                       clock(abs(remaining)), "Difference between planned and spent at completion.",
                                       total: true, color: remaining < 0 ? .red : .green)
                        } else {
                            budgetDefinition("⌛", "Remaining budget", clock(remaining), "Planned time minus time spent.", total: true)
                        }
                        if scenario.ticket?.stage != "done" {
                        budgetDefinition("🛠️", "Remaining effort", "−" + clock(effort), "Open estimates minus time already spent.")
                        Divider()
                        let balance = remaining - effort
                        budgetDefinition(balance < 0 ? "🔴" : "🟢",
                                   balance < 0 ? "Overrun" : "Buffer",
                                   (balance < 0 ? "−" : balance > 0 ? "+" : "") + clock(abs(balance)),
                                   balance < 0 ? "Estimated time shortfall." : "Estimated time left after completion.",
                                   total: true, color: balance < 0 ? .red : .green)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 680, alignment: .topLeading)
                .background(Self.storyCardBackground, in: RoundedRectangle(cornerRadius: 14))



                }
                .padding(.bottom, 24)
                }
                .onChange(of: scenario.selectedBudget) { _, metric in
                    if let metric { proxy.scrollTo(metric) }
                }
                }
                .frame(width: focus == nil ? columnWidth * 2 / 3 : columnWidth, alignment: .topLeading)
                }
                if focus == nil { Divider() }
                if focus != .budget {
                ScrollViewReader { proxy in
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let ticket = scenario.ticket {
                        if focus != .progress {
                        VStack(alignment: .leading, spacing: 12) {
                        Text(ticket.title).font(storyCardTitle).lineLimit(2)
                        Picker("Story status", selection: Binding(
                            get: { scenario.ticket?.stage ?? "planned" },
                            set: { stage in
                                _ = updateTicket { current in
                                    if stage != "in-progress" { current.pause(at: Date()) }
                                    else {
                                        let stamp = ISO8601DateFormatter().string(from: Date())
                                        current.lastWorkedAt = stamp
                                        current.budgetStartedAt = current.budgetStartedAt ?? stamp
                                    }
                                    current.storyStatus = stage
                                }
                            }
                        )) {
                            Text("Planned").tag("planned")
                            Text("In Progress").tag("in-progress")
                            Text("Done").tag("done")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)

                        Text(ticket.key + (ticket.storyPoints.map { "  ·  \($0) Story Points" } ?? ""))
                            .foregroundStyle(.secondary)
                        if focus == nil {
                        Text("Why").font(.system(size: 16, weight: .semibold))
                        Text(ticket.why ?? ticket.description ?? "—").font(.system(size: 17)).textSelection(.enabled)
                        }
                        if focus != .progress {
                        HStack {
                            Text("Acceptance Criteria").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            let ids = Set((ticket.criterionComments ?? []).map(\.id))
                            if !ids.isEmpty {
                                let allExpanded = ids.isSubset(of: scenario.expandedComments)
                                Button(allExpanded ? "Collapse all comments" : "Expand all comments") {
                                    scenario.expandedComments = allExpanded ? [] : ids
                                }
                                .keyboardShortcut("k", modifiers: [.command, .shift])
                                .help("⌘⇧K")
                            }
                        }
                        .padding(.top, 4)
                        ForEach(Array(ticket.acceptanceCriteria.enumerated()), id: \.offset) { index, criterion in
                            criterionView(criterion, index: index, comments: ticket.criterionComments ?? [])
                                .id(index)
                        }
                        let unmatched = (ticket.criterionComments ?? []).filter { !ticket.acceptanceCriteria.contains($0.original) }
                        if !unmatched.isEmpty {
                            Text("Comments on changed criteria").font(.system(size: 15, weight: .semibold))
                            ForEach(unmatched) { comment in commentCard(comment) }
                        }
                        }
                        if focus == nil {
                        Text("Remarks").font(.system(size: 16, weight: .semibold))
                        Text(ticket.remarks ?? "—").font(.system(size: 17)).textSelection(.enabled)
                        }
                        }
                        .modifier(StoryCard())
                        }
                if focus == .progress {
                    HStack(alignment: .top, spacing: 24) {
                        progressTable(tasks, showDivider: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let task = tasks.first(where: { $0.id == scenario.selectedTask }) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(task.title).font(.title2.bold())
                                Text(task.description.flatMap { $0.isEmpty ? nil : $0 } ?? "No description yet.")
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 275, alignment: .leading)
                            .padding(.top, 12)
                        }
                    }
                    .modifier(StoryCard())
                } else if focus == nil {
                    progressTable(tasks, showDivider: false)
                        .modifier(StoryCard())
                }
                        if focus == nil {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("References").font(storyCardTitle)
                                ForEach([("Pull Requests", "prs"), ("ChatGPT", "chats"),
                                          ("Codex", "codex"), ("Worktrees", "worktrees")], id: \.1) { label, field in
                                    Text(label).fontWeight(.semibold)
                                    TextField("One reference per line", text: storyLinks(ticket.key, field: field), axis: .vertical)
                                        .id(ticket.key + field)
                                }
                            }
                            .modifier(StoryCard())
                        }
                    } else {
                        Text(scenario.ticketReadError ?? "Loading ticket…")
                            .font(.system(size: 17)).foregroundStyle(.orange)
                    }
                }
                }
                .onChange(of: scenario.selectedCriterion) { _, index in
                    if let index { proxy.scrollTo(index) }
                }
                .onChange(of: scenario.selectedTask) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                }
                .frame(width: focus == nil ? columnWidth * 4 / 3 : columnWidth, alignment: .topLeading)
                }
                }
                .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("A  Criteria    T  Budget    P  Progress    ↩  Story actions    ⌘,  Settings    ⌥ J  Toggle    Esc  Back / Close")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.085, green: 0.10, blue: 0.13))
            .overlay {
                if let index = scenario.actionIndex {
                    Color.black.opacity(0.38).overlay { storyActionMenu(index) }
                }
            }
            .preferredColorScheme(.dark)
            }
        }
    }

    private let storyCardTitle = Font.system(size: 19, weight: .semibold)
    private static let storyCardBackground = Color.white.opacity(0.07)

    private struct StoryCard: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BudgetView.storyCardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @AppStorage("workdayHours", store: SprintPreferences.store) private var workdayHours = "09:00-12:00,12:45-17:45"
    @AppStorage("ticketReminderPercentages", store: SprintPreferences.store) private var ticketReminderPercentages = "50,80"
    @AppStorage("sprintRemindersEnabled", store: SprintPreferences.store) private var sprintRemindersEnabled = false
    @AppStorage("sprintReminderStart", store: SprintPreferences.store) private var sprintReminderStart = Date().timeIntervalSince1970
    @AppStorage("sprintReminderEnd", store: SprintPreferences.store) private var sprintReminderEnd = Date().addingTimeInterval(7 * 86400).timeIntervalSince1970

    private func dateBinding(_ value: Binding<Double>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: value.wrappedValue) },
                set: { value.wrappedValue = $0.timeIntervalSince1970 })
    }

    private func settingsView() -> some View {
        reportShell(.settings, subtitle: "") {
            let target = scenario.pointTarget > 0 ? scenario.pointTarget : scenario.ticket?.target ?? 4
            let capacity = scenario.ticket?.capacity ?? LocalTicket.available - 480
            VStack(alignment: .leading, spacing: 14) {
                Stepper("Story point target per sprint   \(target)", value: Binding(
                    get: { target }, set: scenario.setPointTarget
                ), in: 1...1000)
                Text("Hours available for ticket work per five-day sprint   " + clock(capacity))
                Text("Hours available per story point   " + clock(Int((Double(capacity) / Double(target)).rounded())))
                Divider()
                Text("Jira Base URL")
                TextField("https://jira.example.com", text: $scenario.jiraURL)
                Text("Tickets Folder")
                TextField("~/tickets", text: $scenario.ticketsDirectory)
                Divider()
                Text("Workday reminders").font(.headline)
                TextField("Weekday hours (HH:mm-HH:mm, …)", text: $workdayHours)
                if WorkdayReminder.windows(workdayHours) == nil {
                    Text("Enter ordered, non-overlapping work windows.").foregroundStyle(.red)
                }
                TextField("Ticket reminder percentages", text: $ticketReminderPercentages)
                Toggle("Sprint deadline reminders", isOn: $sprintRemindersEnabled)
                    .onChange(of: sprintRemindersEnabled) { _, enabled in
                        guard enabled else { return }
                        if SprintPreferences.store.object(forKey: "sprintReminderStart") == nil {
                            sprintReminderStart = Date().timeIntervalSince1970
                        }
                        if SprintPreferences.store.object(forKey: "sprintReminderEnd") == nil {
                            sprintReminderEnd = Date().addingTimeInterval(7 * 86400).timeIntervalSince1970
                        }
                    }
                if sprintRemindersEnabled {
                    DatePicker("Sprint starts", selection: dateBinding($sprintReminderStart))
                    DatePicker("Sprint ends", selection: dateBinding($sprintReminderEnd))
                    if sprintReminderEnd <= sprintReminderStart {
                        Text("Sprint end must be after its start.").foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: 600)
        }
    }

    private func storyLinks(_ key: String, field: String) -> Binding<String> {
        let storageKey = SprintPreferences.referenceKey(key, field)
        return Binding(get: { SprintPreferences.store.string(forKey: storageKey) ?? "" },
                       set: { SprintPreferences.store.set($0, forKey: storageKey) })
    }

    private var storyActionLabels: [String] {
        if let trees = scenario.actionWorktrees {
            return ["Open All Worktrees"] + trees.map(\.lastPathComponent)
        }
        return ["J  Open in Jira", "P  Open PRs in Chrome", "V  Open Worktrees in VS Code", "G  Open in ChatGPT", "W  Resume Codex in Warp"]
    }

    private func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func directories(in path: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func openStoryURLs(_ urls: [URL], bundle: String? = nil) {
        guard let bundle else {
            scenario.actionIndex = nil
            for url in urls { NSWorkspace.shared.open(url) }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            scenario.actionMessage = "The requested app is not installed."
            return
        }
        scenario.actionIndex = nil
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, error in
            if let error { NSLog("Sprint could not open story resources: %@", error.localizedDescription) }
        }
    }

    func handleStoryActionKey(_ key: Int) -> Bool {
        guard scenario.mode == .ticket, let story = scenario.ticket else { return false }
        if let index = scenario.actionIndex {
            let shortcuts = [kVK_ANSI_J, kVK_ANSI_P, kVK_ANSI_V, kVK_ANSI_G, kVK_ANSI_W]
            if scenario.actionWorktrees == nil, let row = shortcuts.firstIndex(of: key) {
                performStoryAction(row, story: story)
                return true
            }
            let count = storyActionLabels.count
            switch key {
            case kVK_UpArrow: scenario.actionIndex = (index + count - 1) % count
            case kVK_DownArrow: scenario.actionIndex = (index + 1) % count
            case kVK_Escape:
                if scenario.actionWorktrees != nil {
                    scenario.actionWorktrees = nil
                    scenario.actionIndex = 2
                    scenario.actionMessage = nil
                } else { scenario.actionIndex = nil }
            case kVK_Return, kVK_ANSI_KeypadEnter: performStoryAction(index, story: story)
            default: break
            }
            return true
        }
        guard key == kVK_Return || key == kVK_ANSI_KeypadEnter else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(story.key, forType: .string)
        scenario.actionWorktrees = nil
        scenario.actionMessage = nil
        scenario.actionIndex = 0
        return true
    }

    private func performStoryAction(_ index: Int, story: LocalTicket) {
        scenario.actionMessage = nil
        if let trees = scenario.actionWorktrees {
            openStoryURLs(index == 0 ? trees : [trees[index - 1]], bundle: "com.microsoft.VSCode")
            return
        }
        switch index {
        case 0:
            guard let base = webURL(scenario.jiraURL), base.query == nil, base.fragment == nil else {
                scenario.actionMessage = "Set a Jira base URL in Settings."
                return
            }
            let browse = base.lastPathComponent == "browse" ? base : base.appendingPathComponent("browse")
            openStoryURLs([browse.appendingPathComponent(story.key)])
        case 1:
            let urls = storyLinks(story.key, field: "prs").wrappedValue.split(whereSeparator: \.isNewline)
                .compactMap { webURL(String($0)) }
            guard !urls.isEmpty else { scenario.actionMessage = "Add PR URLs to the story first."; return }
            openStoryURLs(urls, bundle: "com.google.Chrome")
        case 2:
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = scenario.ticketsDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let roots = root.isEmpty ? ["tickets", "Tickets"].map { home.appendingPathComponent($0) }
                : [URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)]
            let key = story.key.lowercased()
            let folders = roots.flatMap { directories(in: $0) }
            let matches = folders.filter {
                let name = $0.lastPathComponent.lowercased()
                return name == key || name.hasPrefix(key + "-")
            }
            let configured = storyLinks(story.key, field: "worktrees").wrappedValue.split(whereSeparator: \.isNewline)
                .compactMap { line -> URL? in
                    let path = NSString(string: String(line)).expandingTildeInPath
                    guard path.hasPrefix("/") else { return nil }
                    let url = URL(fileURLWithPath: path)
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : nil
                }
            let trees = configured + matches.flatMap { directories(in: $0) }.filter {
                ["worktrees", "work trees"].contains($0.lastPathComponent.lowercased())
            }.flatMap { directories(in: $0) }
            let unique = trees.reduce(into: [URL]()) { result, tree in
                if !result.contains(where: { $0.resolvingSymlinksInPath() == tree.resolvingSymlinksInPath() }) {
                    result.append(tree)
                }
            }
            guard !unique.isEmpty else { scenario.actionMessage = "No worktrees found in the Tickets folder."; return }
            scenario.actionWorktrees = unique
            scenario.actionIndex = 0
        case 3:
            let links = storyLinks(story.key, field: "chats").wrappedValue.split(whereSeparator: \.isNewline)
            guard let url = links.lazy.compactMap({ webURL(String($0)) }).first(where: {
                $0.scheme == "https" && ["chatgpt.com", "chat.openai.com"].contains($0.host?.lowercased() ?? "")
            }) else {
                scenario.actionMessage = "Add a ChatGPT conversation URL to the story first."
                return
            }
            openStoryURLs([url], bundle: "com.openai.codex")
        case 4:
            let ids = storyLinks(story.key, field: "codex").wrappedValue.split(whereSeparator: \.isWhitespace)
            guard let id = ids.first.flatMap({ UUID(uuidString: String($0)) }) else {
                scenario.actionMessage = "Add a Codex session ID to the story first."
                return
            }
            let helper = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/bin/codex_resume_warp")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                scenario.actionMessage = "The Codex Warp launcher is missing."
                return
            }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--session-id", id.uuidString.lowercased()]
            process.terminationHandler = { result in
                guard result.terminationStatus != 0 else { return }
                DispatchQueue.main.async {
                    self.scenario.actionMessage = "Could not resume the Codex session in Warp."
                    if self.scenario.ticket?.key == story.key && self.scenario.mode == .ticket {
                        self.scenario.actionIndex = 4
                    }
                }
            }
            do {
                try process.run()
                scenario.actionIndex = nil
            } catch {
                scenario.actionMessage = "Could not start the Codex Warp launcher."
            }
        default: break
        }
    }

    private func storyActionMenu(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scenario.actionWorktrees == nil ? "Story Actions" : "Worktrees").font(.title2.bold())
            Text("Ticket key copied  ·  ↑ ↓ Select  ·  ↩ Open  ·  Esc Back").foregroundStyle(.secondary)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(storyActionLabels.enumerated()), id: \.offset) { row, label in
                        Button {
                            if let story = scenario.ticket { performStoryAction(row, story: story) }
                        } label: {
                            Text(label).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(row == index ? Color.blue.opacity(0.42) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .id(row)
                    }
                }
            }
            .frame(maxHeight: 240)
            .onChange(of: index) { _, row in proxy.scrollTo(row) }
            }
            if let message = scenario.actionMessage { Text(message).foregroundStyle(.orange) }
        }
        .padding(22)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func progressTable(_ tasks: [TicketTask], showDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showDivider { Divider().padding(.bottom, 6) }
            Text("Progress").font(storyCardTitle)
            HStack {
                Text("Estimate").frame(width: 70)
                Text("Spent").frame(width: 70)
                Text("Task").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                statusColumn()
                timingColumns(showDuration: false)
                Color.clear.frame(width: 74, height: 1)
            }
            .padding(.horizontal, 6)
            ForEach(tasks, id: \.id) { task in
                item(task).id(task.id)
            }
        }
        .padding(.top, 12)
    }

    private var storyBar: some View {
        let stories = scenario.stories.map { $0.key == scenario.ticket?.key ? scenario.ticket ?? $0 : $0 }
        let active = TicketStore.preferred(stories.map { (url: TicketStore.root, ticket: $0) })?.ticket.key
        let visible = active == scenario.ticket?.key ? stories.filter { $0.key == active } : stories
        return HStack {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(visible, id: \.key) { story in
                        let key = story.key
                            Button {
                                scenario.storyFocus = nil
                                scenario.reloadTicket(key: key)
                            } label: {
                                storyTabLabel(story)
                            }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(scenario.ticket?.key == key ? Color.cyan.opacity(0.23) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(scenario.ticket?.key == key ? Color.cyan : Color.secondary)
                    }
                }
            }

        }
    }

    private func anchoredComments(_ criterion: String, index: Int, comments: [CriterionComment]) -> [CriterionComment] {
        let id = "AC-\(index + 1)"
        return comments.filter {
            $0.original == criterion && ($0.criterion == id ||
                scenario.ticket?.acceptanceCriteria.filter { $0 == criterion }.count == 1)
        }
    }

    private func criterionView(_ criterion: String, index: Int, comments: [CriterionComment]) -> some View {
        let anchored = anchoredComments(criterion, index: index, comments: comments)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("AC-\(index + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .monospacedDigit().frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(highlightedCriterion(criterion, comments: anchored))
                    .font(.system(size: 17)).textSelection(.enabled)
                ForEach(anchored) { comment in commentCard(comment) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if scenario.selectedCriterion == index {
                RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.32))
            }
        }
    }

    private func commentCard(_ comment: CriterionComment) -> some View {
        let tint: Color = comment.kind == "question" ? .orange : .cyan
        let expanded = Binding(
            get: { scenario.expandedComments.contains(comment.id) },
            set: { isExpanded in
                if isExpanded {
                    scenario.expandedComments.insert(comment.id)
                } else {
                    scenario.expandedComments.remove(comment.id)
                }
            }
        )
        return DisclosureGroup(isExpanded: expanded) {
            Text(comment.body).font(.system(size: 16)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Label(comment.kind == "question" ? "Open question" : "Definition",
                      systemImage: comment.kind == "question" ? "questionmark.bubble" : "text.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(tint.opacity(0.17), in: Capsule())
                Text("“" + comment.quote + "”").font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 4).allowsHitTesting(false)
        }
    }

    private func highlightedCriterion(_ criterion: String, comments: [CriterionComment]) -> AttributedString {
        var text = AttributedString(criterion)
        for comment in comments {
            if let range = text.range(of: comment.quote) {
                text[range].foregroundColor = comment.kind == "question" ? .orange : .cyan
                text[range].underlineStyle = .single
            }
        }
        return text
    }

    private func reportPeriod(weekly: Bool) -> (start: Date, end: Date, now: Date) {
        ReportNotes.period(weekly: weekly, offset: scenario.dailyOffset)
    }

    private func reportCompletions(for ticket: LocalTicket, weekly: Bool) -> [TicketTask] {
        let period = reportPeriod(weekly: weekly)
        return (ticket.tasks ?? []).filter { task in
            guard task.done, let timestamp = task.completedAt,
                  let date = ISO8601DateFormatter().date(from: timestamp) else { return false }
            return date >= period.start && date < period.end && date <= period.now
        }
    }

    private func reportBlocks(for ticket: LocalTicket, weekly: Bool) -> [WorkBlock] {
        let (start, end, now) = reportPeriod(weekly: weekly)
        return ((ticket.workBlocks ?? []) + (ticket.liveBlock(at: now).map { [$0] } ?? [])).filter {
            guard let date = $0.date else { return false }
            return date >= start && date < end && date <= now
        }.sorted { ($0.date ?? now) < ($1.date ?? now) }
    }

    private func dailyUnplannedItems() -> [UnplannedItem] {
        let period = reportPeriod(weekly: false)
        return scenario.unplannedItems.filter { item in
            let completed = item.completedAt ?? item.date
            return item.status == .completed && completed >= period.start
                && completed < period.end && completed <= period.now
        }.sorted {
            let left = $0.completedAt ?? $0.date
            let right = $1.completedAt ?? $1.date
            return left == right ? $0.id > $1.id : left > right
        }
    }

    private func dailyUnplannedList() -> some View {
        let items = dailyUnplannedItems()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Unplanned Work").font(.headline)
            if let error = scenario.unplannedError { Text(error).foregroundStyle(.orange) }
            if items.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(items) { item in
                let id = ReportRowID.unplanned(item.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text("U-\(item.id)").monospacedDigit().foregroundStyle(.secondary)
                    Text(item.title).fontWeight(.semibold)
                    if scenario.selectedReportRow == id, !item.description.isEmpty {
                        Text(item.description).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background {
                    if scenario.selectedReportRow == id {
                        RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.32))
                    }
                }
                .id(id)
            }
        }
        .modifier(ReportSection(tint: .cyan))
    }

    func handleDailyActionKey(_ key: Int, editingText: Bool) -> Bool {
        guard scenario.mode == .daily else { return false }
        let enter = key == kVK_Return || key == kVK_ANSI_KeypadEnter
        switch scenario.dailyActionStage {
        case nil:
            guard enter, !editingText else { return false }
            scenario.dailyActionStage = .actions
        case .actions:
            if enter { prepareDailyPrompt() }
            else if key == kVK_Escape { scenario.dailyActionStage = nil }
        case .draft:
            if enter { chooseDailyDestination() }
            else if key == kVK_Escape { scenario.dailyActionStage = .actions }
            else { return editingText ? false : true }
        case .destination:
            if key == kVK_Escape { scenario.dailyActionStage = .draft }
            else if key == kVK_UpArrow || key == kVK_DownArrow {
                scenario.dailyDestination = 1 - scenario.dailyDestination
                scenario.dailyDestinationConfirmed = false
            } else if enter { scenario.dailyDestinationConfirmed = true }
        }
        return true
    }

    private func prepareDailyPrompt() {
        let period = reportPeriod(weekly: false)
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: period.start)
        let end = formatter.string(from: period.end)
        let offset = scenario.dailyOffset
        let tickets = reportGroups(weekly: false).map { $0.story.key }.joined(separator: ", ")
        scenario.dailyPrompt = """
        Prepare my Sprint Daily Standup talking points for the period from \(start) up to (excluding) \(end). Use evidence available as of now. Sprint currently shows these stories: \(tickets.isEmpty ? "none" : tickets).

        Review relevant Slack messages, PR status and review activity, and the work chats linked to these stories where access is available. Compare with Sprint's task records and existing speaking notes. Report gaps in access and distinguish confirmed outcomes from open work. Update local task progress only when supported by evidence. Do not infer time spent or mark work complete without evidence.

        For each ticket, write short, speakable bullets:
        • Outcome / Deliverable: What did I build, finish, or move forward?
        • Benefit: What does that enable, improve, or prevent?
        • Complexity: Mention a concrete complication only if it explains the work.
        • Follow-up after Daily: Name who I need to speak with and about what. Reserve team-wide blockers for the standup.

        Before writing, confirm that Daily offset \(offset) still corresponds to the specified dates. Read existing notes with sprint --ticket KEY notes show daily --offset \(offset). Preserve relevant manual notes and save the merged text with sprint --ticket KEY notes set daily --offset \(offset) --body "TEXT" for each ticket. Use the same notes commands without --ticket for verified contributions without a Jira story. Keep Slack, PRs, and chats read-only.
        """
        scenario.dailyActionStage = .draft
    }

    private func chooseDailyDestination() {
        scenario.dailyDestination = 0
        scenario.dailyDestinationConfirmed = false
        scenario.dailyActionStage = .destination
    }

    @FocusState private var dailyPromptFocused: Bool

    private func dailyActionMenu(_ stage: DailyActionStage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch stage {
            case .actions:
                Text("Daily Actions").font(.title2.bold())
                Button("Prepare your Daily Standup talking points", action: prepareDailyPrompt)
            case .draft:
                Text("Prepare your Daily Standup talking points").font(.title2.bold())
                TextEditor(text: $scenario.dailyPrompt)
                    .focused($dailyPromptFocused)
                    .onAppear { dailyPromptFocused = true }
                    .font(.system(size: 16))
                    .frame(height: 360)
                Text("Shift–Enter inserts a new line.").foregroundStyle(.secondary)
                Button("Send to…", action: chooseDailyDestination)
            case .destination:
                Text("Send to").font(.title2.bold())
                ForEach(Array(["ChatGPT", "Codex"].enumerated()), id: \.offset) { index, name in
                    Button {
                        scenario.dailyDestination = index
                        scenario.dailyDestinationConfirmed = true
                    } label: {
                        Text(name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(index == scenario.dailyDestination ? Color.blue.opacity(0.42) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                if scenario.dailyDestinationConfirmed {
                    Text("Sending is not available yet.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .frame(width: stage == .draft ? 700 : 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func dailyView() -> some View {
        let period = reportPeriod(weekly: false)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE, dd MMM HH:mm"
        let range = formatter.string(from: period.start) + " → " + formatter.string(from: period.end)
        return reportShell(.daily, subtitle: range) {
            HStack {
                Button("← Earlier standup") { scenario.switchTab(-1) }
                Button("Later standup →") { scenario.switchTab(1) }.disabled(scenario.dailyOffset == 0)
                Spacer()
                Button("↩ Daily Actions") { scenario.dailyActionStage = .actions }
                Text("⌃⇧Tab / ⌃Tab").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                dailyUnplannedList()
                    .frame(width: 245, alignment: .leading)
                taskActivity(weekly: false)
            }
        }
        .overlay {
            if let stage = scenario.dailyActionStage {
                Color.black.opacity(0.38).overlay { dailyActionMenu(stage) }
            }
        }
    }

    private var reportStories: [LocalTicket] {
        scenario.stories.map { story in
            scenario.ticket?.key == story.key ? scenario.ticket ?? story : story
        }
    }

    private func weeklyView() -> some View {
        let stories = reportStories
        let blocks = stories.flatMap { reportBlocks(for: $0, weekly: true) }
        let unplannedMinutes = blocks.filter { $0.unplanned == true }.reduce(0) { $0 + $1.minutes }
        let completionMinutes = stories.reduce(0) { sum, story in
            let logged = Set((story.workBlocks ?? []).map(\.taskId))
            return sum + reportCompletions(for: story, weekly: true)
                .filter { !logged.contains($0.id) }.reduce(0) { $0 + $1.minutes }
        }
        let period = reportPeriod(weekly: true)
        let corrections = stories.flatMap { $0.tasks ?? [] }.reduce(0) { sum, task in
            guard let raw = task.correctedAt, let date = ISO8601DateFormatter().date(from: raw),
                  date >= period.start && date < period.end && date <= period.now else { return sum }
            return sum + (task.spentCorrection ?? 0)
        }
        let ticketMinutes = blocks.filter { $0.unplanned != true }.reduce(completionMinutes + corrections) { $0 + $1.minutes }
        let importEffort = stories.filter { $0.sprint == nil && $0.stage != "done" }.reduce(0) { $0 + $1.effort }
        let reserve = scenario.ticket?.reserve ?? 480
        let reservedForLater = max(0, reserve - unplannedMinutes)
        let remaining = LocalTicket.available - ticketMinutes - unplannedMinutes - reservedForLater
        let balance = remaining - importEffort

        return reportShell(.planning, subtitle: "Sprint review & next sprint · Wednesday, 10:00") {
            taskActivity(weekly: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Weekly Budget").font(.system(size: 19, weight: .semibold))
                definition("🔒", "Workweek", clock(LocalTicket.workweek), "Fixed weekly budget.")
                definition("👥", "Fixed meetings", "−" + clock(LocalTicket.meetingMinutes), "Total recurring meeting time.", total: true)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(LocalTicket.meetings, id: \.0) { meeting in
                        definition("", meeting.0, clock(meeting.1), meeting.2)
                    }
                }
                .padding(.leading, 16)
                Divider()
                definition("⌛", "Available after meetings", clock(LocalTicket.available), "Workweek minus fixed meetings.", total: true)
                if let ticket = scenario.ticket {
                    planningInput("Unplanned reserve", value: clock(ticket.reserve), id: "", labelWidth: 155)
                    if scenario.invalidDuration && scenario.editingTask == "" {
                        Text("Enter HH:MM between 00:00 and " + clock(LocalTicket.available) + ".")
                            .foregroundStyle(.red)
                    }
                    if let error = scenario.ticketReadError {
                        Text(error).foregroundStyle(.orange)
                    }
                    definition("📅", "H/5D", clock(ticket.capacity), "Available after meetings minus the planned reserve.", total: true)
                }
                Divider()
                definition("⏱️", "Ticket work", "−" + clock(ticketMinutes), "Logged ticket work this sprint.")
                definition("🧯", "Unplanned work", "−" + clock(unplannedMinutes), "Logged this sprint, including extra meetings such as quarterly planning.")
                Divider()
                definition("🛟", "Unused reserve", "−" + clock(reservedForLater), "Planned reserve still held for unplanned work.")
                definition("⌛", "Remaining budget", clock(remaining), "After logged work and unused reserve.", total: true)
                definition("🛠️", "Effort required", "−" + clock(importEffort), "Estimated time for included open work.")
                Divider()
                definition(balance < 0 ? "🔴" : "🟢", balance < 0 ? "Overrun" : "Buffer",
                           clock(balance), balance < 0 ? "Estimated time shortfall." : "Time left after planned work.",
                           total: true, color: balance < 0 ? .red : .green)
            }
        }
    }

    private func timestamp(_ raw: String?) -> String {
        guard let raw, let date = ISO8601DateFormatter().date(from: raw) else { return "" }
        let display = DateFormatter()
        display.timeZone = TimeZone(identifier: "Europe/Berlin")
        display.locale = Locale(identifier: "en_GB")
        display.dateFormat = "dd MMM HH:mm"
        return display.string(from: date)
    }

    private func timingColumns(_ task: TicketTask? = nil, showDuration: Bool = true) -> some View {
        HStack(spacing: 8) {
            Text(task.map { timestamp($0.startedAt) } ?? "Started")
                .frame(width: 108, alignment: .trailing)
            Text(task.map { timestamp($0.completedAt) } ?? "Finished")
                .frame(width: 108, alignment: .trailing)
            if showDuration {
                Text(task.map { clock(scenario.ticket?.minutesSpent(on: $0) ?? 0) } ?? "Spent")
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .font(.system(size: 15, weight: task == nil ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private struct ReportTask: Identifiable {
        let task: TicketTask
        let spent: Int
        let notes: [WorkBlock]
        var id: String { task.id }
    }

    private func reportRows(for story: LocalTicket, weekly: Bool) -> [ReportTask] {
        let period = reportPeriod(weekly: weekly)
        let completed = Set(reportCompletions(for: story, weekly: weekly).map(\.id))
        let blocks = Dictionary(grouping: reportBlocks(for: story, weekly: weekly), by: \.taskId)
        let logged = Set((story.workBlocks ?? []).map(\.taskId))
        return (story.tasks ?? []).compactMap { task in
            let entries = blocks[task.id] ?? []
            let startedHere = task.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }.map {
                $0 >= period.start && $0 < period.end && $0 <= period.now
            } ?? false
            let correctionHere = task.correctedAt.flatMap { ISO8601DateFormatter().date(from: $0) }.map {
                $0 >= period.start && $0 < period.end && $0 <= period.now
            } ?? false
            guard !entries.isEmpty || completed.contains(task.id) || startedHere || correctionHere else { return nil }
            let fallback = completed.contains(task.id) && !logged.contains(task.id) ? task.minutes : 0
            let spent = entries.reduce(fallback) { $0 + $1.minutes } + (correctionHere ? task.spentCorrection ?? 0 : 0)
            let notes = entries.filter { !$0.note.isEmpty && $0.note != "Active work session" && $0.note != "Timed work session" }
            return ReportTask(task: task, spent: spent, notes: notes)
        }
    }

    private func reportGroups(weekly: Bool) -> [(story: LocalTicket, rows: [ReportTask])] {
        let period = reportPeriod(weekly: weekly)
        let scope = ReportNotes.scope(weekly: weekly, end: period.end)
        return reportStories.map { (story: $0, rows: reportRows(for: $0, weekly: weekly)) }
            .filter { !$0.rows.isEmpty || ($0.story.sprint == nil && $0.story.stage != "done") || !scenario.speakingNotes[scope + ":story:" + $0.story.key, default: ""].isEmpty }
            .sorted {
                let order = ["done": 0, "in-progress": 1, "planned": 2]
                let left = order[$0.story.stage, default: 3]
                let right = order[$1.story.stage, default: 3]
                return left == right ? $0.story.key < $1.story.key : left < right
            }
    }

    private func taskActivity(weekly: Bool) -> some View {
        let scope = ReportNotes.scope(weekly: weekly, end: reportPeriod(weekly: weekly).end)
        let groups = reportGroups(weekly: weekly)
        let totalSpent = groups.flatMap(\.rows).reduce(0) { $0 + $1.spent }
        return VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: reportColumnSpacing) {
                reportTableRow(title: "Total spent", status: "", spent: clock(totalSpent), heading: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Self.reportSectionInset)
            if let error = scenario.notesError { Text(error).foregroundStyle(.orange) }
            if groups.isEmpty {
                Text("—").foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.story.key) { group in
                let done = group.story.stage == "done"
                let active = group.story.stage == "in-progress"
                let tint: Color = done ? .green : active ? .cyan : .secondary
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(group.story.key).monospaced().fontWeight(.semibold).foregroundStyle(tint)
                        Text(group.story.title).fontWeight(.semibold)
                        Spacer()
                        Text(done ? "Done" : active ? "In Progress" : "Planned")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .padding(10)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    HStack(alignment: .top, spacing: reportColumnSpacing) {
                        VStack(alignment: .leading, spacing: 8) {
                            if group.rows.isEmpty {
                                Text("—").foregroundStyle(.secondary)
                            } else {
                                reportTableRow(title: "Task / Progress", status: "Status", spent: "Spent", heading: true)
                                Divider()
                                ForEach(group.rows) { row in
                                    let id = ReportRowID.jira(story: group.story.key, task: row.id)
                                    reportTableRow(title: row.task.title, status: row.task.status,
                                                   spent: clock(row.spent), notes: row.notes)
                                        .background {
                                            if scenario.selectedReportRow == id {
                                                RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.32))
                                            }
                                        }
                                        .id(id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        speakingNotes("Speaking notes", key: scope + ":story:" + group.story.key)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .modifier(ReportSection(tint: tint))
            }
            speakingNotes("Other speaking notes", key: scope + ":general")
                .modifier(ReportSection(tint: .gray))
        }
        .font(.system(size: 17))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private let reportColumnSpacing: CGFloat = 22
    private static let reportSectionInset: CGFloat = 16

    private struct ReportSection: ViewModifier {
        let tint: Color

        func body(content: Content) -> some View {
            content
                .padding(BudgetView.reportSectionInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(tint.opacity(0.65), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }

    private func speakingNotes(_ title: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { scenario.speakingNotes[key, default: ""] },
                set: { scenario.setNote($0, key: key) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 60, alignment: .topLeading)
            .padding(10)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(title)
            .id(key)
        }
    }

    private func reportTableRow(title: String, status: String, spent: String,
                                notes: [WorkBlock] = [], heading: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                ForEach(notes, id: \.id) { block in
                    Text((block.unplanned == true ? "Unplanned · " : "") + block.note)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status).frame(width: 88, alignment: .leading)
                .foregroundStyle(status == "Finished" ? Color.green : status == "In Progress" ? Color.cyan : Color.secondary)
            Text(spent).frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 15, weight: heading ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(heading ? Color.secondary : Color.primary)
    }

    private func unplannedView() -> some View {
        reportShell(.unplanned, subtitle: "↑ ↓  Select    ← →  Switch view") {
            if let error = scenario.unplannedError { Text(error).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Button("New item") {
                        scenario.unplannedDraft = UnplannedItem(id: 0, date: .now, title: "",
                                                                description: "", status: .open)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    unplannedRow("ID", "Title", "Date", "Status").fontWeight(.semibold)
                    Divider()
                    ForEach(scenario.unplannedItems) { item in
                        Button { scenario.selectedUnplanned = item.id } label: {
                            unplannedRow("U-\(item.id)", item.title, item.date.formatted(date: .abbreviated, time: .omitted),
                                         item.status.rawValue)
                                .padding(.vertical, 5)
                                .background {
                                    if scenario.selectedUnplanned == item.id {
                                        RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.32))
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                    if scenario.unplannedItems.isEmpty { Text("—").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                if let item = scenario.unplannedItems.first(where: { $0.id == scenario.selectedUnplanned }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(.title2.bold())
                        Text(item.description.isEmpty ? "—" : item.description).textSelection(.enabled)
                        Button("Edit item") { scenario.unplannedDraft = item }
                            .keyboardShortcut("e", modifiers: .command)
                    }
                    .frame(width: 310, alignment: .leading)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { scenario.unplannedDraft != nil },
            set: { if !$0 { scenario.unplannedDraft = nil } }
        )) {
            if let draft = Binding($scenario.unplannedDraft) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(draft.wrappedValue.id == 0 ? "New unplanned item" : "Edit unplanned item").font(.title2.bold())
                    TextField("Title", text: draft.title)
                    DatePicker("Date", selection: draft.date, displayedComponents: .date)
                    Picker("Status", selection: draft.status) {
                        ForEach(UnplannedItem.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Description", text: draft.description, axis: .vertical).lineLimit(4...10)
                    if let error = scenario.unplannedError { Text(error).foregroundStyle(.orange) }
                    HStack {
                        Button("Cancel") { scenario.unplannedDraft = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Save", action: scenario.saveUnplanned).keyboardShortcut(.defaultAction)
                            .disabled(draft.wrappedValue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(24)
                .frame(width: 440)
            }
        }
    }

    private func unplannedRow(_ id: String, _ title: String, _ date: String, _ status: String) -> some View {
        HStack(spacing: 10) {
            Text(id).monospacedDigit().frame(width: 58, alignment: .leading)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(date).frame(width: 100, alignment: .leading)
            Text(status).frame(width: 95, alignment: .leading)
        }
        .font(.system(size: 15))
    }

    private let viewTitleFont = Font.system(size: 33, weight: .bold)

    private func reportShell<Content: View>(_ mode: BudgetMode, subtitle: String,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.title).font(viewTitleFont)
                Text(subtitle).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { content() }
                        .frame(maxWidth: 1050, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: scenario.selectedReportRow) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: scenario.selectedUnplanned) { _, id in
                    if mode == .unplanned, let id { proxy.scrollTo(id) }
                }
            }
            Spacer(minLength: 0)
            Text(mode == .settings ? "⌘,  Settings    ← →  Switch view    Esc  Close" : "⌥" + mode.key.letter + "  Toggle    ⌘,  Settings    Esc  Close").font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.085, green: 0.10, blue: 0.13))
        .preferredColorScheme(.dark)
    }

    private func budgetTimeline(planned: Int, remaining: Int, effort: Int, openTasks: [TicketTask], completed: [TicketTask], showForecast: Bool) -> some View {
        let invested = planned - remaining
        let forecast = invested + effort
        let difference = abs(effort - remaining)
        let overBudget = effort > remaining
        let deltaColor: Color = overBudget ? .red : .green
        return GeometryReader { geometry in
            let scale = max(0, geometry.size.width - 24) / Double(max(1, planned, forecast))
            let start: CGFloat = 12
            let now = start + scale * Double(invested)
            let budgetEnd = start + scale * Double(planned)
            let effortEnd = start + scale * Double(forecast)
            let deltaStart = min(budgetEnd, effortEnd)
            let deltaEnd = max(budgetEnd, effortEnd)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.secondary)
                    .frame(width: 1, height: 39)
                    .offset(x: now, y: 119)
                Rectangle().fill(.secondary)
                    .frame(width: 1, height: 56)
                    .offset(x: budgetEnd, y: 102)

                Rectangle().fill(.gray)
                    .frame(width: now - start, height: 16)
                    .offset(x: start, y: 142)
                if let index = completed.firstIndex(where: { $0.id == scenario.selectedTask }) {
                    Rectangle().fill(.blue)
                        .frame(width: scale * Double(completed[index].minutes), height: 16)
                        .offset(x: start + scale * Double(completed.prefix(index).reduce(0) { $0 + $1.minutes }), y: 142)
                }
                if remaining < 0 {
                    Rectangle().fill(.red)
                        .frame(width: now - budgetEnd, height: 16)
                        .offset(x: budgetEnd, y: 142)
                        .allowsHitTesting(false)
                }
                if !overBudget {
                    Rectangle().fill(deltaColor)
                        .frame(width: deltaEnd - deltaStart, height: 16)
                        .offset(x: deltaStart, y: 142)
                }
                HStack(spacing: 0) {
                    ForEach(Array(openTasks.enumerated()), id: \.offset) { index, task in
                        Button {
                            scenario.selectedBudget = nil
                            scenario.selectedCriterion = nil
                            scenario.selectedTask = scenario.selectedTask == task.id ? nil : task.id
                        } label: {
                            Rectangle()
                                .fill(scenario.selectedTask == task.id ? Color.blue :
                                    Color.white.opacity(0.84))
                                .overlay(alignment: .leading) {
                                    if index > 0 {
                                        Rectangle().fill(Color(white: 0.19)).frame(width: 2)
                                    }
                                }
                                .frame(width: scale * Double(task.minutes), height: 16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.title)
                    }
                }
                .overlay(alignment: .trailing) {
                    if overBudget {
                        Rectangle().fill(.red.opacity(0.65))
                            .frame(width: min(deltaEnd - deltaStart, scale * Double(effort)))
                            .allowsHitTesting(false)
                    }
                }
                .fixedSize()
                .offset(x: now, y: 142)
                Rectangle().fill(.primary)
                    .frame(width: 1, height: 27)
                    .offset(x: effortEnd, y: 137)

                Text("🏃").font(.system(size: 20)).scaleEffect(x: -1, y: 1)
                    .position(x: now, y: 111)
                    .accessibilityLabel("Now")
                    .help("Now")
                Text("⏰").font(.system(size: 20))
                    .position(x: budgetEnd, y: 123)
                    .accessibilityLabel("Budget limit")
                    .help("Budget limit")
                if showForecast {
                Text("🏁").font(.system(size: 20))
                    .position(x: effortEnd, y: 171)
                    .accessibilityLabel("Estimated finish")
                    .help("Estimated finish")
                }
                let middle = geometry.size.width / 2
                intervalLabel("📅 Planned", planned, from: start, to: budgetEnd, row: 42,
                              labelX: (start + budgetEnd) / 2, labelWidth: middle, above: true)
                if remaining >= 0 {
                    intervalLabel(showForecast ? "⌛ Remaining budget" : "✅ Unused Budget",
                                  remaining, from: min(now, budgetEnd), to: max(now, budgetEnd),
                                  row: 94, labelX: (now + budgetEnd) / 2, labelWidth: middle,
                                  color: showForecast ? .secondary : .green, above: true)
                }
                intervalLabel("✅ Spent", invested, from: start, to: now, row: 190,
                              labelX: (start + now) / 2, labelWidth: middle)
                if showForecast {
                    intervalLabel("🛠️ Remaining effort", effort, from: now, to: effortEnd, row: 242,
                                  labelX: (now + effortEnd) / 2, labelWidth: middle)
                }
                if showForecast || remaining < 0 {
                    intervalLabel(overBudget ? "❗ Overrun" : "😌 Buffer", difference,
                                  from: deltaStart, to: deltaEnd, row: 294,
                                  labelX: (deltaStart + deltaEnd) / 2, labelWidth: middle, color: deltaColor)
                }
            }
        }
        .frame(height: 342)
    }

    @ViewBuilder
    private func intervalLabel(_ title: String, _ minutes: Int, from start: CGFloat, to end: CGFloat,
                               row: CGFloat, labelX: CGFloat, labelWidth: CGFloat,
                               color: Color = .secondary, above: Bool = false) -> some View {
        let metric = String(title.split(separator: " ", maxSplits: 1).last ?? "")
        let selected = scenario.selectedBudget == metric
        let color = selected ? Color.cyan : color
        if minutes != 0 || selected {
            if selected {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.cyan, lineWidth: 2)
                    .frame(width: max(3, end - start), height: 20)
                    .offset(x: start, y: 140)
                    .allowsHitTesting(false)
            }
            Rectangle().fill(color)
                .frame(width: max(0, end - start), height: selected ? 3 : 1)
                .offset(x: start, y: row)
            Rectangle().fill(color).frame(width: 1, height: 7).offset(x: start, y: row - 3)
            Rectangle().fill(color).frame(width: 1, height: 7).offset(x: end, y: row - 3)
            let halfLabel = min(labelWidth / 2, 86)
            let plotWidth = labelWidth * 2
            VStack(spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(clock(minutes))
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: max(0, halfLabel * 2))
            .position(x: min(max(labelX, halfLabel), plotWidth - halfLabel), y: row + (above ? -23 : 25))
        }
    }

    private func budgetDefinition(_ icon: String, _ term: String, _ value: String, _ meaning: String,
                                  total: Bool = false, color: Color = .primary) -> some View {
        definition(icon, term, value, meaning, total: total, color: color)
            .background {
                if scenario.selectedBudget == term {
                    RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.32))
                }
            }
            .id(term)
    }

    private func definition(_ icon: String, _ term: String, _ value: String, _ meaning: String,
                            total: Bool = false, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(icon).frame(width: 20).accessibilityHidden(true)
            Text(term).bold().frame(width: 125, alignment: .leading)
            Text(value).monospacedDigit().fontWeight(total ? .bold : .regular)
                .foregroundStyle(color).frame(width: 72, alignment: .trailing)
            Text(meaning)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 15))
        .padding(.vertical, 2)
    }

    func toggleSelectedDetails() -> Bool {
        guard scenario.mode == .ticket else { return false }
        if let index = scenario.selectedCriterion, let ticket = scenario.ticket,
           ticket.acceptanceCriteria.indices.contains(index) {
            let ids = Set(anchoredComments(ticket.acceptanceCriteria[index], index: index,
                                           comments: ticket.criterionComments ?? []).map(\.id))
            if ids.isSubset(of: scenario.expandedComments) {
                scenario.expandedComments.subtract(ids)
            } else {
                scenario.expandedComments.formUnion(ids)
            }
            return true
        }
        guard scenario.storyFocus != .progress, let id = scenario.selectedTask, currentTasks.contains(where: { $0.id == id }) else {
            return false
        }
        scenario.taskDetailsID = scenario.taskDetailsID == id ? nil : id
        return true
    }

    private func nextSelection<ID: Equatable>(_ ids: [ID], selected: ID?, step: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return step > 0 ? ids.first : ids.last
        }
        return ids[(index + step + ids.count) % ids.count]
    }

    func moveSelection(by step: Int) {
        if scenario.mode == .unplanned {
            scenario.selectedUnplanned = nextSelection(scenario.unplannedItems.map(\.id),
                                                       selected: scenario.selectedUnplanned, step: step)
            return
        }
        if scenario.mode == .daily || scenario.mode == .planning {
            let jiraIDs = reportGroups(weekly: scenario.mode == .planning).flatMap { group in
                group.rows.map { ReportRowID.jira(story: group.story.key, task: $0.id) }
            }
            let unplannedIDs = scenario.mode == .daily ? dailyUnplannedItems().map { ReportRowID.unplanned($0.id) } : []
            scenario.selectedReportRow = nextSelection(unplannedIDs + jiraIDs, selected: scenario.selectedReportRow, step: step)
            return
        }
        guard scenario.mode == .ticket else { return }
        let focus = scenario.storyFocus
        let tasks = focus == nil || focus == .progress ? currentTasks : []
        let criteriaCount = focus == nil || focus == .criteria ? scenario.ticket?.acceptanceCriteria.count ?? 0 : 0
        let budget: [String]
        if (focus == nil || focus == .budget), let ticket = scenario.ticket {
            budget = ticket.stage == "done"
                ? ["Planned", "Spent", ticket.remaining < 0 ? "Overrun" : "Unused Budget"]
                : ["Planned", "Spent", "Remaining budget", "Remaining effort",
                   ticket.remaining < ticket.effort ? "Overrun" : "Buffer"]
        } else {
            budget = []
        }
        let count = budget.count + criteriaCount + tasks.count
        guard count > 0 else { return }
        let current = budget.firstIndex { $0 == scenario.selectedBudget }
            ?? scenario.selectedCriterion.flatMap { (0..<criteriaCount).contains($0) ? $0 + budget.count : nil }
            ?? tasks.firstIndex { $0.id == scenario.selectedTask }.map { $0 + budget.count + criteriaCount }
        let next = current.map { ($0 + step + count) % count }
            ?? (step > 0 ? 0 : count - 1)
        scenario.taskDetailsID = nil
        let detailIndex = next - budget.count
        scenario.selectedBudget = detailIndex < 0 ? budget[next] : nil
        scenario.selectedCriterion = (0..<criteriaCount).contains(detailIndex) ? detailIndex : nil
        scenario.selectedTask = detailIndex < criteriaCount ? nil : tasks[detailIndex - criteriaCount].id
    }

    private struct StoryForecast {
        let eligible: Bool
        let available: Int
        let effort: Int
        let reservedForOtherStories: Int
        var margin: Int { available - effort }
    }

    private func storyForecast(_ story: LocalTicket) -> StoryForecast {
        guard story.stage != "done", story.sprint == nil else {
            return StoryForecast(eligible: false, available: 0, effort: 0, reservedForOtherStories: 0)
        }
        let period = reportPeriod(weekly: true)
        func inPeriod(_ date: Date?) -> Bool {
            guard let date else { return false }
            return date >= period.start && date < period.end && date <= period.now
        }
        let stories = scenario.stories.map { $0.key == scenario.ticket?.key ? scenario.ticket ?? $0 : $0 }
        var booked = 0
        var unplanned = 0
        for item in stories {
            let saved = item.workBlocks ?? []
            let blocks = saved + (item.liveBlock(at: period.now).map { [$0] } ?? [])
            for block in blocks where inPeriod(block.date) {
                if block.unplanned == true { unplanned += block.minutes }
                else { booked += block.minutes }
            }
            let logged = Set(blocks.map(\.taskId))
            for task in item.completed where !logged.contains(task.id) {
                if inPeriod(task.completedAt.flatMap({ ISO8601DateFormatter().date(from: $0) })) {
                    booked += task.minutes
                }
            }
            for task in item.tasks ?? [] {
                if inPeriod(task.correctedAt.flatMap({ ISO8601DateFormatter().date(from: $0) })) {
                    booked += task.spentCorrection ?? 0
                }
            }
        }
        let active = stories.filter { $0.key != story.key && $0.sprint == nil && $0.stage == "in-progress" }
        let reserved = active.reduce(0) { $0 + $1.effort }
        let reserve = TicketStore.preferred(stories.map { (url: TicketStore.root, ticket: $0) })?.ticket.reserve ?? story.reserve
        return StoryForecast(eligible: true,
                             available: LocalTicket.available - booked - max(unplanned, reserve) - reserved,
                             effort: story.effort, reservedForOtherStories: reserved)
    }

    private func storyTabLabel(_ story: LocalTicket) -> some View {
        let forecast = storyForecast(story)
        return VStack(alignment: .leading, spacing: 3) {
            Text(story.key).font(.system(size: 12, weight: .semibold))
            Text(story.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(story.stage == "done" ? "✅ Done" : story.stage == "in-progress" ? "▶ In Progress" : "📅 Planned")
                .font(.system(size: 13))
            if story.stage == "done" {
                let exceeded = story.spent > story.planned
                Text(exceeded ? "Overrun · " + clock(story.spent - story.planned) : "Within Budget")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(exceeded ? Color.red : Color.green)
            } else if forecast.eligible {
                Text(forecast.margin < 0 ? "⚠ At Risk" : "On Track")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(forecast.margin < 0 ? Color.red : Color.green)
            }
        }
        .frame(minHeight: 77, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func storyLabel(_ story: LocalTicket, forecast: StoryForecast) -> String {
        if story.stage == "done" { return "✅ Done" }
        let stage = story.stage == "in-progress" ? "▶ In Progress" : "📅 Planned"
        guard forecast.eligible else { return stage }
        return stage + (forecast.margin < 0 ? " · ⚠ At Risk" : " · On Track")
    }

    private var currentTasks: [TicketTask] { scenario.ticket?.tasks ?? [] }

    private func updateTicket(_ update: (inout LocalTicket) throws -> Void) -> Bool {
        do {
            TicketStore.selectedFile = scenario.ticketURL
            defer { TicketStore.selectedFile = nil }
            scenario.ticket = try TicketStore.change { stored in
                guard var current = stored, current.key == scenario.ticket?.key else {
                    throw TicketStore.failure("The active ticket changed. Reopen Ticket Decision.")
                }
                try update(&current)
                stored = current
            }
            scenario.ticketReadError = nil
            return true
        } catch {
            scenario.ticketReadError = error.localizedDescription
            return false
        }
    }

    private func planningInput(_ label: String, value: String, id: String, labelWidth: CGFloat = 64) -> some View {
        HStack {
            Text(label).frame(width: labelWidth, alignment: .leading)
            if scenario.editingTask == id {
                InlineDurationField(text: $scenario.draft, onSubmit: { saveDuration(nil) })
                    .frame(width: 90, height: 24)
                    .accessibilityLabel(label)
            } else {
                Button(value) {
                    scenario.draft = value
                    scenario.invalidDuration = false
                    scenario.editingTask = id
                }
                .accessibilityLabel("Edit " + label)
            }
        }
    }

    private func saveDuration(_ task: TicketTask?) {
        if task == nil && scenario.editingTask == " " {
            guard let target = Int(scenario.draft.trimmingCharacters(in: .whitespaces)),
                  (1...10000).contains(target) else {
                scenario.invalidDuration = true
                return
            }
            if updateTicket({ $0.sprintPointTarget = target }) { cancelEdit() }
            return
        }
        let parts = scenario.draft.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...9999).contains(hours), parts[1].count == 2, (0...59).contains(minutes) else {
            scenario.invalidDuration = true
            return
        }
        let value = hours * 60 + minutes
        if task == nil && value > LocalTicket.available {
            scenario.invalidDuration = true
            return
        }
        if updateTicket({ ticket in
            if let task {
                guard let index = ticket.tasks?.firstIndex(where: { $0.id == task.id }) else {
                    throw TicketStore.failure("Task no longer exists.")
                }
                ticket.tasks?[index].minutes = value
            } else {
                ticket.unplannedReserveMinutes = value
            }
        }) { cancelEdit() }
    }

    func cancelEdit() {
        scenario.editingTask = nil
        scenario.invalidDuration = false
    }

    private func toggleTimer(_ task: TicketTask) {
        _ = updateTicket { ticket in
            try ticket.setTimer(task.id, running: task.runningSince == nil)
        }
    }

    private func statusColumn(_ task: TicketTask? = nil) -> some View {
        let status = task?.status ?? "Status"
        return Group {
            if let task, status == "Backlog" || status == "Planned" {
                Menu(status) {
                    Button("Backlog") { setPlanned(task, false) }
                    Button("Planned") { setPlanned(task, true) }
                }
            } else {
                Text(status)
                    .foregroundStyle(status == "Finished" ? Color.green : status == "In Progress" ? Color.cyan : Color.secondary)
            }
        }
        .font(.system(size: 15, weight: task == nil ? .semibold : .regular))
        .frame(width: 105, alignment: .leading)
    }

    private func setPlanned(_ task: TicketTask, _ planned: Bool) {
        _ = updateTicket { ticket in
            guard let index = ticket.tasks?.firstIndex(where: { $0.id == task.id }),
                  let current = ticket.tasks?[index], !current.done, current.startedAt == nil,
                  current.runningSince == nil else {
                throw TicketStore.failure("Only tasks that have not started can change planning status.")
            }
            ticket.tasks?[index].included = planned
        }
    }

    private func taskInput(_ task: TicketTask, field: String, value: String, width: CGFloat) -> some View {
        let key = task.id + ":" + field
        return VStack(spacing: 2) {
            if scenario.editingTask == key {
                InlineDurationField(text: $scenario.draft, onSubmit: { saveTaskInput(task, field: field) })
                    .frame(height: 22)
                if scenario.invalidDuration {
                    Text(field == "Started" || field == "Finished" ? "Use ISO 8601" : "Use HH:MM")
                        .font(.system(size: 12)).foregroundStyle(.red)
                }
            } else {
                Button(value.isEmpty ? "—" : value) {
                    scenario.selectedBudget = nil
                    scenario.selectedCriterion = nil
                    scenario.selectedTask = task.id
                    scenario.draft = field == "Started" ? task.startedAt ?? "" :
                        field == "Finished" ? task.completedAt ?? "" : value
                    scenario.invalidDuration = false
                    scenario.editingTask = key
                }
                .monospacedDigit()
                .help(field == "Started" || field == "Finished" ? "Edit " + field + " (ISO 8601 with offset)" : "Edit " + field)
            }
        }
        .frame(width: width)
        .accessibilityLabel("\(field) for \(task.title)")
    }

    private func saveTaskInput(_ task: TicketTask, field: String) {
        if field == "Estimate" {
            saveDuration(task)
            return
        }
        let raw = scenario.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if field == "Spent" {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
                  (0...9999).contains(hours), parts[1].count == 2, (0...59).contains(minutes) else {
                scenario.invalidDuration = true
                return
            }
            if updateTicket({ ticket in
                guard let index = ticket.tasks?.firstIndex(where: { $0.id == task.id }) else {
                    throw TicketStore.failure("Task no longer exists.")
                }
                try ticket.setSpent(hours * 60 + minutes, at: index)
            }) { cancelEdit() }
            return
        }
        guard ISO8601DateFormatter().date(from: raw) != nil else {
            scenario.invalidDuration = true
            return
        }
        if updateTicket({ ticket in
            guard let index = ticket.tasks?.firstIndex(where: { $0.id == task.id }),
                  var current = ticket.tasks?[index] else {
                throw TicketStore.failure("Task no longer exists.")
            }
            if field == "Started" {
                current.startedAt = raw
            } else {
                if current.runningSince != nil { ticket.pause(at: Date()) }
                current.runningSince = nil
                current.done = true
                current.completedAt = raw
            }
            ticket.tasks?[index] = current
        }) { cancelEdit() }
    }

    private func item(_ task: TicketTask) -> some View {
        let excluded = !task.included
        return HStack {
            taskInput(task, field: "Estimate", value: clock(task.minutes), width: 70)
            let spent = scenario.ticket?.minutesSpent(on: task) ?? 0
            taskInput(task, field: "Spent", value: clock(spent), width: 70)
                .foregroundStyle(spent > task.minutes ? Color.orange : Color.primary)
                .help(spent > task.minutes ? "Above estimate by " + clock(spent - task.minutes) : "Time spent")
            Button {
                scenario.selectedBudget = nil
                scenario.selectedCriterion = nil
                scenario.selectedTask = task.id
                scenario.taskDetailsID = scenario.storyFocus == .progress ? nil : task.id
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(task.title, systemImage: task.done ? "checkmark.circle.fill" : excluded ? "minus.circle" : "circle")
                            .foregroundStyle(task.done ? Color.green : excluded ? Color.secondary : Color.primary)

                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show task details")
            .popover(isPresented: Binding(
                get: { scenario.taskDetailsID == task.id },
                set: { if !$0 && scenario.taskDetailsID == task.id { scenario.taskDetailsID = nil } }
            )) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.title)
                        .font(.title2.bold())
                    ScrollView {
                        let description = task.description ?? ""
                        Text(description.isEmpty ? "No description yet." : description)
                            .foregroundStyle(description.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                }
                .padding(20)
                .frame(width: 460, alignment: .leading)
            }
            statusColumn(task)
            taskInput(task, field: "Started", value: timestamp(task.startedAt), width: 108)
            taskInput(task, field: "Finished", value: timestamp(task.completedAt), width: 108)
            if !task.done {
                Button {
                    toggleTimer(task)
                } label: {
                    Image(systemName: task.runningSince != nil ? "pause.fill" : "play.fill")
                }
                .help(task.runningSince != nil ? "Pause" : task.startedAt != nil ? "Resume" : "Start")
                .accessibilityLabel(task.runningSince != nil ? "Pause" : task.startedAt != nil ? "Resume" : "Start")
                .frame(width: 74)
            } else {
                Color.clear.frame(width: 74, height: 1)
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 6)
        .background {
            if scenario.selectedTask == task.id {
                RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.32))
            }
        }
    }

    private func clock(_ minutes: Int) -> String {
        (minutes < 0 ? "−" : "") + String(format: "%02d:%02d", abs(minutes) / 60, abs(minutes) % 60)
    }
}

private struct InlineDurationField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.editor = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(editor: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var editor: InlineDurationField

        init(editor: InlineDurationField) { self.editor = editor }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                editor.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            editor.text = textView.string
            editor.onSubmit()
            return true
        }
    }
}

final class BudgetWindow: NSWindow {
    var isEditing: (() -> Bool)?
    var cancelEdit: (() -> Void)?
    var moveSelection: ((Int) -> Void)?
    var switchTab: ((Int) -> Void)?
    var switchMode: ((Int) -> Void)?
    var dailyActionKey: ((Int, Bool) -> Bool)?
    var storyActionKey: ((Int) -> Bool)?
    var openSettings: (() -> Void)?
    var storyFocusKey: ((Int) -> Bool)?
    var toggleTaskDetails: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, modifiers == .command {
            if Int(event.keyCode) == kVK_ANSI_Q {
                NSApp.terminate(nil)
                return
            }
            if Int(event.keyCode) == kVK_ANSI_W {
                orderOut(nil)
                return
            }
        }
        if event.type == .keyDown, modifiers == .command, Int(event.keyCode) == kVK_ANSI_Comma {
            openSettings?()
            return
        }
        if event.type == .keyDown, !modifiers.contains(.command), Int(event.keyCode) == kVK_Tab,
           modifiers == .control || modifiers == [.control, .shift] {
            switchTab?(modifiers.contains(.shift) ? -1 : 1)
            return
        }
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if isEditing?() == true {
                if Int(event.keyCode) == kVK_Escape {
                    cancelEdit?()
                    return
                }
                super.sendEvent(event)
                return
            }
            if dailyActionKey?(Int(event.keyCode), firstResponder is NSTextView) == true { return }
            if !(firstResponder is NSTextView), storyActionKey?(Int(event.keyCode)) == true { return }
            if !(firstResponder is NSTextView), storyFocusKey?(Int(event.keyCode)) == true { return }
            switch Int(event.keyCode) {
            case kVK_Space:
                if !(firstResponder is NSTextView), !event.isARepeat, toggleTaskDetails?() == true { return }
            case kVK_LeftArrow, kVK_RightArrow:
                if !(firstResponder is NSTextView) {
                    switchMode?(Int(event.keyCode) == kVK_LeftArrow ? -1 : 1)
                    return
                }
            case kVK_UpArrow:
                if !(firstResponder is NSTextView) { moveSelection?(-1); return }
            case kVK_DownArrow:
                if !(firstResponder is NSTextView) { moveSelection?(1); return }
            default: break
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private enum WorkdayReminder {
    static func windows(_ text: String) -> [(Int, Int)]? {
        func minute(_ raw: Substring) -> Int? {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...24).contains(hour), (0..<60).contains(minute), hour < 24 || minute == 0 else { return nil }
            return hour * 60 + minute
        }
        var windows: [(Int, Int)] = []
        for window in text.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = window.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let start = minute(parts[0]), let end = minute(parts[1]),
                  start >= (windows.last?.1 ?? 0), end > start else { return nil }
            windows.append((start, end))
        }
        return windows.isEmpty ? nil : windows
    }

    static func percentages(_ text: String) -> [Int]? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let percentages = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard percentages.count == parts.count, percentages.allSatisfy({ (1...100).contains($0) }) else { return nil }
        return Set(percentages).sorted(by: >)
    }
}

final class BudgetNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let stateKey = "notifiedBudgetOverruns"
    private var timer: Timer?
    private var pending = Set<String>()

    func start() {
        center.delegate = self
        requestPermission { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func test() {
        requestPermission { [weak self] in
            self?.post(title: "Sprint: Budget warning test",
                       body: "Example story needs 2h more. Check with your team whether scope or budget should change.") { _ in }
        }
    }

    private func requestPermission(_ granted: @escaping () -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
            if let error { NSLog("Sprint notification permission: %@", error.localizedDescription) }
            if allowed { DispatchQueue.main.async(execute: granted) }
        }
    }

    private func check() {
        let tickets = TicketStore.registry().map(\.ticket)
        let open = tickets.filter { $0.stage != "done" && $0.sprint == nil && $0.storyPoints != nil }
        let overruns = open.filter { $0.effort > $0.remaining }
        let restored = Set(open.filter { $0.effort <= $0.remaining }.map(\.key))
        let closed = Set(tickets.filter { $0.stage == "done" || $0.sprint != nil }.map(\.key))
        let acknowledged = Set(SprintPreferences.store.stringArray(forKey: stateKey) ?? [])
        let current = acknowledged.subtracting(restored.union(closed))
        if current != acknowledged { SprintPreferences.store.set(current.sorted(), forKey: stateKey) }
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async { [weak self] in
                self?.notify(overruns)
                self?.notifyElapsedBudget(open)
                self?.notifySprintDeadline()
            }
        }
    }

    private func elapsedWorkMinutes(from start: Date, to end: Date) -> Int {
        guard start < end,
              let windows = WorkdayReminder.windows(SprintPreferences.store.string(forKey: "workdayHours") ?? "09:00-12:00,12:45-17:45") else { return 0 }
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: start)
        var seconds: TimeInterval = 0
        while day < end {
            if !calendar.isDateInWeekend(day) {
                for (opening, closing) in windows {
                    guard let from = calendar.date(bySettingHour: opening / 60, minute: opening % 60, second: 0, of: day),
                          let to = closing == 1440 ? calendar.date(byAdding: .day, value: 1, to: day) : calendar.date(bySettingHour: closing / 60, minute: closing % 60, second: 0, of: day) else { continue }
                    seconds += max(0, min(end, to).timeIntervalSince(max(start, from)))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Int(seconds / 60)
    }

    private func notifyElapsedBudget(_ tickets: [LocalTicket]) {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        guard let percentages = WorkdayReminder.percentages(
            SprintPreferences.store.string(forKey: "ticketReminderPercentages") ?? "50,80"
        ) else { return }
        let key = "notifiedElapsedTicketBudget"
        for ticket in tickets where ticket.stage == "in-progress" && ticket.planned > 0 {
            let firstTaskStart = (ticket.tasks ?? []).compactMap {
                $0.startedAt.flatMap { formatter.date(from: $0) }
            }.min()
            guard let start = ticket.budgetStartedAt.flatMap({ formatter.date(from: $0) }) ?? firstTaskStart else { continue }
            let raw = formatter.string(from: start)
            let elapsed = elapsedWorkMinutes(from: start, to: now)
            guard let threshold = percentages.first(where: { Double(elapsed) / Double(ticket.planned) >= Double($0) / 100 }) else { continue }
            let id = "elapsed:" + ticket.key + ":" + raw
            let notified = SprintPreferences.store.dictionary(forKey: key)?[id] as? Int ?? 0
            guard threshold > notified, pending.insert(id).inserted else { continue }
            post(title: "Sprint: " + ticket.key + " · " + ticket.title,
                 body: "\(elapsed) of \(ticket.planned) planned workday minutes have elapsed since you started this story. Does the remaining scope still fit?") { [weak self] success in
                guard let self else { return }
                self.pending.remove(id)
                if success {
                    var recorded = SprintPreferences.store.dictionary(forKey: key) ?? [:]
                    recorded[id] = threshold
                    SprintPreferences.store.set(recorded, forKey: key)
                }
            }
        }
    }

    private func notifySprintDeadline() {
        let store = SprintPreferences.store
        guard store.bool(forKey: "sprintRemindersEnabled") else { return }
        let start = Date(timeIntervalSince1970: store.double(forKey: "sprintReminderStart"))
        let end = Date(timeIntervalSince1970: store.double(forKey: "sprintReminderEnd"))
        let now = Date()
        guard start <= now, now < end else { return }
        let total = elapsedWorkMinutes(from: start, to: end)
        let remaining = elapsedWorkMinutes(from: now, to: end)
        guard total > 0 else { return }
        let threshold = remaining <= min(480, total / 2) ? 2 : (remaining <= total / 2 ? 1 : 0)
        let id = "deadline:\(start.timeIntervalSince1970):\(end.timeIntervalSince1970)"
        let key = "notifiedSprintDeadline"
        guard threshold > (store.dictionary(forKey: key)?[id] as? Int ?? 0),
              pending.insert(id).inserted else { return }
        post(title: threshold == 2 ? "Sprint: Final workday" : "Sprint: Halfway point",
             body: "\(remaining / 60)h \(remaining % 60)m of scheduled work time remain before the sprint ends. Does the remaining scope fit?") { [weak self] success in
            self?.pending.remove(id)
            if success {
                var recorded = store.dictionary(forKey: key) ?? [:]
                recorded[id] = threshold
                store.set(recorded, forKey: key)
            }
        }
    }

    private func notify(_ overruns: [LocalTicket]) {
        for ticket in overruns {
            guard !(SprintPreferences.store.stringArray(forKey: stateKey) ?? []).contains(ticket.key),
                  pending.insert(ticket.key).inserted else { continue }
            let minutes = ticket.effort - ticket.remaining
            let duration = String(format: "%dh %02dm", minutes / 60, minutes % 60)
            post(title: "Overrun: " + ticket.title,
                 body: "\(ticket.key) is forecast to exceed its budget by \(duration). Check with your team whether scope or budget should change.") { [weak self] success in
                guard let self else { return }
                self.pending.remove(ticket.key)
                if success {
                    var keys = Set(SprintPreferences.store.stringArray(forKey: self.stateKey) ?? [])
                    keys.insert(ticket.key)
                    SprintPreferences.store.set(keys.sorted(), forKey: self.stateKey)
                }
            }
        }
    }

    private func post(title: String, body: String, completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("Sprint could not add notification: %@", error.localizedDescription) }
            DispatchQueue.main.async { completion(error == nil) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let budgetNotifications = BudgetNotifications()
    private var instanceLock: Int32 = -1
    var window: BudgetWindow?
    var menuItem: NSStatusItem?
    var shortcuts: [EventHotKeyRef] = []
    var scenario: Scenario?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lockURL = URL.applicationSupportDirectory.appendingPathComponent("Sprint/gui.lock")
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("Sprint could not prepare its instance lock: %@", error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        instanceLock = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            NSApp.terminate(nil)
            return
        }
        let panel = BudgetWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 830),
                                 styleMask: [.titled, .closable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.acceptsMouseMovedEvents = true
        panel.title = "Sprint"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace]
        let budgetView = BudgetView()
        scenario = budgetView.scenario
        panel.switchTab = { step in
            if budgetView.scenario.mode == .unplanned { budgetView.moveSelection(by: step) }
            else { budgetView.scenario.switchTab(step) }
        }
        panel.switchMode = { [weak self] step in
            guard let self, let mode = self.scenario?.mode else { return }
            let modes = BudgetMode.navigation
            guard let index = modes.firstIndex(of: mode) else { return }
            self.show(modes[(index + step + modes.count) % modes.count])
        }
        panel.dailyActionKey = budgetView.handleDailyActionKey
        panel.storyActionKey = budgetView.handleStoryActionKey
        panel.openSettings = { [weak self] in self?.show(.settings) }
        panel.storyFocusKey = { key in
            let scenario = budgetView.scenario
            guard scenario.mode == .ticket else { return false }
            let focus: StoryFocus?
            switch key {
            case kVK_ANSI_A: focus = .criteria
            case kVK_ANSI_T: focus = .budget
            case kVK_ANSI_P: focus = .progress
            case kVK_Escape where scenario.storyFocus != nil: focus = nil
            default: return false
            }
            let next = scenario.storyFocus == focus ? nil : focus
            scenario.storyFocus = next
            scenario.taskDetailsID = nil
            scenario.selectedTask = nil
            scenario.selectedCriterion = nil
            scenario.selectedBudget = nil
            if let ticket = scenario.ticket, next == nil || next == .budget {
                scenario.selectedBudget = ticket.stage == "done"
                    ? (ticket.remaining < 0 ? "Overrun" : "Unused Budget")
                    : "Remaining budget"
            } else if next != nil {
                budgetView.moveSelection(by: 1)
            }
            return true
        }
        panel.moveSelection = budgetView.moveSelection
        panel.toggleTaskDetails = budgetView.toggleSelectedDetails
        panel.isEditing = { budgetView.scenario.editingTask != nil }
        panel.cancelEdit = budgetView.cancelEdit
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        let hosting = NSHostingView(rootView: GeometryReader { geometry in
            budgetView.frame(width: geometry.size.width, height: geometry.size.height)
        })
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        window = panel

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Sprint")
        let menu = NSMenu()
        for mode in BudgetMode.allCases {
            let item = menu.addItem(withTitle: mode.title + (mode == .settings ? "  ⌘," : "  ⌥" + mode.key.letter),
                                    action: #selector(openMode(_:)), keyEquivalent: "")
            item.tag = Int(mode.rawValue)
            item.target = self
        }
        let testNotification = menu.addItem(withTitle: "Send Test Budget Notification",
                                            action: #selector(sendTestBudgetNotification), keyEquivalent: "")
        testNotification.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sprint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        menuItem = status

        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID(signature: 0, id: 0)
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, let mode = BudgetMode(rawValue: id.id == 5 ? BudgetMode.planning.rawValue : id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().toggle(mode)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        var unavailable: [String] = []
        for mode in BudgetMode.allCases where mode != .settings {
            var shortcut: EventHotKeyRef?
            let registration = RegisterEventHotKey(UInt32(mode.key.code), UInt32(optionKey),
                EventHotKeyID(signature: 0x5A454954, id: mode.rawValue),
                GetApplicationEventTarget(), 0, &shortcut)
            if handler == noErr, registration == noErr, let shortcut {
                shortcuts.append(shortcut)
            } else {
                unavailable.append("⌥" + mode.key.letter)
            }
        }
        status.button?.toolTip = unavailable.isEmpty ? "Sprint" : "Unavailable: " + unavailable.joined(separator: ", ")
        NSLog("Sprint registered %d shortcuts", shortcuts.count)
        budgetNotifications.start()
        if CommandLine.arguments.contains("--test-budget-notification") { budgetNotifications.test() }
        if !CommandLine.arguments.contains("--background") { toggle(.ticket) }
    }

    @objc private func sendTestBudgetNotification() { budgetNotifications.test() }

    @objc private func openMode(_ item: NSMenuItem) {
        if let mode = BudgetMode(rawValue: UInt32(item.tag)) { toggle(mode) }
    }

    private func toggle(_ mode: BudgetMode) {
        guard let window, let scenario else { return }
        if window.isVisible && window.isKeyWindow && scenario.mode == mode {
            window.orderOut(nil)
        } else {
            show(mode)
        }
    }

    private func show(_ mode: BudgetMode) {
        guard let window, let scenario else { return }
        scenario.dailyActionStage = nil
        scenario.storyFocus = nil
        scenario.actionIndex = nil
        if mode == .daily { scenario.dailyOffset = 0 }
        scenario.selectedReportRow = nil
        if mode == .unplanned || mode == .daily { scenario.reloadUnplanned() }
        scenario.reloadTicket(preferActive: mode == .ticket)
        if mode != .ticket { scenario.reloadNotes() }
        if scenario.mode != mode {
            window.cancelEdit?()
            scenario.mode = mode
        }
        if let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("U3225QE") })
            ?? NSScreen.screens.first {
            window.setFrame(screen.visibleFrame, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

if CommandLine.arguments.count > 1 && !CommandLine.arguments.dropFirst().allSatisfy({ ["--background", "--test-budget-notification"].contains($0) }) {
    do {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "reference-add" {
            try SprintPreferences.addReference(args)
        } else if let command = args.first, ["unplanned-list", "unplanned-add", "unplanned-edit"].contains(command) {
            try UnplannedStore.cli(command)
        } else {
            try TicketStore.cli(args)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
