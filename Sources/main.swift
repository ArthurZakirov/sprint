import AppKit
import SwiftUI
import Carbon

enum BudgetMode: UInt32, CaseIterable {
    case ticket = 1, daily, planning

    var title: String {
        switch self {
        case .ticket: "Ticket Decision"
        case .daily: "Daily Standup"
        case .planning: "Planning"
        }
    }

    var key: (code: Int, letter: String) {
        switch self {
        case .ticket: (kVK_ANSI_J, "J")
        case .daily: (kVK_ANSI_D, "D")
        case .planning: (kVK_ANSI_P, "P")
        }
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
    var target: Int { sprintPointTarget ?? 4 }
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
                        else { current.lastWorkedAt = ISO8601DateFormatter().string(from: Date()) }
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

final class Scenario: ObservableObject {
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
        if ticket?.key != entry.ticket.key {
            editingTask = nil
            selectedTask = nil
            taskDetailsID = nil
            selectedBudget = nil
            selectedCriterion = nil
            expandedComments = []
        }
        ticketURL = entry.url
        ticket = entry.ticket
        ticketReadError = nil
    }

    @Published var dailyOffset = 0

    func switchTab(_ step: Int) {
        if mode == .daily {
            dailyOffset = max(-3650, min(0, dailyOffset + step))
            reloadNotes()
            return
        }
        guard mode == .ticket, let key = ticket?.key else { return }
        let keys = TicketStore.registry().map(\.ticket.key)
        guard keys.count > 1, let index = keys.firstIndex(of: key) else { return }
        reloadTicket(key: keys[(index + step + keys.count) % keys.count])
    }

    @Published var mode: BudgetMode = .ticket
    @Published var editingTask: String?
    @Published var draft = ""
    @Published var invalidDuration = false
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
            } else {
            let forecast = scenario.ticket.map(storyForecast)
            let atRisk = forecast.map { $0.margin < 0 } ?? false
            let tone: Color = atRisk ? .red : .green
            VStack(alignment: .leading, spacing: 22) {
                storyBar
                .padding(.horizontal, 10)
                .frame(height: 106)
                .background(Color(red: 0.15, green: 0.18, blue: 0.23), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.24)).frame(height: 1)
                }
                GeometryReader { layout in
                let columnWidth = max(1, (layout.size.width - 65) / 2)
                HStack(alignment: .top, spacing: 32) {
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
                    Text("Ticket Budget").font(.system(size: 19, weight: .semibold))
                    if let ticket = scenario.ticket {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("H/5D").frame(width: 64, alignment: .leading)
                                Text(clock(ticket.capacity)).monospacedDigit()
                            }
                            planningInput("SP/5D", value: String(ticket.target), id: " ")
                            HStack {
                                Text("H/SP").frame(width: 64, alignment: .leading)
                                Text(clock(Int(ticket.factor.rounded()))).monospacedDigit()
                            }
                            .accessibilityLabel("Hours per story point")
                            .accessibilityValue(clock(Int(ticket.factor.rounded())))
                        }
                        if scenario.invalidDuration && (scenario.editingTask == "" || scenario.editingTask == " ") {
                            Text("Enter a positive duration (HH:MM) or a positive whole SP target.")
                                .foregroundStyle(.red)
                        }
                    }
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
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))



                }
                .padding(.bottom, 24)
                }
                .onChange(of: scenario.selectedBudget) { _, metric in
                    if let metric { proxy.scrollTo(metric) }
                }
                }
                .frame(width: columnWidth, alignment: .topLeading)
                Divider()
                ScrollViewReader { proxy in
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let ticket = scenario.ticket {
                        Text(ticket.title).font(.system(size: 33, weight: .bold)).lineLimit(2)
                        Text(ticket.key + (ticket.storyPoints.map { "  ·  \($0) Story Points" } ?? ""))
                            .foregroundStyle(.secondary)
                        Text("Why").font(.system(size: 19, weight: .semibold))
                        Text(ticket.why ?? ticket.description ?? "—").font(.system(size: 17)).textSelection(.enabled)
                        HStack {
                            Text("Acceptance Criteria").font(.system(size: 19, weight: .semibold))
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
                        Text("Remarks").font(.system(size: 19, weight: .semibold))
                        Text(ticket.remarks ?? "—").font(.system(size: 17)).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.bottom, 6)
                    Text("Progress").font(.system(size: 19, weight: .semibold))
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
                .frame(width: columnWidth, alignment: .topLeading)
                }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("↩  Copy story key    ⌥ J  Toggle    Esc  Close")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.085, green: 0.10, blue: 0.13))
            .preferredColorScheme(.dark)
            }
        }
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
                            Button { scenario.reloadTicket(key: key) } label: {
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
                Text("⌃⇧Tab / ⌃Tab").foregroundStyle(.secondary)
            }
            taskActivity(weekly: false)
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

    private func taskActivity(weekly: Bool) -> some View {
        let period = reportPeriod(weekly: weekly)
        let scope = ReportNotes.scope(weekly: weekly, end: period.end)
        let groups = reportStories.map { (story: $0, rows: reportRows(for: $0, weekly: weekly)) }
            .filter { !$0.rows.isEmpty || ($0.story.sprint == nil && $0.story.stage != "done") || !scenario.speakingNotes[scope + ":story:" + $0.story.key, default: ""].isEmpty }
            .sorted {
                let order = ["done": 0, "in-progress": 1, "planned": 2]
                let left = order[$0.story.stage, default: 3]
                let right = order[$1.story.stage, default: 3]
                return left == right ? $0.story.key < $1.story.key : left < right
            }
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
                                    reportTableRow(title: row.task.title, status: row.task.status,
                                                   spent: clock(row.spent), notes: row.notes)
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

    private func reportShell<Content: View>(_ mode: BudgetMode, subtitle: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mode.title).font(.system(size: 33, weight: .bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content() }
                    .frame(maxWidth: 1050, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
            Text("⌥" + mode.key.letter + "  Toggle    Esc  Close").font(.system(size: 15)).foregroundStyle(.secondary)
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
                if !showForecast && remaining < 0 {
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
                if remaining >= 0 || showForecast {
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
        guard let id = scenario.selectedTask, currentTasks.contains(where: { $0.id == id }) else {
            return false
        }
        scenario.taskDetailsID = scenario.taskDetailsID == id ? nil : id
        return true
    }

    func moveSelection(by step: Int) {
        guard scenario.mode == .ticket else { return }
        let tasks = currentTasks
        let criteriaCount = scenario.ticket?.acceptanceCriteria.count ?? 0
        let budget: [String]
        if let ticket = scenario.ticket {
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
            ?? scenario.selectedCriterion.map { $0 + budget.count }
            ?? tasks.firstIndex { $0.id == scenario.selectedTask }.map { $0 + budget.count + criteriaCount }
        let next = current.map { min(max($0 + step, 0), count - 1) }
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
                scenario.taskDetailsID = task.id
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
    var copyStoryKey: (() -> Bool)?
    var toggleTaskDetails: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, Int(event.keyCode) == kVK_Tab,
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
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if copyStoryKey?() == true { return }
            case kVK_Space:
                if !(firstResponder is NSTextView), !event.isARepeat, toggleTaskDetails?() == true { return }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: BudgetWindow?
    var menuItem: NSStatusItem?
    var shortcuts: [EventHotKeyRef] = []
    var scenario: Scenario?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = BudgetWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 830),
                                 styleMask: [.titled, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.acceptsMouseMovedEvents = true
        panel.title = "Sprint"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        let budgetView = BudgetView()
        scenario = budgetView.scenario
        panel.switchTab = budgetView.scenario.switchTab
        panel.copyStoryKey = {
            let scenario = budgetView.scenario
            guard scenario.mode == .ticket, let key = scenario.ticket?.key else {
                return false
            }
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            return clipboard.setString(key, forType: .string)
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
            let item = menu.addItem(withTitle: mode.title + "  ⌥" + mode.key.letter,
                                    action: #selector(openMode(_:)), keyEquivalent: "")
            item.tag = Int(mode.rawValue)
            item.target = self
        }
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
            guard result == noErr, let mode = BudgetMode(rawValue: id.id == 4 ? BudgetMode.planning.rawValue : id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().toggle(mode)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        var unavailable: [String] = []
        for mode in BudgetMode.allCases {
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
        var weeklyShortcut: EventHotKeyRef?
        if handler == noErr,
           RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(optionKey),
                EventHotKeyID(signature: 0x5A454954, id: 4),
                GetApplicationEventTarget(), 0, &weeklyShortcut) == noErr,
           let weeklyShortcut {
            shortcuts.append(weeklyShortcut)
        } else {
            unavailable.append("⌥W")
        }
        status.button?.toolTip = unavailable.isEmpty ? "Sprint" : "Unavailable: " + unavailable.joined(separator: ", ")
        NSLog("Sprint registered %d of 4 shortcuts", shortcuts.count)
        toggle(.ticket)
    }

    @objc private func openMode(_ item: NSMenuItem) {
        if let mode = BudgetMode(rawValue: UInt32(item.tag)) { toggle(mode) }
    }

    private func toggle(_ mode: BudgetMode) {
        guard let window, let scenario else { return }
        if window.isVisible && window.isKeyWindow && scenario.mode == mode {
            window.orderOut(nil)
        } else {
            if mode == .daily { scenario.dailyOffset = 0 }
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
}

if CommandLine.arguments.count > 1 {
    do {
        try TicketStore.cli(Array(CommandLine.arguments.dropFirst()))
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
