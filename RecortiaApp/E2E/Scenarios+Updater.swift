#if DEBUG
    import AppKit
    import Features
    import MacPlatform

    /// Check for Updates… (FP-024) through the real menu command, `AppModel` and message path, with
    /// the synthetic updater: no network, no Sparkle window. The key-absent state that hides the
    /// entry points is covered by the package tests, because this runner's updater is synthetic.
    @MainActor
    enum UpdaterScenarios {
        static func updater(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            let updater = app.features.updater
            let updates = harness.updates
            let messages = harness.messages
            let portuguese = context.output.language.hasPrefix("pt")

            context.check(
                "the runner's Info.plist carries no update key or feed, so no live updater could start",
                !SparkleUpdateService.isConfigured(Bundle.main.infoDictionary))
            context.check(
                "launch started the updater once, with automatic checks off", updates.starts == [false],
                "\(updates.starts)")
            context.check(
                "Check for Updates is offered and enabled", updater.isOffered && app.isEnabled(.checkForUpdates))
            context.check(
                "automatic checks are off and nothing was asked yet",
                !updater.checksAutomatically && updates.checks == 0, "\(updates.checks) checks")
            context.check(
                "the menu item is localized",
                AppCommand.checkForUpdates.title == (portuguese ? "Buscar atualizações…" : "Check for Updates…"),
                AppCommand.checkForUpdates.title)

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            for (result, expected, title) in [
                (
                    UpdateCheckResult.noUpdate, UserMessage.updateNotFound(version: version),
                    portuguese ? "O Recortia está atualizado" : "Recortia is up to date"
                ),
                (
                    .failed, .updateCheckFailed,
                    portuguese ? "Não foi possível buscar atualizações" : "Could not check for updates"
                ),
            ] {
                updates.result = result
                let start = messages.requests.count
                app.perform(.checkForUpdates)
                let shown = await E2EWait.until { messages.requests.count > start }
                let request = messages.requests.last
                context.check(
                    "\(result) is reported as an app alert",
                    shown && messages.requests.count == start + 1 && request?.isSheet == false
                        && request?.message == expected,
                    "\(String(describing: request?.message))")
                context.check("\(result) has a localized title", request?.message.title == title)
            }

            updates.result = .updateAvailable(version: "99.0")
            let alertsBefore = messages.requests.count
            messages.answers = [false]
            app.perform(.checkForUpdates)
            let asked = await E2EWait.until { messages.confirmations.count == 1 }
            let question = messages.confirmations.last
            context.check(
                "an update found asks before opening the updater window, naming the version",
                asked && question == .updateAvailable(version: "99.0")
                    && question?.title
                        == (portuguese ? "O Recortia 99.0 está disponível" : "Recortia 99.0 is available"),
                "\(String(describing: question))")
            context.check(
                "Later opens nothing", updates.installs == 0 && messages.requests.count == alertsBefore,
                "\(updates.installs) installs")
            messages.answers = [true]
            app.perform(.checkForUpdates)
            context.check(
                "Show Update opens the updater window once",
                await E2EWait.until { updates.installs == 1 } && messages.confirmations.count == 2)
            context.check("each press asked the updater exactly once", updates.checks == 4, "\(updates.checks)")

            updater.setChecksAutomatically(true)
            context.check(
                "turning automatic checks on stores the choice and tells the updater, without a check",
                harness.settings.preferences.checksForUpdatesAutomatically && updates.automatic == [true]
                    && updates.checks == 4)
            updater.setChecksAutomatically(false)
            context.check(
                "turning them off again is stored and passed on",
                !harness.settings.preferences.checksForUpdatesAutomatically && updates.automatic == [true, false])
        }
    }
#endif
