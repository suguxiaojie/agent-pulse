import AppKit
import SwiftUI

@MainActor enum IslandMascotTests {
    static func run() {
        var checks = 0
        func expect(_ value: Bool, _ title: String) { precondition(value, title); checks += 1 }
        var row = ActivitySessionSnapshot(sessionID: "mascot", turnID: "turn", projectID: "p", projectName: "P",
            title: "private title", phase: .starting, actionText: "", updatedAt: Date(), tokenUsage: nil)
        for (phase, mood): (TaskPhase, IslandMascotMood) in [(.starting, .think), (.working, .think), (.usingTool, .tool),
            (.waitingApproval, .approve), (.completed, .done), (.failed, .fail), (.ended, .idle)] {
            row.phase = phase
            expect(IslandMascotMood.mood(for: row) == mood, "phase maps to mascot mood")
            expect(IslandMascotMood.mood(for: row.hidingDetails()) == mood, "privacy preserves mood")
        }
        row.phase = .waitingApproval; row.waitReason = .userInput
        expect(IslandMascotMood.mood(for: row) == .reply, "user input is reply")
        row.endReason = .cancelled
        expect(IslandMascotMood.mood(for: row) == .idle, "cancellation takes priority")
        expect(IslandMascotMood.mood(for: nil) == .idle, "no session is idle")
        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
        func gaze(_ point: CGPoint) -> CGSize { IslandMascotGeometry.gazeOffset(pointer: point, islandRect: rect) }
        expect(gaze(CGPoint(x: 60, y: 40)) == .zero, "center has zero gaze")
        expect(gaze(CGPoint(x: 80, y: 40)).width > 0, "inside point tracks")
        let edge = gaze(CGPoint(x: 350, y: 40))
        expect(abs(edge.width - 3.15) < 0.001 && edge.height == 0, "240 pt boundary is included and clamped")
        expect(gaze(CGPoint(x: 350.01, y: 40)) == .zero, "outside 240 pt resets gaze")
        let diagonal = gaze(CGPoint(x: 200, y: 200))
        expect(hypot(diagonal.width, diagonal.height) <= 3.15001 && diagonal.height < 0, "vector clamped and screen Y inverted")
        expect(IslandMascotGeometry.gazeOffset(pointer: .zero, islandRect: .zero) == .zero, "invalid geometry resets gaze")
        let model = ActivityIslandViewModel()
        let context = model.mascotContext
        row.phase = .completed; row.endReason = .completed; row.waitReason = nil
        context.noteCompletion(row, serial: 1, playable: true)
        expect(context.claimCompletion(row, serial: 1), "completion serial triggers once")
        let rebuilt = NSHostingView(rootView: IslandSessionMascot(row: row, size: 20, animated: true, reduceMotion: false)
            .environment(\.islandMascotContext, context).environment(\.islandMascotSerial, 1))
        _ = rebuilt.fittingSize
        expect(!context.claimCompletion(row, serial: 1), "view reconstruction cannot replay completion")
        context.noteCompletion(row, serial: 2, playable: false)
        expect(!context.claimCompletion(row, serial: 2), "hidden or reduced-motion completion consumed without playback")
        row.isRetainedReceipt = true
        context.noteCompletion(row, serial: 3, playable: true)
        expect(!context.claimCompletion(row, serial: 3), "retained receipt never bounces")
        row.isRetainedReceipt = false; row.phase = .waitingApproval; row.endReason = nil; row.waitReason = .userInput
        row.replyRequestIDs = ["question"]
        expect(model.claimReplyCue(for: row) && context.claimReply(row), "mascot uses original request cue")
        expect(!model.claimReplyCue(for: row) && !context.claimReply(row), "same reply request never replays")
        row.replyRequestIDs = ["next-question"]
        expect(model.claimReplyCue(for: row) && context.claimReply(row), "new request can animate")
        expect(context.claimFailure(row) && !context.claimFailure(row), "failure shakes only once per turn")
        context.update(visible: true, reduceMotion: true, islandRect: rect)
        expect(!context.enabled && context.monitorCount == 0, "Reduce Motion installs no mouse monitors")
        context.update(visible: false, reduceMotion: false, islandRect: rect)
        expect(context.monitorCount == 0, "hidden island installs no monitors")
        context.update(visible: true, reduceMotion: false, islandRect: rect)
        expect(context.enabled && context.monitorCount > 0, "visible island installs local mouse tracking")
        context.update(visible: false, reduceMotion: false, islandRect: rect)
        expect(!context.enabled && context.monitorCount == 0 && context.gaze == .zero, "hide removes all monitors and clears gaze")
        func orbs(_ view: NSView) -> [RippleGlowHostView] {
            (view as? RippleGlowHostView).map { [$0] } ?? view.subviews.flatMap(orbs)
        }
        let moods: [IslandMascotMood] = [.think, .tool, .approve, .reply, .done, .fail, .idle]
        for mood in moods {
            let host = NSHostingView(rootView: IslandMascotView(mood: mood, size: 26, animated: false, reduceMotion: true))
            host.frame = CGRect(x: 0, y: 0, width: 26, height: 26); host.layoutSubtreeIfNeeded()
            expect(orbs(host).isEmpty, "card Clawd draws pixels without a RippleGlow host")
        }

        // Sprite: feet stay anchored at y = 0 for every pose and squash.
        for mood in moods {
            for arms: IslandClawdPose.Arms in [.side, .up, .down, .hang, .oneLeft, .oneRight, .oneWave] {
                for squash: CGFloat in [0.6, 0.97, 1] {
                    var pose = IslandClawdPose(mood: mood, arms: arms); pose.squashY = squash
                    let pixels = IslandClawdSprite.pixels(pose)
                    expect(pixels.allSatisfy { $0.rect.maxY <= 0.0001 }, "sprite never extends below the feet")
                    expect(pose.legsTucked || abs((pixels.map(\.rect.maxY).max() ?? 1)) < 0.0001, "legs reach the feet line")
                    expect(pixels.allSatisfy { $0.rect.minX >= -5.6 && $0.rect.maxX <= 5.6 }, "sprite stays 11 pixels wide")
                }
            }
        }
        expect(IslandClawdPose(mood: .idle).legsTucked && IslandClawdPose(mood: .idle).eyes == .closed, "idle sleeps with tucked legs")
        expect(IslandClawdPose(mood: .fail).eyes == .cross && IslandClawdPose(mood: .done).eyes == .happy, "terminal eyes")
        expect(!IslandClawdSprite.pixels(IslandClawdPose(mood: .approve)).contains { $0.ink == .glint }, "pixel-art eyes carry no glint")

        for height: CGFloat in [32, 37, 40] {
            model.metrics = ActivityIslandPanelMetrics(rowCount: 1, availableSize: CGSize(width: 1200, height: 800), safeAreaTop: height)
            for size in IslandClawdSize.allCases {
                model.clawdSize = size
                expect(model.compactClawdPixel <= size.pixel, "compact pixel never exceeds preference")
                expect(model.compactClawdPixel * 12 <= height - 4, "entire badge grid fits with two-point margins")
                expect(model.floatingUsageCompactOffset == 24, "badge requires no hanging clearance")
            }
        }
        for state: IslandClawdBadgeState in [.idle, .start, .think, .tool, .approve, .reply, .done, .fail] {
            let images = IslandClawdBadgeRenderer.images(state, pixel: 2.2, scale: 2, gaze: 0)
            expect(!images.isEmpty, "every clip renders")
            expect(images.count == IslandClawdBadgeClips.clip(state).frames.count, "every frame is retained")
            expect(IslandClawdBadgeRenderer.stillImage(state, pixel: 2.2, scale: 2) != nil, "static expression renders")
        }
        // Codex pet: same states, same frame contract, its own art; the provider decides which pet appears.
        for state: IslandClawdBadgeState in [.idle, .start, .think, .tool, .approve, .reply, .done, .fail] {
            let codex = IslandClawdBadgeRenderer.images(state, pixel: 2.2, scale: 2, gaze: 0, species: .codex)
            expect(codex.count == IslandCodexClips.clip(state).frames.count, "every Codex frame renders")
            expect(IslandClawdBadgeRenderer.stillImage(state, pixel: 2.2, scale: 2, species: .codex) != nil, "Codex expression renders")
            expect(IslandCodexClips.clip(state).duration > 0, "Codex clip has a duration")
            let clawdFirst = IslandClawdBadgeRenderer.images(state, pixel: 2.2, scale: 2, gaze: 0).first
            expect(clawdFirst?.dataProvider?.data as Data? != codex.first?.dataProvider?.data as Data?, "Codex art differs from Clawd")
        }
        expect(IslandClawdBadgeRenderer.timing(.start, species: .codex).duration == IslandClawdBadgeRenderer.timing(.start, species: .clawd).duration,
               "both pets hand off from start to work at the same moment")
        expect(IslandPetSpecies(provider: "Codex") == .codex && IslandPetSpecies(provider: "Claude Code") == .clawd
               && IslandPetSpecies(provider: "Grok CLI") == .grok
               && IslandPetSpecies(provider: "Antigravity") == .antigravity, "provider picks the pet")
        // Grok Bot: its own art for every state, the same start hand-off as the other pets.
        for state: IslandClawdBadgeState in [.idle, .start, .think, .tool, .approve, .reply, .done, .fail] {
            let grok = IslandClawdBadgeRenderer.images(state, pixel: 2.2, scale: 2, gaze: 0, species: .grok)
            expect(grok.count == IslandGrokClips.clip(state).frames.count, "every Grok frame renders")
            expect(IslandClawdBadgeRenderer.stillImage(state, pixel: 2.2, scale: 2, species: .grok) != nil, "Grok expression renders")
            let codexFirst = IslandClawdBadgeRenderer.images(state, pixel: 2.2, scale: 2, gaze: 0, species: .codex).first
            expect(grok.first?.dataProvider?.data as Data? != codexFirst?.dataProvider?.data as Data?, "Grok art differs from Codex")

            let agy = IslandClawdBadgeRenderer.images(state, pixel: 2.2, scale: 2, gaze: 0, species: .antigravity)
            expect(agy.count == IslandAntigravityClips.clip(state).frames.count, "every Antigravity frame renders")
            expect(IslandClawdBadgeRenderer.stillImage(state, pixel: 2.2, scale: 2, species: .antigravity) != nil, "Antigravity expression renders")
            expect(agy.first?.dataProvider?.data as Data? != grok.first?.dataProvider?.data as Data?, "Antigravity art differs from Grok")
        }
        expect(IslandClawdBadgeRenderer.timing(.start, species: .grok).duration == IslandClawdBadgeRenderer.timing(.start, species: .clawd).duration,
               "Grok hands off from start to work with the other pets")
        expect(IslandClawdBadgeRenderer.timing(.start, species: .antigravity).duration == IslandClawdBadgeRenderer.timing(.start, species: .clawd).duration,
               "Antigravity hands off from start to work with the other pets")
        let grokBadge = IslandClawdBadgeView(frame: .zero)
        grokBadge.apply(mood: .approve, pixel: 2.2, gaze: 0, reduceMotion: true, playing: true, species: .grok)
        expect(grokBadge.shown == .approve && grokBadge.species == .grok, "badge shows the Grok pet")
        let petModel = ActivityIslandViewModel()
        expect(petModel.idlePetSpecies == .codex, "idle defaults to the Codex pet before Claude Code is seen")
        var claudeRow = ActivitySessionSnapshot(sessionID: "pet-claude", turnID: "t", projectID: "p", projectName: "P",
            title: "Claude", phase: .working, actionText: "", updatedAt: Date(), tokenUsage: nil)
        claudeRow.provider = "Claude Code"
        let codexRow = ActivitySessionSnapshot(sessionID: "pet-codex", turnID: "t", projectID: "p", projectName: "P",
            title: "Codex", phase: .working, actionText: "", updatedAt: Date().addingTimeInterval(-60), tokenUsage: nil)
        petModel.sessions = [codexRow, claudeRow]
        expect(petModel.idlePetSpecies == .clawd, "idle follows the most recently active client")
        petModel.sessions = []
        expect(petModel.idlePetSpecies == .clawd, "idle keeps the last active pet once sessions clear")

        // Idle mascot and top-left quota percentage sync with the last finished agent across all providers.
        let syncModel = ActivityIslandViewModel()
        let syncNow = Date()
        let codexBucket = RateLimitBucket(
            id: "codex", name: "Codex", planType: "plus",
            primary: RateLimitWindow(usedPercent: 28, windowDurationMinutes: 300, resetsAt: syncNow.addingTimeInterval(3600)),
            secondary: nil, creditBalance: nil, hasCredits: false
        )
        syncModel.quotaState = .loaded([codexBucket], syncNow)
        syncModel.updateClaudeEnabled(true)
        syncModel.claudeStatusLineEnabled = true
        syncModel.claudeLimits = .init(
            fiveHour: .init(usedPercent: 12, resetsAt: syncNow.addingTimeInterval(7200)),
            sevenDay: .init(usedPercent: 30, resetsAt: syncNow.addingTimeInterval(86400)),
            capturedAt: syncNow
        )
        syncModel.grokEnabled = true
        syncModel.grokQuota = GrokQuotaSnapshot(
            usedPercent: 5, startsAt: nil, resetsAt: syncNow.addingTimeInterval(3600),
            periodType: "weekly", plan: "SuperGrok", prepaidCents: nil,
            sharedPool: true, capturedAt: syncNow
        )
        syncModel.antigravityEnabled = true
        syncModel.antigravityStatusLineEnabled = true
        syncModel.antigravityQuota = AntigravityQuotaSnapshot(
            windows: [
                AntigravityQuotaWindow(id: "gemini_pro", title: "Gemini", remainingPercent: 64, usedPercent: 36,
                    durationMinutes: 300, resetsAt: syncNow.addingTimeInterval(7200), sortPriority: 0),
                AntigravityQuotaWindow(id: "claude", title: "Claude", remainingPercent: 82, usedPercent: 18,
                    durationMinutes: 300, resetsAt: syncNow.addingTimeInterval(7200), sortPriority: 1)
            ],
            planTier: "pro", aiCredits: nil, useG1Credits: nil, capturedAt: syncNow
        )
        func makeRow(_ id: String, provider: String, phase: TaskPhase, at: Date, retained: Bool = false) -> ActivitySessionSnapshot {
            var item = ActivitySessionSnapshot(sessionID: id, turnID: "turn-\(id)", projectID: "p", projectName: "P",
                title: provider, phase: phase, actionText: "", updatedAt: at, tokenUsage: nil)
            item.provider = provider
            item.isRetainedReceipt = retained
            if !phase.isActive { item.endReason = phase == .completed ? .completed : phase == .failed ? .failed : .ended }
            return item
        }
        // 1) Codex finishes first -> idle shows Codex pet & 72%.
        let t1 = syncNow.addingTimeInterval(-30)
        syncModel.sessions = [makeRow("c1", provider: "Codex", phase: .working, at: t1)]
        let codexDone = makeRow("c1", provider: "Codex", phase: .completed, at: t1.addingTimeInterval(2))
        syncModel.sessions = [codexDone]
        expect(syncModel.idleProvider == .codex && syncModel.idlePetSpecies == .codex && syncModel.compactQuotaPercent == "72%",
               "Codex completion syncs idle pet and quota")
        // 2) Claude starts running while Codex receipt stays: idleProvider waits until Claude finishes.
        let t2 = syncNow.addingTimeInterval(-20)
        syncModel.sessions = [codexDone, makeRow("cl1", provider: "Claude Code", phase: .working, at: t2)]
        expect(syncModel.idleProvider == .codex, "running task does not prematurely overwrite last finished agent")
        // 3) Claude finishes -> idle syncs to Claude (Clawd + 88%), even if older Codex stays after Claude expires.
        let claudeDone = makeRow("cl1", provider: "Claude Code", phase: .completed, at: t2.addingTimeInterval(5))
        syncModel.sessions = [codexDone, claudeDone]
        expect(syncModel.idleProvider == .claude && syncModel.idlePetSpecies == .clawd && syncModel.compactQuotaPercent == "88%",
               "Claude completion syncs idle pet and Claude remaining quota")
        syncModel.sessions = [codexDone]
        expect(syncModel.idleProvider == .claude && syncModel.compactQuotaPercent == "88%",
               "older retained Codex receipt never reverts newer Claude idle state")
        syncModel.sessions = []
        expect(syncModel.idleProvider == .claude && syncModel.idlePetSpecies == .clawd && syncModel.compactQuotaPercent == "88%",
               "pure idle keeps last finished Claude pet and quota")
        // 4) Grok finishes -> syncs to Grok Bot + 95%.
        let t3 = syncNow.addingTimeInterval(-10)
        syncModel.sessions = [makeRow("g1", provider: "Grok CLI", phase: .working, at: t3)]
        syncModel.sessions = [makeRow("g1", provider: "Grok CLI", phase: .completed, at: t3.addingTimeInterval(2))]
        syncModel.sessions = []
        expect(syncModel.idleProvider == .grok && syncModel.idlePetSpecies == .grok && syncModel.compactQuotaPercent == "95%",
               "Grok completion syncs idle pet and Grok quota")
        // 5) Antigravity finishes -> syncs to Antigravity pet + 64% (minimum active window).
        let t4 = syncNow.addingTimeInterval(-5)
        syncModel.sessions = [makeRow("a1", provider: "Antigravity", phase: .working, at: t4)]
        syncModel.sessions = [makeRow("a1", provider: "Antigravity", phase: .completed, at: t4.addingTimeInterval(2))]
        syncModel.sessions = []
        expect(syncModel.idleProvider == .antigravity && syncModel.idlePetSpecies == .antigravity && syncModel.compactQuotaPercent == "64%",
               "Antigravity completion syncs idle pet and Antigravity quota")
        syncModel.privacyMode = true
        expect(syncModel.compactQuotaPercent == "—", "privacy hides non-Codex idle quota")
        syncModel.privacyMode = false
        // 6) Restoring persisted idle provider resists older retained baseline rows and falls back when disabled.
        let restored = ActivityIslandViewModel()
        restored.antigravityEnabled = true
        restored.antigravityStatusLineEnabled = true
        restored.antigravityQuota = syncModel.antigravityQuota
        restored.restoreIdleProvider(.antigravity, finishedAt: t4.addingTimeInterval(2))
        restored.sessions = [makeRow("old-codex", provider: "Codex", phase: .completed, at: t1, retained: true)]
        expect(restored.idleProvider == .antigravity && restored.compactQuotaPercent == "64%",
               "restored idle provider resists older baseline retained receipt")
        restored.antigravityEnabled = false
        expect(restored.idleProvider == .codex && restored.idlePetSpecies == .codex,
               "disabling current idle provider falls back to Codex")
        let codexBadge = IslandClawdBadgeView(frame: .zero)
        codexBadge.apply(mood: .tool, pixel: 2.2, gaze: 0, reduceMotion: true, playing: true, species: .codex)
        expect(codexBadge.shown == .tool && codexBadge.species == .codex, "badge shows the Codex pet")
        let badge = IslandClawdBadgeView(frame: .zero)
        badge.apply(mood: .think, pixel: 2.2, gaze: 0, reduceMotion: true, playing: true)
        expect(badge.shown == .think, "reduced motion skips start reaction")
        badge.apply(mood: .reply, pixel: 2.2, gaze: 0, reduceMotion: false, playing: false)
        expect(badge.shown == .reply, "hidden badge keeps current expression")

        let mascotSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexNotchMonitor/ActivityIslandMascot.swift")
        let source = try! String(contentsOf: mascotSource, encoding: .utf8)
        expect(!source.contains("RippleGlowOrb("), "mascot implementation does not reference the old orb")
        expect(!source.contains("TimelineView("), "card expressions have no frame clock")
        print("Island mascot: \(checks)/\(checks) passed")
    }
}
