import AppKit
import CryptoKit
import Foundation

struct NexBrowserTaskResult: Sendable {
    let taskID: String
    let status: String
    let text: String
    let tabs: [String]
    let downloads: [String]
    let screenshots: [String]
    let error: String
}

actor NexManagedBrowserProvider {
    private let root: URL
    private var processes: [String: Process] = [:]
    private var results: [String: NexBrowserTaskResult] = [:]
    init(root: URL? = nil) { self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nexus/Browser", isDirectory: true) }

    func run(goal: String, stepsJSON: String, progress: @escaping @Sendable (String) async -> Void) async throws -> NexBrowserTaskResult {
        let taskID = UUID().uuidString.lowercased(), runtime = try await ensureRuntime(), taskRoot = root.appendingPathComponent("tasks/\(taskID)", isDirectory: true); try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        guard let stepsData = stepsJSON.data(using: .utf8), (try? JSONSerialization.jsonObject(with: stepsData)) is [Any] else { throw NexToolError.executionFailed(code: "invalid_browser_steps", message: "steps_json must be a JSON array of browser steps.") }
        let request: [String: Any] = ["taskID": taskID, "goal": goal, "steps": try JSONSerialization.jsonObject(with: stepsData), "profile": root.appendingPathComponent("Profile").path, "taskRoot": taskRoot.path, "chrome": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
        let input = try JSONSerialization.data(withJSONObject: request)
        let process = Process(), stdin = Pipe(), stdout = Pipe(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node"); process.arguments = [runtime.appendingPathComponent("agent.mjs").path]; process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stdout; processes[taskID] = process; try process.run(); try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        var final = NexBrowserTaskResult(taskID: taskID, status: "running", text: "", tabs: [], downloads: [], screenshots: [], error: "")
        for try await line in stdout.fileHandleForReading.bytes.lines { guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }; if let event = json["event"] as? String, event != "completed" { await progress((json["message"] as? String) ?? event) }; if json["event"] as? String == "completed" { final = .init(taskID: taskID, status: json["status"] as? String ?? "completed", text: json["text"] as? String ?? "", tabs: json["tabs"] as? [String] ?? [], downloads: json["downloads"] as? [String] ?? [], screenshots: json["screenshots"] as? [String] ?? [], error: json["error"] as? String ?? "") } }
        process.waitUntilExit(); processes[taskID] = nil; if process.terminationStatus != 0, final.status == "running" { final = .init(taskID: taskID, status: "failed", text: "", tabs: [], downloads: [], screenshots: [], error: "Managed browser process exited \(process.terminationStatus).") }; results[taskID] = final; return final
    }
    func status(_ id: String) -> NexBrowserTaskResult? { results[id] ?? (processes[id] != nil ? .init(taskID: id, status: "running", text: "", tabs: [], downloads: [], screenshots: [], error: "") : nil) }
    func cancel(_ id: String) throws { guard let process = processes[id] else { throw NexToolError.executionFailed(code: "browser_task_missing", message: "Browser task is not running.") }; process.terminate(); processes[id] = nil; results[id] = .init(taskID: id, status: "cancelled", text: "", tabs: [], downloads: [], screenshots: [], error: "") }
    func importProfile(chromeRoot: URL) throws -> [String] {
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) else { throw NexToolError.executionFailed(code: "chrome_must_close", message: "Quit Chrome before importing browser state.") }
        let source = chromeRoot.appendingPathComponent("Default"), destination = root.appendingPathComponent("Profile/Default"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true); var copied: [String] = []
        for name in ["Bookmarks", "History", "Preferences"] { let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name); guard FileManager.default.fileExists(atPath: from.path) else { continue }; try? FileManager.default.removeItem(at: to); try FileManager.default.copyItem(at: from, to: to); copied.append(name) }
        return copied
    }
    func reset() throws { for process in processes.values { process.terminate() }; processes.removeAll(); try? FileManager.default.removeItem(at: root.appendingPathComponent("Profile")); try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile"), withIntermediateDirectories: true) }

    private func ensureRuntime() async throws -> URL {
        let runtime = root.appendingPathComponent("Runtime", isDirectory: true), module = runtime.appendingPathComponent("node_modules/playwright-core")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: module.path) {
            guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npm") else { throw NexToolError.executionFailed(code: "npm_unavailable", message: "Managed Playwright provisioning requires the installed npm executable.") }
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/npm"); process.arguments = ["install", "--prefix", runtime.path, "--no-audit", "--no-fund", "playwright-core@1.55.0"]; process.standardOutput = pipe; process.standardError = pipe; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NexToolError.executionFailed(code: "playwright_install_failed", message: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Playwright provisioning failed.") }
        }
        let script = runtime.appendingPathComponent("agent.mjs"); if !FileManager.default.fileExists(atPath: script.path) { try Self.script.write(to: script, atomically: true, encoding: .utf8) }; return runtime
    }

    private static let script = #"""
