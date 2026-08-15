import AppKit
import CryptoKit
import Foundation

struct NexBrowserTaskResult: Codable, Sendable {
    let taskID: String
    let status: String
    let text: String
    let tabs: [String]
    let downloads: [String]
    let screenshots: [String]
    let error: String
}

/// This action is intentionally routed without model inference. “Play
/// something” has a complete interaction contract: use the visible Nexus
/// browser, play the first result, and keep it playing.
enum NexusYouTubeVoiceIntent {
    struct Request: Equatable, Sendable {
        let query: String?
    }

    static func request(in prompt: String) -> Request? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard !trimmed.isEmpty else { return nil }
        let genericPhrases = ["play something", "play a video", "play youtube", "open youtube", "start youtube", "put on youtube"]
        if genericPhrases.contains(where: normalized.contains) {
            return .init(query: nil)
        }
        let requestPrefix: String
        if normalized.hasPrefix("play "), normalized.count > "play ".count {
            requestPrefix = "play "
        } else if normalized.hasPrefix("put on "), normalized.count > "put on ".count {
            requestPrefix = "put on "
        } else {
            return nil
        }
        var query = String(trimmed.dropFirst(requestPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for suffix in [
            " on youtube",
            " in youtube",
            " in the nexus browser",
            " on the nexus browser",
            " for me",
            " and make it fill the screen",
            " and make it fullscreen",
            " and show it full screen",
            " and show it fullscreen",
            " and go full screen",
            " in full screen",
            " full screen"
        ] {
            if query.lowercased().hasSuffix(suffix) {
                query = String(query.dropLast(suffix.count))
            }
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !query.isEmpty, !["it", "that", "this", "current video"].contains(query.lowercased()) else { return nil }
        return .init(query: query)
    }
}

actor NexManagedBrowserProvider {
    private struct TaskRun {
        let taskID: String
        let process: Process
        let stdout: Pipe
    }

    private let root: URL
    private let chromeIsRunning: @Sendable () -> Bool
    private var processes: [String: Process] = [:]
    private var results: [String: NexBrowserTaskResult] = [:]
    private var cancelledTaskIDs: Set<String> = []
    init(root: URL? = nil, chromeIsRunning: @escaping @Sendable () -> Bool = {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.google.Chrome" }
    }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nexus/Browser", isDirectory: true)
        self.chromeIsRunning = chromeIsRunning
    }

    /// Starts a managed browser task without waiting for its final browser
    /// result. The returned UUID is usable immediately by `status` and
    /// `cancel`, while the collector continues to persist the final evidence.
    func start(goal: String, stepsJSON: String, visible: Bool = false, keepOpen: Bool = false, progress: @escaping @Sendable (String) async -> Void) async throws -> NexBrowserTaskResult {
        let task = try await launch(goal: goal, stepsJSON: stepsJSON, visible: visible, keepOpen: keepOpen)
        Task { _ = await self.collect(task, progress: progress) }
        return .init(taskID: task.taskID, status: "running", text: "", tabs: [], downloads: [], screenshots: [], error: "")
    }

    /// Playback has a visible completion point. Do not report success until
    /// the browser has actually selected a video and entered full screen.
    func startPlayback(goal: String, stepsJSON: String, progress: @escaping @Sendable (String) async -> Void) async throws -> NexBrowserTaskResult {
        let task = try await launch(goal: goal, stepsJSON: stepsJSON, visible: true, keepOpen: true)
        Task { _ = await self.collect(task, progress: progress) }
        for _ in 0..<1_200 { // two minutes, sampled every 100 ms
            if let result = results[task.taskID] {
                if result.status == "playing" { return result }
                if result.status == "failed" || result.status == "cancelled" {
                    throw NexToolError.executionFailed(
                        code: "youtube_playback_failed",
                        message: result.error.isEmpty ? "YouTube did not begin playback." : result.error
                    )
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try? cancel(task.taskID)
        throw NexToolError.executionFailed(
            code: "youtube_playback_timeout",
            message: "YouTube did not reach visible playback within two minutes. Nexus left the browser task stopped rather than claiming it played."
        )
    }

    func run(goal: String, stepsJSON: String, visible: Bool = false, progress: @escaping @Sendable (String) async -> Void) async throws -> NexBrowserTaskResult {
        let task = try await launch(goal: goal, stepsJSON: stepsJSON, visible: visible, keepOpen: false)
        return await collect(task, progress: progress)
    }

    private func launch(goal: String, stepsJSON: String, visible: Bool, keepOpen: Bool) async throws -> TaskRun {
        guard let stepsData = stepsJSON.data(using: .utf8), (try? JSONSerialization.jsonObject(with: stepsData)) is [Any] else { throw NexToolError.executionFailed(code: "invalid_browser_steps", message: "Browser steps must be a JSON array.") }
        let profileIsOpen = FileManager.default.fileExists(atPath: root.appendingPathComponent("Profile/SingletonLock").path)
        guard !profileIsOpen else {
            throw NexToolError.executionFailed(
                code: "nexus_browser_profile_in_use",
                message: "Nexus browser is still open. Quit only the separate Nexus browser window, then run again. Your signed-in session is saved and will be reused automatically."
            )
        }
        let taskID = UUID().uuidString.lowercased(), runtime = try await ensureRuntime(), taskRoot = root.appendingPathComponent("tasks/\(taskID)", isDirectory: true); try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        let request: [String: Any] = ["taskID": taskID, "goal": goal, "steps": try JSONSerialization.jsonObject(with: stepsData), "profile": root.appendingPathComponent("Profile").path, "taskRoot": taskRoot.path, "chrome": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "visible": visible, "keepOpen": keepOpen]
        let input = try JSONSerialization.data(withJSONObject: request)
        let process = Process(), stdin = Pipe(), stdout = Pipe(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node"); process.arguments = [runtime.appendingPathComponent("agent.mjs").path]; process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stdout; processes[taskID] = process; try process.run(); try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        let running = NexBrowserTaskResult(taskID: taskID, status: "running", text: "", tabs: [], downloads: [], screenshots: [], error: "")
        results[taskID] = running
        return .init(taskID: taskID, process: process, stdout: stdout)
    }

    private func collect(_ task: TaskRun, progress: @escaping @Sendable (String) async -> Void) async -> NexBrowserTaskResult {
        let taskID = task.taskID
        var final = NexBrowserTaskResult(taskID: taskID, status: "running", text: "", tabs: [], downloads: [], screenshots: [], error: "")
        do {
            for try await line in task.stdout.fileHandleForReading.bytes.lines { guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }; let event = json["event"] as? String; if event == "browser_foreground_request", let pid = json["pid"] as? Int32, pid > 0 { await MainActor.run { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]) } }; if event == "media_ready" { final = .init(taskID: taskID, status: "playing", text: json["text"] as? String ?? "", tabs: json["tabs"] as? [String] ?? [], downloads: [], screenshots: [], error: ""); results[taskID] = final; try? persist(final) }; if let event, event != "completed" { await progress((json["message"] as? String) ?? event) }; if event == "completed" { final = .init(taskID: taskID, status: json["status"] as? String ?? "completed", text: json["text"] as? String ?? "", tabs: json["tabs"] as? [String] ?? [], downloads: json["downloads"] as? [String] ?? [], screenshots: json["screenshots"] as? [String] ?? [], error: json["error"] as? String ?? "") } }
        } catch { task.process.terminate() }
        task.process.waitUntilExit(); processes[taskID] = nil
        let cancelled = cancelledTaskIDs.remove(taskID) != nil
        if cancelled {
            final = .init(taskID: taskID, status: "cancelled", text: "", tabs: [], downloads: [], screenshots: [], error: "")
        } else if task.process.terminationStatus != 0, ["running", "playing"].contains(final.status) {
            final = .init(taskID: taskID, status: "failed", text: "", tabs: [], downloads: [], screenshots: [], error: "Managed browser process exited \(task.process.terminationStatus).")
        }
        results[taskID] = final; try? persist(final); return final
    }
    func status(_ id: String) -> NexBrowserTaskResult? { results[id] ?? (processes[id] != nil ? .init(taskID: id, status: "running", text: "", tabs: [], downloads: [], screenshots: [], error: "") : persistedResult(id)) }
    func cancel(_ id: String) throws { guard let process = processes[id], process.isRunning else { throw NexToolError.executionFailed(code: "browser_task_missing", message: "Browser task is not running.") }; cancelledTaskIDs.insert(id); process.terminate(); processes[id] = nil; let cancelled = NexBrowserTaskResult(taskID: id, status: "cancelled", text: "", tabs: [], downloads: [], screenshots: [], error: ""); results[id] = cancelled; try persist(cancelled) }
    func cancelAll() {
        let activeProcesses = processes
        for (id, process) in activeProcesses where process.isRunning {
            cancelledTaskIDs.insert(id)
            process.terminate()
            processes[id] = nil
            let cancelled = NexBrowserTaskResult(taskID: id, status: "cancelled", text: "", tabs: [], downloads: [], screenshots: [], error: "")
            results[id] = cancelled
            try? persist(cancelled)
        }
    }
    func importProfile(chromeRoot: URL) throws -> [String] {
        guard !chromeIsRunning() else { throw NexToolError.executionFailed(code: "chrome_must_close", message: "Quit Chrome before importing browser state.") }
        let source = chromeRoot.appendingPathComponent("Default"), destination = root.appendingPathComponent("Profile/Default"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true); var copied: [String] = []
        for name in ["Bookmarks", "History", "Preferences"] { let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name); guard FileManager.default.fileExists(atPath: from.path) else { continue }; try? FileManager.default.removeItem(at: to); try FileManager.default.copyItem(at: from, to: to); copied.append(name) }
        return copied
    }
    /// Opens a separate, persistent Chrome profile owned by Nexus. This is the
    /// only supported place to sign in to private web services for managed
    /// browser tasks; macOS-encrypted cookies and passwords are never copied
    /// out of the user's normal Chrome profile.
    func openProfileForSignIn() throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chrome.path) else {
            throw NexToolError.executionFailed(code: "chrome_unavailable", message: "Google Chrome is required for Nexus's managed browser.")
        }
        let profile = root.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = chrome
        // Pin the launch to the exact profile the runner owns.  Starting on
        // Gmail (rather than a blank tab) makes it unambiguous which Chrome
        // window must be signed into, and avoids a successful sign-in being
        // performed in the user's normal Chrome profile by mistake.
        process.arguments = [
            "--user-data-dir=\(profile.path)",
            "--profile-directory=Default",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-mode",
            "--new-window",
            "https://mail.google.com/mail/u/0/#inbox"
        ]
        try process.run()
    }
    func reset() throws { cancelledTaskIDs.formUnion(processes.keys); for process in processes.values { process.terminate() }; processes.removeAll(); try? FileManager.default.removeItem(at: root.appendingPathComponent("Profile")); try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile"), withIntermediateDirectories: true) }

    /// Browser actions may be started and inspected by separate `nex-computer`
    /// invocations.  Keep the final, non-secret task result beside the task's
    /// screenshots and downloads so `browser.get_task` remains useful after
    /// the originating CLI process exits.
    private func persist(_ result: NexBrowserTaskResult) throws {
        guard let taskDirectory = taskDirectory(for: result.taskID) else { return }
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(result)
        try encoded.write(to: taskDirectory.appendingPathComponent("result.json"), options: .atomic)
    }

    private func persistedResult(_ id: String) -> NexBrowserTaskResult? {
        guard let taskDirectory = taskDirectory(for: id),
              let data = try? Data(contentsOf: taskDirectory.appendingPathComponent("result.json")) else { return nil }
        return try? JSONDecoder().decode(NexBrowserTaskResult.self, from: data)
    }

    private func taskDirectory(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return root.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent(id.lowercased(), isDirectory: true)
    }

    private func ensureRuntime() async throws -> URL {
        let runtime = root.appendingPathComponent("Runtime", isDirectory: true), module = runtime.appendingPathComponent("node_modules/playwright-core")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: module.path) {
            guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npm") else { throw NexToolError.executionFailed(code: "npm_unavailable", message: "Managed Playwright provisioning requires the installed npm executable.") }
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/npm"); process.arguments = ["install", "--prefix", runtime.path, "--no-audit", "--no-fund", "playwright-core@1.55.0"]
            // `npm` launches Node through `/usr/bin/env`. Xcode's sanitized
            // process environment omits Homebrew's bin directory, so make the
            // managed runtime self-contained rather than requiring Terminal.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = environment
            process.standardOutput = pipe; process.standardError = pipe; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NexToolError.executionFailed(code: "playwright_install_failed", message: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Playwright provisioning failed.") }
        }
        let script = runtime.appendingPathComponent("agent.mjs")
        // The runtime directory persists across app updates. Refresh this
        // Nexus-owned script whenever its bundled implementation changes so
        // new supported steps are not documented before they are executable.
        if (try? String(contentsOf: script, encoding: .utf8)) != Self.script {
            try Self.script.write(to: script, atomically: true, encoding: .utf8)
        }
        return runtime
    }

    private static let script = #"""
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright-core';
const request = JSON.parse(fs.readFileSync(0, 'utf8'));
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
let context; const downloads = [], screenshots = [], extracted = [];
try {
  emit({event:'started',message:'Starting secure browser…'});
  // The sign-in window and an automation run deliberately share this one
  // Nexus-owned user-data directory.  Playwright normally adds
  // `--password-store=basic` and `--use-mock-keychain` to Chrome.  Those
  // flags prevent the automation process from reading the real macOS
  // Keychain-encrypted cookies which Chrome saved during interactive sign-in,
  // making Gmail appear logged out after the window is quit.  Let Chrome use
  // its normal Keychain integration for this persistent, local-only profile.
  context = await chromium.launchPersistentContext(request.profile,{
    headless:request.visible !== true,
    executablePath:request.chrome,
    acceptDownloads:true,
    args:['--disable-background-mode'],
    ignoreDefaultArgs:['--password-store=basic','--use-mock-keychain']
  });
  emit({event:'progress',message:'Using saved Nexus browser session…'});
  let page = context.pages()[0] || await context.newPage();
  page.on('download', async download => { const target=`${request.taskRoot}/${download.suggestedFilename()}`; await download.saveAs(target); downloads.push(target); emit({event:'download',message:`Downloaded ${download.suggestedFilename()}`}); });
  for (const [index,step] of request.steps.entries()) {
    emit({event:'progress',message:step.label || `${step.action} ${index+1}/${request.steps.length}`});
    switch(step.action) {
      case 'navigate': await page.goto(step.url,{waitUntil:'domcontentloaded',timeout:30000}); break;
      case 'new_tab': page=await context.newPage(); if(step.url) await page.goto(step.url,{waitUntil:'domcontentloaded'}); break;
      case 'activate_tab': { const pages=context.pages(); if(!pages[step.index]) throw new Error('Tab index unavailable'); page=pages[step.index]; await page.bringToFront(); break; }
      case 'close_tab': await page.close(); page=context.pages()[0] || await context.newPage(); break;
      case 'click': {
        const locator=page.locator(step.selector);
        await (step.first === true ? locator.first() : locator).click();
        break;
      }
      case 'bring_to_front': {
        await page.bringToFront();
        const pid=Number((execFileSync('/bin/ps',['-axo','pid=,command='],{encoding:'utf8'})
          .split('\n')
          .find(line=>line.includes(`--user-data-dir=${request.profile}`) && line.includes('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')) || '')
          .trim().split(/\s+/,1)[0]) || 0;
        emit({event:'browser_foreground_request',pid,message:'Bringing the Nexus browser window forward'});
        break;
      }
      // A wait only establishes that the page has rendered at least one
      // matching element. `locator.waitFor` is strict, so waiting on Gmail's
      // many rows or Calendar's many event chips throws before extraction.
      // Extract still deliberately reads every match below.
      case 'wait_for_element': await page.locator(step.selector).first().waitFor({state:step.state || 'visible',timeout:step.timeout || 30000}); break;
      case 'type': await page.locator(step.selector).fill(step.text || ''); break;
      case 'form': for(const field of step.fields || []) await page.locator(field.selector).fill(field.value); if(step.submitSelector) await page.locator(step.submitSelector).click(); break;
      case 'extract': {
        const locator=page.locator(step.selector || 'body');
        // `innerText` on a multi-match locator only returns one element. That
        // made Gmail and Calendar look successful while handing the briefing
        // only an arbitrary first row or page chrome. Preserve every matched
        // row/event as individually delimited evidence.
        const count=await locator.count();
        if(count===0) throw new Error(`No readable elements matched ${step.selector || 'body'}`);
        const values=[];
        for(let item=0;item<count;item++) {
          const text=(await locator.nth(item).innerText({timeout:15000})).trim();
          if(text) values.push(text);
        }
        if(values.length===0) throw new Error(`Matched ${count} elements but none had readable text for ${step.selector || 'body'}`);
        extracted.push(values.join('\n--- Nexus source item ---\n'));
        break;
      }
      case 'upload': await page.locator(step.selector).setInputFiles(step.paths || []); break;
      case 'download': await Promise.all([page.waitForEvent('download'),page.locator(step.selector).click()]); break;
      case 'screenshot': {
        // Playwright infers its encoder from the filename extension. Models
        // naturally supply labels such as "results" rather than "results.png",
        // so normalize to a task-local PNG instead of failing with a null MIME
        // type. Sanitizing to a basename also prevents a supplied label from
        // escaping Nexus's per-task evidence directory.
        const requested = String(step.name || `shot-${index}.png`);
        const safeBase = requested.replace(/[^A-Za-z0-9._-]/g, '_').replace(/^_+/, '') || `shot-${index}`;
        const filename = /\.(png|jpe?g|webp)$/i.test(safeBase) ? safeBase : `${safeBase}.png`;
        const target=`${request.taskRoot}/${filename}`;
        await page.screenshot({path:target,fullPage:step.fullPage ?? step.full_page ?? true});
        screenshots.push(target);
        break;
      }
      case 'skip_youtube_ad': {
        // This only presses YouTube's own, visibly rendered Skip control. It
        // never blocks, mutes, fast-forwards, or otherwise bypasses an ad.
        const minimumWait=Math.max(0,Number(step.minimumWaitMs || 5000));
        const deadline=Date.now()+Math.max(minimumWait,Number(step.timeout || 90000));
        await page.waitForTimeout(minimumWait);
        while(Date.now()<deadline) {
          const skip=page.locator('button.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button').first();
          if(await skip.isVisible().catch(()=>false)) {
            await skip.click();
            emit({event:'progress',message:'Pressed YouTube’s visible Skip button.'});
            break;
          }
          const adShowing=await page.locator('.ad-showing').count().catch(()=>0);
          if(!adShowing) break;
          await page.waitForTimeout(500);
        }
        break;
      }
      case 'youtube_start_first_visible': {
        // A fresh YouTube profile can show consent before its feed. Only use
        // the site's visible control, then select a real watch link from its
        // current home/search layouts.
        const consent=page.locator('button:has-text("Accept all"), button:has-text("Accept the use"), button:has-text("I agree")').first();
        if(await consent.isVisible().catch(()=>false)) {
          await consent.click();
          emit({event:'progress',message:'Accepted YouTube’s visible consent screen.'});
          await page.waitForTimeout(800);
        }
        const selectors=[
          'ytd-rich-grid-media a#thumbnail[href*="/watch"]',
          'ytd-rich-item-renderer a#thumbnail[href*="/watch"]',
          'ytd-video-renderer a#thumbnail[href*="/watch"]',
          'a#thumbnail[href*="/watch"]',
          'a[href^="/watch?v="]'
        ];
        let selected;
        for(const selector of selectors) {
          const candidate=page.locator(selector).first();
          if(await candidate.isVisible({timeout:9000}).catch(()=>false)) { selected=candidate; break; }
        }
        if(!selected) throw new Error('YouTube loaded but no visible playable video was found. Nexus did not claim playback.');
        await selected.click();
        await page.waitForURL(/(?:youtube\.com)?\/watch\?/, {timeout:30000}).catch(async()=>{
          const player=page.locator('#movie_player, video.html5-main-video').first();
          if(!await player.isVisible().catch(()=>false)) throw new Error('The first YouTube item did not open a playable watch page.');
        });
        emit({event:'progress',message:'Started the first visible YouTube video.'});
        break;
      }
      case 'youtube_fullscreen': {
        const fullscreen=page.locator('button.ytp-fullscreen-button').first();
        await fullscreen.waitFor({state:'visible',timeout:30000});
        await fullscreen.click();
        emit({event:'progress',message:'Entering YouTube full screen.'});
        break;
      }
      case 'schoology_check': {
        const schoologyURL=step.url || 'https://fuhsd.schoology.com/';
        await page.goto(schoologyURL,{waitUntil:'domcontentloaded',timeout:30000});
        const beginSchoologySSO=async()=>{
          const controls=page.locator('button:has-text("Google"), a:has-text("Google"), button:has-text("Log in"), a:has-text("Log in"), button:has-text("Sign in"), a:has-text("Sign in")');
          const count=await controls.count();
          for(let i=0;i<count;i++) {
            const control=controls.nth(i);
            if(await control.isVisible().catch(()=>false)) {
              await control.click();
              await page.waitForTimeout(800);
              return true;
            }
          }
          return false;
        };
        const chooseAccount=async()=>{
          const accounts=page.locator('[data-identifier]');
          const count=await accounts.count();
          if(count===0) return false;
          const requested=String(step.schoolEmail || '').trim().toLowerCase();
          const matches=[];
          for(let i=0;i<count;i++) {
            const account=accounts.nth(i);
            const email=(await account.getAttribute('data-identifier').catch(()=>'' ) || '').trim().toLowerCase();
            if(email && (requested ? email===requested : /@(?:[a-z0-9-]+\\.)*fuhsd\\.org$/.test(email))) matches.push(account);
          }
          if(matches.length===1) { await matches[0].click(); return true; }
          if(requested) throw new Error(`The saved Google account ${requested} is not available in the Nexus browser profile. Open Nexus browser and sign in to that exact school account once.`);
          if(matches.length>1) throw new Error('More than one FUHSD Google account is signed in. Set the exact school email for this request so Nexus can choose safely.');
          throw new Error('Nexus could not identify a signed-in FUHSD school account. Open Nexus browser, sign in to the school Google account once, then try again.');
        };
        let initialText=(await page.locator('body').innerText({timeout:15000})).trim();
        if(!new URL(page.url()).hostname.includes('google.com') && /(?:^|\\n)\s*(sign in|log in)\b/i.test(initialText)) {
          emit({event:'progress',message:'Following Schoology’s existing sign-in path…'});
          await beginSchoologySSO();
        }
        if(new URL(page.url()).hostname.includes('google.com')) {
          await chooseAccount();
          await page.waitForLoadState('domcontentloaded',{timeout:30000}).catch(()=>{});
        }
        const text=(await page.locator('body').innerText({timeout:15000})).trim();
        const url=page.url();
        if(new URL(url).hostname.includes('google.com') || /(?:^|\\n)\s*(sign in|log in)\b/i.test(text)) {
          throw new Error('Schoology still requires sign-in. Nexus will not enter a password or MFA code; open the Nexus browser profile, complete the sign-in once, then retry.');
        }
        const upcoming=page.locator('[class*="upcoming" i], [id*="upcoming" i], [data-testid*="upcoming" i]');
        const count=await upcoming.count();
        const items=[];
        for(let item=0;item<count;item++) {
          const value=(await upcoming.nth(item).innerText().catch(()=>'' )).trim();
          if(value) items.push(value);
        }
        const evidence=items.length>0 ? items.join('\\n--- Nexus Schoology item ---\\n') : text;
        if(!/upcoming|assignment|course|grade/i.test(evidence)) {
          throw new Error('Schoology opened, but Nexus could not locate a readable upcoming-assignments area. It will not report that there are no assignments without live page evidence.');
        }
        extracted.push(`Live Schoology evidence from ${url}:\\n${evidence}`);
        break;
      }
      case 'hold_open': {
        await page.bringToFront();
        emit({event:'media_ready',message:'YouTube is playing in the frontmost Nexus browser window.',text:'YouTube is playing in the frontmost Nexus browser window.',tabs:context.pages().map(p=>p.url())});
        // Keep this one media session alive so the visible, Nexus-owned
        // browser remains on screen and continues playback. Cancellation or
        // closing the browser ends it; ordinary browser tasks still close.
        await new Promise(()=>{});
        break;
      }
      default: throw new Error(`Unsupported browser step: ${step.action}`);
    }
  }
  emit({event:'completed',status:'completed',text:extracted.join('\n\n').slice(0,100000),tabs:context.pages().map(p=>p.url()),downloads,screenshots,error:''});
} catch(error) { emit({event:'completed',status:'failed',text:extracted.join('\n\n'),tabs:context?.pages().map(p=>p.url()) || [],downloads,screenshots,error:String(error?.message || error)}); process.exitCode=1; }
finally { await context?.close(); }
"""#
}

actor NexBrowserActionCatalog {
    private let managed: NexManagedBrowserProvider; private var registered = false
    init(managed: NexManagedBrowserProvider = NexManagedBrowserProvider()) { self.managed = managed }
    func cancelAll() async { await managed.cancelAll() }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let managed = managed
        try await registry.register(manifest: Self.manifest("browser.visit_url", "Visit one HTTP(S) page in Nexus's separate managed browser profile and return readable page evidence so Nex can answer Sir's request from the page. Use this for a simple explicit request to open, visit, or inspect one URL. For clicks, forms, uploads, downloads, or multiple pages use browser.run_task.", ["Use Nexus browser to inspect https://example.com", "Visit this page and tell me what it says"], ["url": .init(.string, required: true)], risk: .medium, confirmation: .never, method: .browserAgent)) { args, context in
            let url = try Self.validHTTPURL(try Self.required(args, "url"))
            let steps = try Self.pageVisitSteps(url: url)
            let result = try await managed.run(goal: "Visit \(url.host ?? url.absoluteString) and extract its readable page text.", stepsJSON: steps) { await context.reportProgress($0, nil) }
            return Self.result(result)
        }
        try await registry.register(manifest: Self.manifest("browser.run_task", "Start a bounded Playwright task in Nexus's separate persistent browser profile and return its stable task ID while it runs. Use it for an agentic, multi-step website workflow: navigate pages, wait for elements, click controls, fill forms, extract evidence, download or upload files, or take a full-page screenshot. Supply structured steps, not a JSON string. Set visible only for a site that cannot be read in background browser mode; it opens the Nexus browser window.", ["Take a full-page screenshot of this website", "Research this site and extract the results", "Fill this form but do not submit without confirmation", "Wait for a page element before continuing"], ["goal": .init(.string, required: true), "steps": .init(.array, description: "Structured array of browser step objects. Supported actions: navigate, new_tab, activate_tab, close_tab, click, type, form, extract, upload, download, wait_for_element, screenshot."), "visible": .init(.boolean, description: "Open the Nexus browser window for compatibility with a site that rejects background browser mode."), "steps_json": .init(.string, description: "Legacy JSON-encoded browser step array. Use steps instead for new calls.", deprecated: true)], risk: .high, confirmation: .always, method: .browserAgent, aliases: ["wait for an element on a page", "watch a webpage condition"], tags: ["wait", "element", "selector", "page condition"])) { args, context in let result = try await managed.start(goal: try Self.required(args, "goal"), stepsJSON: try Self.stepsJSON(args), visible: args["visible"]?.bool ?? false) { await context.reportProgress($0, nil) }; return Self.result(result) }
        try await registry.register(manifest: Self.manifest(
            "browser.play_youtube",
            "Play a requested YouTube video through Nexus's signed-in managed browser. This is the one browser action that intentionally brings the Nexus browser to the foreground and keeps it open while media plays. It opens YouTube, clicks the first visible video result, uses only YouTube's own visible Skip button after five seconds when one is offered, then presses YouTube's normal full-screen control; it never bypasses ads.",
            ["Play something for me on YouTube", "Play lo-fi beats in Nexus browser", "Open YouTube and play a video"],
            ["query": .init(.string, required: false, description: "Optional music, video, or search request. Omit only when the user asks for any first video from YouTube home.")],
            risk: .medium,
            confirmation: .never,
            method: .browserAgent,
            aliases: ["play something for me", "play this on youtube", "open youtube and play", "play music in nexus browser"],
            tags: ["youtube", "play", "video", "music", "visible browser"]
        )) { args, context in
            let query = args["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await managed.startPlayback(
                goal: query?.isEmpty == false ? "Play the first YouTube result for \(query!)." : "Play the first visible YouTube video.",
                stepsJSON: try Self.youtubePlaybackSteps(query: query)
            ) { await context.reportProgress($0, nil) }
            return Self.result(result)
        }
        try await registry.register(manifest: Self.manifest(
            "browser.check_schoology",
            "Read live upcoming Schoology assignments through Nexus's managed browser. It uses an already signed-in school Google session only; it never enters passwords or MFA. When no school_email is supplied, it safely chooses exactly one signed-in @fuhsd.org account and otherwise fails with a specific sign-in/account-selection message rather than inventing assignments.",
            ["Check Schoology", "What upcoming assignments do I have in Schoology?", "Check my school homework"],
            ["school_email": .init(.string, required: false, description: "Optional exact FUHSD Google address. Omit only when exactly one signed-in @fuhsd.org account exists in the Nexus browser profile.")],
            risk: .medium,
            confirmation: .never,
            method: .browserAgent,
            aliases: ["check schoology", "check my schoology", "school homework", "upcoming school assignments"],
            tags: ["schoology", "school", "assignments", "homework", "fuhsd"]
        )) { args, context in
            let schoolEmail = args["school_email"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await managed.run(
                goal: "Read live upcoming assignments from the user's signed-in Schoology dashboard.",
                stepsJSON: try Self.schoologyCheckSteps(schoolEmail: schoolEmail),
                visible: false
            ) { await context.reportProgress($0, nil) }
            return Self.result(result)
        }
        try await registry.register(manifest: Self.manifest("browser.get_task", "Read a managed browser task by stable ID.", ["Check that browser task"], ["task_id": .init(.string, required: true)], method: .browserAgent)) { args, _ in guard let result = await managed.status(try Self.required(args, "task_id")) else { throw NexToolError.executionFailed(code: "browser_task_missing", message: "Browser task was not found.") }; return Self.result(result) }
        try await registry.register(manifest: Self.manifest("browser.cancel_task", "Cancel a running managed browser task.", ["Cancel the browser task"], ["task_id": .init(.string, required: true)], risk: .high, confirmation: .always, method: .browserAgent)) { args, _ in let id = try Self.required(args, "task_id"); try await managed.cancel(id); return Self.result(.init(taskID: id, status: "cancelled", text: "", tabs: [], downloads: [], screenshots: [], error: "")) }
        try await registry.register(manifest: Self.manifest("browser.import_chrome_profile", "One-time copy of bookmarks, history, and preferences from the default Chrome profile into Nexus's separate profile while Chrome is closed. Passwords, cookies, and Keychain secrets are never extracted. The source root is optional and defaults to ~/Library/Application Support/Google/Chrome.", ["Import my safe Chrome browser data into Nexus"], ["chrome_profile_root": .init(.string, required: false)], risk: .high, confirmation: .always, method: .nativeAPI)) { args, _ in
            let source = args["chrome_profile_root"]?.string.map { URL(fileURLWithPath: $0) } ?? Self.defaultChromeRoot
            let copied = try await managed.importProfile(chromeRoot: source)
            return .object(["display": .string("Imported: \(copied.joined(separator: ", ")). Sign in once in the Nexus browser for private sites; encrypted sessions are never copied."), "status": .string("completed"), "task_id": .string(""), "text": .string(""), "tabs": .array([]), "downloads": .array([]), "screenshots": .array([]), "error": .string("")])
        }
        try await registry.register(manifest: Self.manifest("browser.open_profile", "Open Nexus's separate persistent Chrome profile so Sir can sign in once to private sites. Its session stays local to Nexus and is reused by future managed-browser tasks.", ["Open the Nexus browser so I can sign in to Notion", "Let me sign in to a website in Nexus browser"], [:], risk: .medium, confirmation: .never, method: .nativeAPI)) { _, _ in
            try await managed.openProfileForSignIn()
            return Self.result(.init(taskID: "", status: "completed", text: "Opened the separate Nexus browser profile directly at Gmail. Sign in there once, open Google Calendar and Fidelity in that same window if needed, then use Command-Q to quit the separate Nexus Chrome app. The saved session is reused automatically; simply closing a window does not quit Chrome on macOS.", tabs: [], downloads: [], screenshots: [], error: ""))
        }
        try await registry.register(manifest: Self.manifest("browser.reset_profile", "Reset only the Nexus-owned browser profile and cancel managed browser tasks.", ["Reset Nexus browser"], [:], risk: .high, confirmation: .always, method: .nativeAPI)) { _, _ in try await managed.reset(); return Self.result(.init(taskID: "", status: "completed", text: "Nexus browser profile reset.", tabs: [], downloads: [], screenshots: [], error: "")) }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "task_id": .init(.string, required: true), "text": .init(.string, required: true), "tabs": .init(.stringArray, required: true), "downloads": .init(.stringArray, required: true), "screenshots": .init(.stringArray, required: true), "error": .init(.string, required: true)])
    private static let defaultChromeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    private static func required(_ input: [String: NexJSONValue], _ key: String) throws -> String { guard let value = input[key]?.string, !value.isEmpty else { throw NexToolError.missingField(key) }; return value }
    private static func stepsJSON(_ input: [String: NexJSONValue]) throws -> String {
        if let steps = input["steps"]?.array {
            let data = try JSONEncoder().encode(steps)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NexToolError.executionFailed(code: "invalid_browser_steps", message: "Browser steps could not be encoded.")
            }
            return json
        }
        return try required(input, "steps_json")
    }
    private static func validHTTPURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw NexToolError.executionFailed(code: "unsafe_url", message: "Nexus browser accepts only complete HTTP(S) URLs.")
        }
        return url
    }
    private static func pageVisitSteps(url: URL) throws -> String {
        let steps: [[String: String]] = [
            ["action": "navigate", "url": url.absoluteString, "label": "Opening \(url.host ?? url.absoluteString)"],
            ["action": "extract", "selector": "body", "label": "Reading the page"]
        ]
        return String(data: try JSONSerialization.data(withJSONObject: steps), encoding: .utf8) ?? "[]"
    }
    nonisolated static func youtubePlaybackSteps(query: String?) throws -> String {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let destination: String
        if trimmed.isEmpty {
            destination = "https://www.youtube.com/"
        } else {
            var components = URLComponents(string: "https://www.youtube.com/results")!
            components.queryItems = [.init(name: "search_query", value: trimmed)]
            destination = components.url!.absoluteString
        }
        let steps: [[String: Any]] = [
            ["action": "navigate", "url": destination, "label": "Opening YouTube in the Nexus browser"],
            ["action": "bring_to_front", "label": "Bringing Nexus browser forward"],
            ["action": "youtube_start_first_visible", "label": "Starting the first visible video"],
            ["action": "skip_youtube_ad", "minimumWaitMs": 5_000, "timeout": 90_000, "label": "Waiting for YouTube playback"],
            ["action": "youtube_fullscreen", "label": "Entering YouTube full screen"],
            ["action": "hold_open", "label": "Keeping YouTube open and playing"]
        ]
        return String(data: try JSONSerialization.data(withJSONObject: steps), encoding: .utf8) ?? "[]"
    }
    nonisolated static func schoologyCheckSteps(schoolEmail: String?) throws -> String {
        let email = schoolEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let steps: [[String: Any]] = [[
            "action": "schoology_check",
            "url": "https://fuhsd.schoology.com/",
            "schoolEmail": email,
            "label": "Checking live upcoming Schoology assignments"
        ]]
        return String(data: try JSONSerialization.data(withJSONObject: steps), encoding: .utf8) ?? "[]"
    }
    private static func result(_ r: NexBrowserTaskResult) -> NexJSONValue { .object(["display": .string(r.error.isEmpty ? "Browser task \(r.status)." : r.error), "status": .string(r.status), "task_id": .string(r.taskID), "text": .string(r.text), "tabs": .array(r.tabs.map(NexJSONValue.string)), "downloads": .array(r.downloads.map(NexJSONValue.string)), "screenshots": .array(r.screenshots.map(NexJSONValue.string)), "error": .string(r.error)]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never, method: NexComputerImplementationMethod, aliases additionalAliases: [String] = [], tags additionalTags: [String] = []) -> NexComputerActionManifest { .init(actionID: id, application: "Chrome", provider: "Managed Playwright", bundleIdentifier: "com.google.Chrome", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")] + additionalAliases, tags: ["browser", "chrome", "webpage", "form", "download", "screenshot"] + additionalTags, inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: method, registryPermission: .network, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .application(bundleIdentifier: "com.google.Chrome"), timeoutSeconds: 300, supportsCancellation: true, dryRunBehavior: .supported("Would run \(id) in the separate Nexus browser profile."), previewRenderer: "browser.task", tests: ["NexBrowserActionTests"]) }
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
        try await registry.register(manifest: Self.manifest("chrome.open_url", "Open one validated HTTP(S) URL in Chrome.", ["Open this URL in Chrome"], ["url": .init(.string, required: true)], risk: .medium, confirmation: .never)) { args, _ in guard let text = args["url"]?.string, let url = URL(string: text) else { throw NexToolError.executionFailed(code: "unsafe_url", message: "Chrome accepts only HTTP(S) URLs.") }; try await catalog.openURL(url); return Self.result("Opened the URL in Chrome.") }
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
