import AppKit
import Darwin
import Foundation
import RAPPCrispyCore
import RAPPDesktopSupport
import SwiftUI

@MainActor
final class CrispyAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CrispyAppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.job.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A meeting job is still active"
        alert.informativeText = "Quit will stop capture and cancel processing. Completed local audio and text are kept. Content already sent to a notes provider cannot be recalled."
        alert.addButton(withTitle: "Keep app open")
        alert.addButton(withTitle: "Cancel job and quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.job.cancel()
        Task {
            await model.job.waitForCurrentOperation()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct RAPPCrispyApp: App {
    @NSApplicationDelegateAdaptor(CrispyAppDelegate.self) private var delegate
    @StateObject private var bootstrap: AppBootstrap

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-check"] {
            print("RAPP Crispy \(CrispyVersion.current) — native SwiftUI/AppKit, macOS 14+, no capture started")
            exit(0)
        }
        if arguments == ["--runtime-check"] {
            do {
                let runtime = try RuntimeTools.executable(named: "whisper-cli")
                let result = [
                    "app_version": CrispyVersion.current,
                    "bundle_id": CrispyVersion.bundleID,
                    "whisper_cli": runtime.path
                ]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                print()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        if arguments == ["--diagnostics-json"] {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(AudioDevices.snapshot()))
                print()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        if arguments.contains(where: { $0.hasPrefix("--") }) {
            FileHandle.standardError.write(Data("Supported read-only flags: --self-check, --runtime-check, --diagnostics-json. Start/stop recording in the graphical app.\n".utf8))
            exit(2)
        }
        _bootstrap = StateObject(wrappedValue: AppBootstrap())
    }

    var body: some Scene {
        WindowGroup("RAPP Crispy", id: "main") {
            if let model = bootstrap.model {
                MainView(model: model, job: model.job)
                    .onAppear { delegate.model = model }
                    .onOpenURL { model.handle($0) }
            } else {
                ContentUnavailableView("Cannot open the meeting library", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(bootstrap.error ?? "Unknown startup error"))
                    .frame(minWidth: 600, minHeight: 300)
            }
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Meeting files in Finder") {
                    if let model = bootstrap.model { NSWorkspace.shared.open(model.store.meetingsDirectory) }
                }
            }
        }
        MenuBarExtra("RAPP Crispy", systemImage: "waveform") {
            if let model = bootstrap.model {
                StatusMenu(model: model, job: model.job)
            } else {
                Text("Library unavailable")
            }
        }
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: CrispyAppModel
    @ObservedObject var job: MeetingJob
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(job.isRecording ? "● Recording microphone" : job.status)
        Button("Show RAPP Crispy") { openWindow(id: "main"); model.activate() }
        Divider()
        Button("Stop recording") { model.stop() }.disabled(!job.isRecording)
            .accessibilityIdentifier("crispy.menu.stop")
        Button("Cancel active job") { job.cancel() }.disabled(!job.isBusy)
            .accessibilityIdentifier("crispy.menu.cancel")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
