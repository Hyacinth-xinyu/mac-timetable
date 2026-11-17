import SwiftUI
import UserNotifications

import UniformTypeIdentifiers
import AppKit

@main
struct TimetableApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(TimetableAppDelegate.self) private var appDelegate
    var body: some Scene {
        Window("课表", id: "main") {
            MainView()
                .environmentObject(store)
                .background(MainWindowObserver())
        }
            .defaultSize(width: 1120, height: 760)
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("退出课表（收起到菜单栏）") {
                        WindowLifecycle.shared.hideMainWindow()
                    }
                    .keyboardShortcut("q")
                }
            }
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            Label("课表", systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

private let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
private let calendarFileType = UTType(filenameExtension: "ics") ?? .data

private struct CalendarFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [calendarFileType] }
    static var writableContentTypes: [UTType] { [calendarFileType] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private func timeText(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
private func courseTime(_ course: Course, settings: AppSettings) -> String {
    guard settings.periods.indices.contains(course.startPeriod - 1), settings.periods.indices.contains(course.endPeriod - 1) else { return "第 \(course.startPeriod)–\(course.endPeriod) 节" }
    return "\(timeText(settings.periods[course.startPeriod - 1].startMinutes))–\(timeText(settings.periods[course.endPeriod - 1].endMinutes))"
}

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedWeek = 1
    @State private var showImport = false
    @State private var importTargetID: UUID?
    @State private var importTargetName = ""
    @State private var draft: ImportDraft?
    @State private var editing: CourseDraft?
    @State private var settingsTarget: TimetableTarget?
    @State private var showTimetableManager = false
    @State private var errorMessage: String?
    @State private var errorTitle = "无法导入课表"
    @State private var showExportInfo = false
    @State private var showExport = false
    @State private var exportDocument: CalendarFileDocument?
    @State private var exportName = "我的课表"
    @State private var exportHasReminder = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.courses.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                    Text("开始安排你的学期").font(.title2.weight(.semibold))
                    Text("导入 Word 课表，或手动添加第一门课程。\n设置学期和作息时间后，就能收到课前提醒。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack { Button("导入 Word 课表") { beginImport() }.buttonStyle(.borderedProminent); Button("添加课程") { editing = CourseDraft(course: Course(), timetableID: store.selectedTimetableID) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                schedule
            }
            if let message = store.statusMessage, !message.isEmpty {
                HStack { Image(systemName: "info.circle"); Text(message); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(10)
            }
            HStack {
                Image(systemName: "menubar.rectangle")
                Text("关闭窗口或 ⌘Q 可收起到顶部菜单栏；菜单中可完全退出。若顶部入口被遮挡，点击 Dock 中的课表图标恢复窗口。")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { selectedWeek = max(1, store.weekNumber()) }
        .onChange(of: store.selectedTimetableID) { _ in selectedWeek = max(1, store.weekNumber()) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [UTType(filenameExtension: "docx") ?? .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let imported = try DocxImporter.parse(url: url)
                guard let target = importTargetID, store.timetable(id: target) != nil else {
                    errorTitle = "无法导入课表"; errorMessage = "目标课表已不存在，请重新选择。"; return
                }
                draft = ImportDraft(courses: imported.courses, warnings: imported.warnings, skipped: imported.skipped, timetableID: target, timetableName: store.timetable(id: target)?.name ?? importTargetName)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError { errorTitle = "无法导入课表"; errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: calendarFileType, defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                    errorTitle = "无法导出日历"
                    errorMessage = error.localizedDescription
                }
            }
            exportDocument = nil
        }
        .sheet(item: $draft) { value in ImportPreview(draft: value) { courses in
            let success = store.updateCourses(courses, forID: value.timetableID)
            if success, store.selectedTimetableID == value.timetableID { selectedWeek = max(1, store.weekNumber()) }
            return success
        }.environmentObject(store) }
        .sheet(item: $editing) { value in CourseEditor(course: value.course) { course in
            guard let target = value.timetableID, var record = store.timetable(id: target) else { store.statusMessage = "目标课表已不存在，无法保存课程。"; return false }
            if let index = record.courses.firstIndex(where: { $0.id == course.id }) { record.courses[index] = course } else { record.courses.append(course) }
            return store.updateCourses(record.courses, forID: target)
        } onDelete: { id in
            guard let target = value.timetableID, var record = store.timetable(id: target) else { store.statusMessage = "目标课表已不存在，无法删除课程。"; return false }
            record.courses.removeAll { $0.id == id }; return store.updateCourses(record.courses, forID: target)
        } }
        .sheet(item: $settingsTarget) { target in SettingsView(timetableID: target.id).environmentObject(store) }
        .sheet(isPresented: $showTimetableManager) { TimetableManager().environmentObject(store) }
        .alert("导出到苹果日历", isPresented: $showExportInfo) {
            Button("取消", role: .cancel) { exportDocument = nil }
            Button("继续保存") { showExport = true }
        } message: {
            Text("将导出“\(exportName)”整个学期的课表。导入日历后，课表的后续修改不会自动同步；重复导入可能产生重复日程。\(exportHasReminder ? "\n\n课表和苹果日历同时开启提醒时，可能收到重复通知。" : "")")
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    ForEach(store.timetables) { timetable in
                        Button { _ = store.selectTimetable(id: timetable.id) } label: {
                            if timetable.id == store.selectedTimetableID { Label(timetable.name, systemImage: "checkmark") } else { Text(timetable.name) }
                        }
                    }
                    Divider()
                    Button("管理课表…") { showTimetableManager = true }
                } label: {
                    HStack(spacing: 5) { Text(store.timetable(id: store.selectedTimetableID)?.name ?? "课表").font(.title2.bold()).lineLimit(1); Image(systemName: "chevron.down").font(.caption) }
                }.menuStyle(.borderlessButton).fixedSize().help("切换或管理课表")
                Text("切换查看不同人的课程").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button { selectedWeek = max(1, selectedWeek - 1) } label: { Image(systemName: "chevron.left") }.help("上一周")
                Text("第 \(selectedWeek) 周").font(.headline.monospacedDigit()).frame(minWidth: 72)
                Button { selectedWeek += 1 } label: { Image(systemName: "chevron.right") }.help("下一周")
                Button("回到本周") { selectedWeek = max(1, store.weekNumber()) }
            }.buttonStyle(.borderless)
            Divider().frame(height: 24).padding(.horizontal, 4)
            Button { beginImport() } label: { Label("导入", systemImage: "square.and.arrow.down") }
            Button { prepareExport() } label: { Label("导出日历", systemImage: "square.and.arrow.up") }
                .disabled(store.courses.isEmpty)
                .help("将整个学期导出为日历文件")
            Button { editing = CourseDraft(course: Course(), timetableID: store.selectedTimetableID) } label: { Label("添加", systemImage: "plus") }
            Button { settingsTarget = TimetableTarget(id: store.selectedTimetableID) } label: { Image(systemName: "gearshape") }.help("学期与提醒设置").accessibilityLabel("学期与提醒设置")
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private func beginImport() {
        guard let target = store.timetable(id: store.selectedTimetableID) else { return }
        importTargetID = target.id; importTargetName = target.name; showImport = true
    }
    private func prepareExport() {
        do {
            guard let snapshot = store.exportSnapshot(id: store.selectedTimetableID) else { errorTitle = "无法导出日历"; errorMessage = "目标课表已不存在。"; return }
            exportDocument = CalendarFileDocument(data: try CalendarExporter.export(courses: snapshot.courses, settings: snapshot.settings))
            exportName = snapshot.name; exportHasReminder = snapshot.settings.remindersEnabled
            showExportInfo = true
        } catch {
            errorTitle = "无法导出日历"
            errorMessage = error.localizedDescription
        }
    }
    private var schedule: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("节次").font(.caption).foregroundStyle(.secondary).frame(width: 66)
                    ForEach(1...7, id: \.self) { day in
                        VStack(spacing: 4) {
                            Text(weekdayNames[day - 1]).font(.subheadline.weight(.semibold))
                            if let date = store.date(forWeek: selectedWeek, weekday: day) { Text(date, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary) }
                        }.frame(width: 145).padding(.vertical, 12)
                    }
                }.background(Color(nsColor: .controlBackgroundColor))
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(1...13, id: \.self) { period in
                            VStack(spacing: 3) {
                                Text("\(period)").font(.subheadline.weight(.medium))
                                if store.settings.periods.indices.contains(period - 1) { Text(timeText(store.settings.periods[period - 1].startMinutes)).font(.caption2).foregroundStyle(.secondary) }
                            }.frame(width: 66, height: 76).overlay(alignment: .bottom) { Divider() }
                        }
                    }
                    ForEach(1...7, id: \.self) { day in dayColumn(day) }
                }
            }.frame(width: 1081)
        }
    }
    private func dayColumn(_ day: Int) -> some View {
        let courses = store.courses(forWeek: selectedWeek).filter { $0.weekday == day }.sorted { ($0.startPeriod, $0.name) < ($1.startPeriod, $1.name) }
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) { ForEach(1...13, id: \.self) { _ in Rectangle().fill(Color.clear).frame(height: 76).overlay(alignment: .bottom) { Divider().opacity(0.5) } } }
            ForEach(courses) { course in
                let overlaps = courses.filter { $0.startPeriod <= course.endPeriod && $0.endPeriod >= course.startPeriod }
                let index = overlaps.firstIndex(where: { $0.id == course.id }) ?? 0
                let width = 137.0 / Double(max(1, overlaps.count))
                Button { editing = CourseDraft(course: course, timetableID: store.selectedTimetableID) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name).font(.caption.weight(.semibold))
                            .lineLimit(course.isOnline ? 2 : 3)
                            .layoutPriority(2)
                        if course.isOnline {
                            Label("线上授课", systemImage: "video.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.purple)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if course.location.trimmingCharacters(in: .whitespacesAndNewlines) != "线上授课" {
                                Text(course.location).font(.caption2).lineLimit(1)
                            }
                        } else {
                            if !course.location.isEmpty { Text(course.location).font(.caption2).lineLimit(2) }
                            Text("\(course.startPeriod)–\(course.endPeriod) 节").font(.caption2)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(7)
                        .background((course.isOnline ? Color.purple : Color.accentColor).opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("编辑 \(course.name)\(course.isOnline ? "，线上授课" : "")")
                    .frame(width: width - 3, height: max(40, CGFloat(course.endPeriod - course.startPeriod + 1) * 76 - 6))
                    .offset(x: 4 + Double(index) * width, y: CGFloat(course.startPeriod - 1) * 76 + 3)
            }
        }.frame(width: 145, height: 988).overlay(alignment: .leading) { Divider().opacity(0.5) }
    }
}