import fs from 'node:fs';
import { chromium } from 'playwright-core';
const request = JSON.parse(fs.readFileSync(0, 'utf8'));
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
let context; const downloads = [], screenshots = [], extracted = [];
try {
  emit({event:'started',message:'Starting secure browser…'});
  context = await chromium.launchPersistentContext(request.profile,{headless:true,executablePath:request.chrome,acceptDownloads:true});
  let page = context.pages()[0] || await context.newPage();
  page.on('download', async download => { const target=`${request.taskRoot}/${download.suggestedFilename()}`; await download.saveAs(target); downloads.push(target); emit({event:'download',message:`Downloaded ${download.suggestedFilename()}`}); });
  for (const [index,step] of request.steps.entries()) {
    emit({event:'progress',message:step.label || `${step.action} ${index+1}/${request.steps.length}`});
    switch(step.action) {
      case 'navigate': await page.goto(step.url,{waitUntil:'domcontentloaded',timeout:30000}); break;
      case 'new_tab': page=await context.newPage(); if(step.url) await page.goto(step.url,{waitUntil:'domcontentloaded'}); break;
      case 'activate_tab': { const pages=context.pages(); if(!pages[step.index]) throw new Error('Tab index unavailable'); page=pages[step.index]; await page.bringToFront(); break; }
      case 'close_tab': await page.close(); page=context.pages()[0] || await context.newPage(); break;
      case 'click': await page.locator(step.selector).click(); break;
      case 'type': await page.locator(step.selector).fill(step.text || ''); break;
      case 'form': for(const field of step.fields || []) await page.locator(field.selector).fill(field.value); if(step.submitSelector) await page.locator(step.submitSelector).click(); break;
      case 'extract': extracted.push(await page.locator(step.selector || 'body').innerText({timeout:15000})); break;
      case 'upload': await page.locator(step.selector).setInputFiles(step.paths || []); break;
      case 'download': await Promise.all([page.waitForEvent('download'),page.locator(step.selector).click()]); break;
      case 'screenshot': { const target=`${request.taskRoot}/${step.name || `shot-${index}.png`}`; await page.screenshot({path:target,fullPage:step.fullPage ?? true}); screenshots.push(target); break; }
      default: throw new Error(`Unsupported browser step: ${step.action}`);
    }
  }
  emit({event:'completed',status:'completed',text:extracted.join('\n\n').slice(0,100000),tabs:context.pages().map(p=>p.url()),downloads,screenshots,error:''});
} catch(error) { emit({event:'completed',status:'failed',text:extracted.join('\n\n'),tabs:context?.pages().map(p=>p.url()) || [],downloads,screenshots,error:String(error?.message || error)}); process.exitCode=1; }
finally { await context?.close(); }
"""#
}

actor NexChromeLocalProvider {
    func list() throws -> [[String: NexJSONValue]] { let output = try script(#"tell application "Google Chrome" to set rows to {}\n tell application "Google Chrome"\n repeat with w from 1 to count windows\n repeat with t from 1 to count tabs of window w\n set end of rows to {(w as text), (t as text), title of tab t of window w, URL of tab t of window w, (t is active tab index of window w)}\n end repeat\n end repeat\n return rows\n end tell"#); return parseRows(output) }
    func active() throws -> [[String: NexJSONValue]] { try list().filter { $0["active"] == .bool(true) } }
    func activate(window: Int, tab: Int) throws { _ = try script("tell application \"Google Chrome\" to set active tab index of window \(window) to \(tab)\ntell application \"Google Chrome\" to set index of window \(window) to 1\ntell application \"Google Chrome\" to activate") }
    func openURL(_ url: URL) throws { guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw NexToolError.executionFailed(code: "unsafe_url", message: "Chrome only accepts HTTP(S) URLs.") }; _ = try script("tell application \"Google Chrome\" to open location \"\(url.absoluteString.replacingOccurrences(of: "\"", with: "%22"))\"") }
    func close(window: Int, tab: Int) throws { _ = try script("tell application \"Google Chrome\" to close tab \(tab) of window \(window)") }
    func open() throws { guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { throw BrowserTabProviderError.chromeUnavailable }; NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    private func script(_ source: String) throws -> String { var error: NSDictionary?; let result = NSAppleScript(source: source)?.executeAndReturnError(&error); if let error { throw BrowserTabProviderError.scriptFailed(error.description) }; return result?.description ?? "" }
    private func parseRows(_ ignored: String) -> [[String: NexJSONValue]] { [] } // list_tabs uses the proven BrowserTab provider in the UI process; retained for non-row commands.
}

actor NexBrowserActionCatalog {
    private let managed: NexManagedBrowserProvider; private var registered = false
    init(managed: NexManagedBrowserProvider = NexManagedBrowserProvider()) { self.managed = managed }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let managed = managed
        try await registry.register(manifest: Self.manifest("browser.run_task", "Run a bounded Playwright task in Nexus's separate persistent browser profile. Steps support navigation, tabs, click, type, forms, extraction, downloads, uploads, and screenshots.", ["Research this site and extract the results", "Fill this form but do not submit without confirmation"], ["goal": .init(.string, required: true), "steps_json": .init(.string, required: true)], risk: .high, confirmation: .always, method: .browserAgent)) { args, context in let result = try await managed.run(goal: try Self.required(args, "goal"), stepsJSON: try Self.required(args, "steps_json")) { await context.reportProgress($0, nil) }; return Self.result(result) }
        try await registry.register(manifest: Self.manifest("browser.get_task", "Read a managed browser task by stable ID.", ["Check that browser task"], ["task_id": .init(.string, required: true)], method: .browserAgent)) { args, _ in guard let result = await managed.status(try Self.required(args, "task_id")) else { throw NexToolError.executionFailed(code: "browser_task_missing", message: "Browser task was not found.") }; return Self.result(result) }
        try await registry.register(manifest: Self.manifest("browser.cancel_task", "Cancel a running managed browser task.", ["Cancel the browser task"], ["task_id": .init(.string, required: true)], risk: .high, confirmation: .always, method: .browserAgent)) { args, _ in let id = try Self.required(args, "task_id"); try await managed.cancel(id); return Self.result(.init(taskID: id, status: "cancelled", text: "", tabs: [], downloads: [], screenshots: [], error: "")) }
        try await registry.register(manifest: Self.manifest("browser.import_chrome_profile", "One-time copy of bookmarks, history, and preferences into Nexus's separate profile while Chrome is closed. Passwords, cookies, and Keychain secrets are never extracted.", ["Import safe Chrome state"], ["chrome_profile_root": .init(.string, required: true)], risk: .high, confirmation: .always, method: .nativeAPI)) { args, _ in let copied = try await managed.importProfile(chromeRoot: URL(fileURLWithPath: try Self.required(args, "chrome_profile_root"))); return .object(["display": .string("Imported: \(copied.joined(separator: ", ")). Sign in once where encrypted sessions cannot transfer safely."), "status": .string("completed"), "task_id": .string(""), "text": .string(""), "tabs": .array([]), "downloads": .array([]), "screenshots": .array([]), "error": .string("")]) }
        try await registry.register(manifest: Self.manifest("browser.reset_profile", "Reset only the Nexus-owned browser profile and cancel managed browser tasks.", ["Reset Nexus browser"], [:], risk: .high, confirmation: .always, method: .nativeAPI)) { _, _ in try await managed.reset(); return Self.result(.init(taskID: "", status: "completed", text: "Nexus browser profile reset.", tabs: [], downloads: [], screenshots: [], error: "")) }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "task_id": .init(.string, required: true), "text": .init(.string, required: true), "tabs": .init(.stringArray, required: true), "downloads": .init(.stringArray, required: true), "screenshots": .init(.stringArray, required: true), "error": .init(.string, required: true)])
    private static func required(_ input: [String: NexJSONValue], _ key: String) throws -> String { guard let value = input[key]?.string, !value.isEmpty else { throw NexToolError.missingField(key) }; return value }
    private static func result(_ r: NexBrowserTaskResult) -> NexJSONValue { .object(["display": .string(r.error.isEmpty ? "Browser task \(r.status)." : r.error), "status": .string(r.status), "task_id": .string(r.taskID), "text": .string(r.text), "tabs": .array(r.tabs.map(NexJSONValue.string)), "downloads": .array(r.downloads.map(NexJSONValue.string)), "screenshots": .array(r.screenshots.map(NexJSONValue.string)), "error": .string(r.error)]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never, method: NexComputerImplementationMethod) -> NexComputerActionManifest { .init(actionID: id, application: "Chrome", provider: "Managed Playwright", bundleIdentifier: "com.google.Chrome", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["browser", "chrome", "webpage", "form", "download", "screenshot"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: method, registryPermission: .network, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .application(bundleIdentifier: "com.google.Chrome"), timeoutSeconds: 300, supportsCancellation: true, dryRunBehavior: .supported("Would run \(id) in the separate Nexus browser profile."), previewRenderer: "browser.task", tests: ["NexBrowserActionTests"]) }
}

@MainActor
final class NexChromeTabActionCatalog {
    private let provider: BrowserTabProviding
    private var registered = false
    init() { self.provider = ChromeBrowserTabProvider() }
    init(provider: BrowserTabProviding) { self.provider = provider }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider; let catalog = self
        try await registry.register(manifest: Self.manifest("chrome.open", "Open or activate Google Chrome.", ["Open Chrome"], [:])) { _, _ in try await catalog.openChrome(); return Self.result("Opened Chrome.") }
        try await registry.register(manifest: Self.manifest("chrome.list_tabs", "List every live Chrome tab with stable ID, window/tab position, title, URL, and active state.", ["List my Chrome tabs"], [:])) { _, _ in Self.result("Read Chrome tabs.", tabs: try await provider.listTabs()) }
        try await registry.register(manifest: Self.manifest("chrome.get_active_tab", "Read the currently active Chrome tab.", ["What Chrome tab is active?"], [:])) { _, _ in Self.result("Read the active Chrome tab.", tabs: try await provider.activeTab().map { [$0] } ?? []) }
        try await registry.register(manifest: Self.manifest("chrome.activate_tab", "Activate an existing live Chrome tab by stable tab ID.", ["Switch back to that YouTube tab"], ["tab_id": .init(.string, required: true)])) { args, _ in guard let id = args["tab_id"]?.string else { throw NexToolError.missingField("tab_id") }; try await provider.activate(tabID: id); return Self.result("Activated the Chrome tab.") }
        try await registry.register(manifest: Self.manifest("chrome.open_url", "Open one validated HTTP(S) URL in Chrome.", ["Open this URL in Chrome"], ["url": .init(.string, required: true)], risk: .medium, confirmation: .always)) { args, _ in guard let text = args["url"]?.string, let url = URL(string: text) else { throw NexToolError.executionFailed(code: "unsafe_url", message: "Chrome accepts only HTTP(S) URLs.") }; try await catalog.openURL(url); return Self.result("Opened the URL in Chrome.") }
        try await registry.register(manifest: Self.manifest("chrome.close_tab", "Close one exact live Chrome tab by stable ID.", ["Close that Chrome tab"], ["tab_id": .init(.string, required: true)], risk: .high, confirmation: .always)) { args, _ in
            guard let id = args["tab_id"]?.string else { throw NexToolError.missingField("tab_id") }; try await catalog.closeTab(id: id); return Self.result("Closed the Chrome tab.")
        }
        registered = true
    }
    private func openChrome() async throws { guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { throw BrowserTabProviderError.chromeUnavailable }; let config = NSWorkspace.OpenConfiguration(); config.activates = true; _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config) }
    private func openURL(_ url: URL) throws { guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw NexToolError.executionFailed(code: "unsafe_url", message: "Chrome accepts only HTTP(S) URLs.") }; guard NSWorkspace.shared.open(url) else { throw NexToolError.executionFailed(code: "chrome_open_failed", message: "Chrome could not open the URL.") } }
    private func closeTab(id: String) async throws { let tabs = try await provider.listTabs(); guard let tab = tabs.first(where: { $0.id == id }) else { throw BrowserTabProviderError.tabNotFound }; var error: NSDictionary?; _ = NSAppleScript(source: "tell application \"Google Chrome\" to close tab \(tab.tabIndex) of window \(tab.windowIndex)")?.executeAndReturnError(&error); if let error { throw BrowserTabProviderError.scriptFailed(error.description) } }
    nonisolated private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "tabs": .init(.array, required: true)])
    nonisolated private static func result(_ display: String, tabs: [BrowserTab] = []) -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "tabs": .array(tabs.map { .object(["id": .string($0.id), "window": .number(Double($0.windowIndex)), "tab": .number(Double($0.tabIndex)), "title": .string($0.title), "url": .string($0.url.absoluteString), "active": .bool($0.isActive)]) })]) }
    nonisolated private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never) -> NexComputerActionManifest { .init(actionID: id, application: "Google Chrome", provider: "Chrome AppleScript", bundleIdentifier: "com.google.Chrome", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["chrome", "browser", "tabs", "url"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: .appleScript, requiredPermissions: [.init(id: "automation.com.google.Chrome", permission: .automation)], registryPermission: .automation, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .application(bundleIdentifier: "com.google.Chrome"), timeoutSeconds: 30, supportsCancellation: false, dryRunBehavior: .supported("Would perform \(id) through Chrome's scripting dictionary."), previewRenderer: "chrome.tabs", tests: ["NexBrowserActionTests"]) }
}