struct TimetableTarget: Identifiable { let id: UUID }
struct CourseDraft: Identifiable { let id = UUID(); var course: Course; var timetableID: UUID? = nil }
struct ImportDraft: Identifiable { let id = UUID(); var courses: [Course]; var warnings: [String]; var skipped: [String]; let timetableID: UUID; let timetableName: String }

struct ImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State var draft: ImportDraft
    @State private var editing: CourseDraft?
    @State private var confirm = false
    @State private var showSettings = false
    @State private var checkedSettings = false
    var onCommit: ([Course]) -> Bool
    private var targetName: String { store.timetable(id: draft.timetableID)?.name ?? "\(draft.timetableName)（已删除）" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("检查导入的课表").font(.title2.bold())
            Text("已识别 \(draft.courses.count) 条课程安排。点击课程可校对；确认后将替换“\(targetName)”的课表。") .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("确认学期和作息").fontWeight(.medium); Text("文件不包含第一教学周和具体作息，请核对日期及长安校区时间。") .font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("设置") { showSettings = true }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Toggle("我已核对第一教学周和各节课时间", isOn: $checkedSettings).font(.caption)
            if !draft.warnings.isEmpty || !draft.skipped.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "exclamationmark.triangle") }
                    ForEach(Array(draft.skipped.enumerated()), id: \.offset) { _, text in Label("已跳过：\(text)", systemImage: "minus.circle") }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = store.statusMessage { Text(message).font(.caption).foregroundStyle(.red) }
            List {
                ForEach(draft.courses) { course in
                    Button { editing = CourseDraft(course: course) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                HStack(spacing: 6) {
                                    Text(course.name).fontWeight(.medium)
                                    if course.isOnline {
                                        Label("线上授课", systemImage: "video.fill")
                                            .font(.caption).foregroundStyle(.purple)
                                    }
                                }
                                Text("\(weekdayNames[max(0, min(6, course.weekday - 1))]) · 第 \(course.startPeriod)–\(course.endPeriod) 节 · \(course.location)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Text("\(course.weeks.map(String.init).joined(separator: ",")) 周").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("确认导入") { confirm = true }.buttonStyle(.borderedProminent).disabled(draft.courses.isEmpty || !checkedSettings) }
        }.padding(24).frame(width: 700, height: 600)
        .sheet(item: $editing) { value in CourseEditor(course: value.course) { course in
            if let index = draft.courses.firstIndex(where: { $0.id == course.id }) { draft.courses[index] = course }
            return true
        } onDelete: { id in draft.courses.removeAll { $0.id == id }; return true } }
        .sheet(isPresented: $showSettings) { SettingsView(timetableID: draft.timetableID).environmentObject(store) }
        .confirmationDialog("替换“\(targetName)”的课表？", isPresented: $confirm) {
            Button("替换并导入", role: .destructive) { if onCommit(draft.courses) { dismiss() } }
            Button("取消", role: .cancel) {}
        } message: { Text("“\(targetName)”已有课程将被导入的课表替换。") }
    }
}

struct CourseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State var course: Course
    @State private var weekText: String
    @State private var confirmDelete = false
    var onSave: (Course) -> Bool
    var onDelete: (UUID) -> Bool
    init(course: Course, onSave: @escaping (Course) -> Bool, onDelete: @escaping (UUID) -> Bool) {
        self._course = State(initialValue: course)
        self._weekText = State(initialValue: course.weeks.map(String.init).joined(separator: ","))
        self.onSave = onSave; self.onDelete = onDelete
    }
    private var parsedWeeks: [Int]? {
        var values = Set<Int>()
        for part in weekText.replacingOccurrences(of: "，", with: ",").split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespaces)
            let bounds = text.replacingOccurrences(of: "~", with: "-").split(separator: "-")
            if bounds.count == 1, let n = Int(bounds[0]), (1...60).contains(n) { values.insert(n) }
            else if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), a >= 1, b <= 60, a <= b { values.formUnion(a...b) }
            else { return nil }
        }
        return values.isEmpty ? nil : values.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑课程").font(.title2.bold())
            Form {
                TextField("课程名称", text: $course.name)
                TextField("教师", text: $course.teacher)
                TextField("地点或线上授课", text: $course.location)
                if course.isOnline {
                    Label("已标记为线上授课", systemImage: "video.fill")
                        .font(.caption).foregroundStyle(.purple)
                    Text("可直接修改地点或授课链接。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("标记为线上授课") {
                        let existing = course.location.trimmingCharacters(in: .whitespacesAndNewlines)
                        course.location = existing.isEmpty ? "线上授课" : "\(course.location) · 线上授课"
                    }
                }
                Picker("星期", selection: $course.weekday) { ForEach(1...7, id: \.self) { Text(weekdayNames[$0 - 1]).tag($0) } }
                HStack { Stepper("开始：第 \(course.startPeriod) 节", value: $course.startPeriod, in: 1...13); Stepper("结束：第 \(course.endPeriod) 节", value: $course.endPeriod, in: 1...13) }
                TextField("上课周次", text: $weekText, prompt: Text("例如 1-8,10,12-16"))
                if parsedWeeks == nil { Text("请输入 1 到 60 之间的周次，例如 1-8,10。") .font(.caption).foregroundStyle(.red) }
                if !course.rawText.isEmpty {
                    DisclosureGroup("查看导入原文") { Text(course.rawText).textSelection(.enabled).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.formStyle(.grouped)
            if let message = store.statusMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("删除课程", role: .destructive) { confirmDelete = true }
                Spacer(); Button("取消") { dismiss() }
                Button("保存") {
                    guard let weeks = parsedWeeks else { return }; course.weeks = weeks; if onSave(course) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedWeeks == nil || course.endPeriod < course.startPeriod)
            }
        }.padding(24).frame(width: 560, height: 550)
        .confirmationDialog("确定删除这门课程？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { if onDelete(course.id) { dismiss() } }
            Button("取消", role: .cancel) {}
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let timetableID: UUID
    @State private var working: AppSettings?
    @State private var launchAtLogin = false
    @State private var notificationStatus = "正在检查"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(store.timetable(id: timetableID)?.name ?? "课表") · 设置").font(.title2.bold())
            if let settings = working {
                Form {
                    Section("学期") {
                        DatePicker("第一教学周的日期", selection: binding(\.firstWeekDate, fallback: settings.firstWeekDate), displayedComponents: .date)
                        Text("按所选日期所在的周一计算第一周。") .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("课前提醒") {
                        if timetableID == store.ownTimetableID {
                            Toggle("启用课前提醒", isOn: binding(\.remindersEnabled, fallback: settings.remindersEnabled))
                            Stepper("提前 \(settings.reminderMinutes) 分钟", value: binding(\.reminderMinutes, fallback: settings.reminderMinutes), in: 0...120, step: 5)
                            HStack { Text("系统通知权限"); Spacer(); Text(notificationStatus).foregroundStyle(.secondary) }
                            Text("关闭主窗口后应用继续在菜单栏运行。请保持应用运行以持续安排提醒。") .font(.caption).foregroundStyle(.secondary)
                        } else { Text("只提醒“我的课表”；查看其他课表不会中断自己的提醒。") .foregroundStyle(.secondary) }
                    }
                    Section("启动") { Toggle("登录时自动启动", isOn: $launchAtLogin) }
                    Section("各节课作息") {
                        Button("使用长安校区作息") { working?.periods = AppSettings.changAnPeriods }
                        Text("按西北工业大学 2026–2027 学年长安校区课表设置，可按需调整。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(settings.periods.indices, id: \.self) { index in
                            HStack {
                                Text("第 \(index + 1) 节").frame(width: 54, alignment: .leading)
                                DatePicker("开始", selection: periodBinding(index: index, start: true), displayedComponents: .hourAndMinute).labelsHidden()
                                Text("至").foregroundStyle(.secondary)
                                DatePicker("结束", selection: periodBinding(index: index, start: false), displayedComponents: .hourAndMinute).labelsHidden()
                            }
                        }
                    }
                }.formStyle(.grouped)
                HStack { Button("取消") { dismiss() }; Spacer(); Button("保存设置") {
                    guard let working, store.updateSettings(working, forID: timetableID) else { return }
                    if store.launchAtLogin != launchAtLogin { store.setLaunchAtLogin(launchAtLogin) }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(!validTimes(settings)) }
                if !validTimes(settings) { Text("每节课的结束时间必须晚于开始时间。") .font(.caption).foregroundStyle(.red) }
                if let message = store.statusMessage { Text(message).font(.caption).foregroundStyle(.red) }
            }
        }.padding(24).frame(width: 560, height: 640)
        .onAppear {
            guard let record = store.timetable(id: timetableID) else { store.statusMessage = "目标课表已不存在，无法修改设置。"; dismiss(); return }
            working = record.settings; launchAtLogin = store.launchAtLogin
            UNUserNotificationCenter.current().getNotificationSettings { info in
                let status: String
                switch info.authorizationStatus { case .authorized, .provisional, .ephemeral: status = "已允许"; case .denied: status = "已关闭，请在系统设置中开启"; default: status = "尚未请求" }
                DispatchQueue.main.async { notificationStatus = status }
            }
        }
    }
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>, fallback: T) -> Binding<T> {
        Binding(get: { working?[keyPath: keyPath] ?? fallback }, set: { working?[keyPath: keyPath] = $0 })
    }
    private func periodBinding(index: Int, start: Bool) -> Binding<Date> {
        Binding(get: {
            let minutes = start ? (working?.periods[index].startMinutes ?? 0) : (working?.periods[index].endMinutes ?? 0)
            return Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes * 60))
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            if start { working?.periods[index].startMinutes = minutes } else { working?.periods[index].endMinutes = minutes }
        })
    }
    private func validTimes(_ settings: AppSettings) -> Bool { settings.periods.allSatisfy { $0.startMinutes < $0.endMinutes } }
}

struct TimetableManager: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renamedName = ""
    @State private var renameTarget: TimetableTarget?
    @State private var deleteTarget: TimetableTarget?
    @State private var showRename = false
    @State private var showDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("管理课表").font(.title2.bold())
            Text("每个人的课程、学期和作息各自保存。只有“我的课表”会发送提醒。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("输入姓名或课表名称", text: $newName)
                    .onSubmit { add() }
                Button("新建课表") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(store.timetables) { timetable in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(timetable.name).fontWeight(.medium)
                            Text(timetable.id == store.ownTimetableID ? "我的课表 · 可接收提醒" : "\(timetable.courses.count) 条课程安排")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if timetable.id == store.selectedTimetableID { Text("当前").font(.caption).foregroundStyle(.secondary) }
                        else { Button("切换") { _ = store.selectTimetable(id: timetable.id) } }
                        if timetable.id != store.ownTimetableID {
                            Button("重命名") { renameTarget = TimetableTarget(id: timetable.id); renamedName = timetable.name; showRename = true }
                            Button("删除", role: .destructive) { deleteTarget = TimetableTarget(id: timetable.id); showDelete = true }
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let message = store.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 560, height: 480)
        .alert("重命名课表", isPresented: $showRename) {
            TextField("课表名称", text: $renamedName)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") { if let target = renameTarget { _ = store.renameTimetable(id: target.id, name: renamedName) }; renameTarget = nil }
        }
        .confirmationDialog("删除这份课表？", isPresented: $showDelete) {
            Button("删除课表", role: .destructive) { if let target = deleteTarget { _ = store.deleteTimetable(id: target.id) }; deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("将删除“\(deleteTarget.flatMap { store.timetable(id: $0.id)?.name } ?? "该课表")”及其课程，此操作无法撤销。")
        }
    }

    private func add() {
        if store.addTimetable(name: newName) != nil { newName = "" }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date, snapshot: MenuSchedule.snapshot(store: store, now: context.date))
        }
    }

    private func content(now: Date, snapshot: MenuScheduleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(store.timetables) { timetable in
                    Button { _ = store.selectTimetable(id: timetable.id) } label: {
                        if timetable.id == store.selectedTimetableID { Label(timetable.name, systemImage: "checkmark") } else { Text(timetable.name) }
                    }
                }
            } label: {
                HStack { Label(store.timetable(id: store.selectedTimetableID)?.name ?? "课表", systemImage: "person.crop.circle"); Spacer(); Image(systemName: "chevron.up.chevron.down") }
            }.help("切换课表")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今天的课程").font(.headline)
                    Text(now, format: .dateTime.month().day().weekday(.wide)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(snapshot.week > 0 ? "第 \(snapshot.week) 周" : "学期未开始")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if store.courses.isEmpty {
                Text("还没有课表，请打开完整课表导入或添加课程。")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            } else if snapshot.today.isEmpty {
                Text("今天没有课程").foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.today) { course in
                            HStack(alignment: .top) {
                                Text(courseTime(course, settings: store.settings))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 85, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(course.name).fontWeight(.medium)
                                        if course.isOnline {
                                            Label("线上授课", systemImage: "video.fill")
                                                .font(.caption2).foregroundStyle(.purple)
                                        }
                                    }
                                    if !course.location.isEmpty {
                                        Text(course.location).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            if let next = snapshot.next {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("接下来").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Text(next.course.name).fontWeight(.medium)
                        if next.course.isOnline {
                            Label("线上授课", systemImage: "video.fill")
                                .font(.caption2).foregroundStyle(.purple)
                        }
                    }
                    Text(next.date, format: .dateTime.month().day().weekday(.abbreviated).hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    if !next.course.location.isEmpty {
                        Text(next.course.location).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("打开完整课表") { WindowLifecycle.shared.showMainWindow() }
                Spacer()
                Button("完全退出") { NSApp.terminate(nil) }
            }
        }.padding(16).frame(width: 310)
    }
}
