# macOS Share extension for an unsandboxed Developer ID app: fact sheet (2026-11-21)

Sources read 2026-11-21. "DTS" = Quinn "The Eskimo!", Apple DTS. Older, archived: App Extension
Programming Guide (APG, 2017-10-19) and Services Implementation Guide (2016-09-13).

## 1. Must the extension be sandboxed? Which entitlements?

- Yes. "macOS app extensions must have App Sandbox enabled. [...] If you distribute the container app
  directly, you have the option to sandbox it or not." (DTS, Sep 2025)
  https://developer.apple.com/forums/thread/798886
- "In general, all app extensions must be sandboxed"; outside the Mac App Store, temporary exception
  entitlements can bypass most sandbox restrictions. (DTS, Sep 2023)
  https://developer.apple.com/forums/thread/738407
- A sandboxed extension inside a non-sandboxed app is "a common approach used by directly distributed
  apps". (DTS, Mar 2025) https://developer.apple.com/forums/thread/776568
- Minimum entitlements: `com.apple.security.app-sandbox`. Xcode's macOS extension templates also add
  `com.apple.security.files.user-selected.read-only` (APG, 2017).
  https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html
- Add `com.apple.security.application-groups` for a group-container hand-off (Q2a). `com.apple.share-services`
  is a listed NSExtensionPointIdentifier value (developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionpointidentifier).

## 2. Handing the image from the sandboxed extension to the unsandboxed app

(a) App Group container: the documented pattern.
- APG: the extension and its containing app "have no direct access to each other's containers. To enable
  data sharing [...] enable app groups for the containing app and its contained app extensions."
  https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
- App groups work "between sandboxed apps, and between sandboxed and nonsandboxed apps". With the
  `<Team ID>.<group name>` form, "macOS checks that the code signature of processes that try to access
  the app group container contains the same Developer-Team-ID".
  https://developer.apple.com/documentation/xcode/configuring-app-groups
- macOS 15+ app group container protection. Access is silent only if the code claims the group in its
  entitlement and one of these holds: Mac App Store; TestFlight on 15.1+; the group ID starts with the
  Team ID; or a provisioning profile embedded in the app authorizes the claim. Otherwise "the system
  prompts the user", and consent lasts only for that app instance. Developer ID profiles automatically
  authorize `TEAM_ID.*`. Since Feb 2025, `group.` IDs work on macOS for all products, but they need
  profile authorization. (DTS post, revised 2025-08-12) https://developer.apple.com/forums/thread/721701
- The same post: unsandboxed code once needed no claim, but on macOS 15+ "access to the app group
  container requires the entitlement". So the host app must claim the group too.
- `containerURL(forSecurityApplicationGroupIdentifier:)` returns a URL on macOS even for an invalid group;
  test access first. https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)
- Groups also scope Mach/XPC names `<group id>.<name>` and UNIX sockets in the container.
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups

(b) The extension's own container plus asking the host to open the file
- Since macOS 14, an app that reads another app's data container triggers a prompt, but "all apps signed
  with your Team ID can access data in your other app's containers by default, without a permission
  prompt." (WWDC23 10053) https://developer.apple.com/videos/play/wwdc2023/10053/
- Launching the container app from an extension: DTS says "there isn't a supported way to do this"
  (Apr 2025), and "App extensions are not allowed to open URLs directly. This isn't accidental" (Sep 2024).
  Both threads concern iOS (`UIApplication`); no macOS-specific Apple answer was found.
  https://developer.apple.com/forums/thread/779644 · https://developer.apple.com/forums/thread/764570
- `NSExtensionContext.open` exists on macOS 10.10+, but "Each extension point determines whether to support this method"; only iOS Today and iMessage are named. https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)
- Opening a document with `NSWorkspace` from a sandboxed process issues "a sandbox extension to the
  receiving process" for that one file; same-team apps "can share files using an app group container".
  (DTS, Oct–Nov 2026) https://developer.apple.com/forums/thread/852014

(c) NSItemProvider
- `loadFileRepresentation`'s temporary copy is deleted "when the completion handler returns", so copy it
  (for example into the group container) first. `loadInPlaceFileRepresentation` needs `NSFileCoordinator`.
  https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)
  https://developer.apple.com/documentation/foundation/nsitemprovider/loadinplacefilerepresentation(fortypeidentifier:completionhandler:)
- No Apple source found on passing a security-scoped bookmark from a Share extension to its app (unconfirmed).

(d) XPC
- "There is no supported way to directly communicate between apps using XPC." It needs a rendezvous via a
  launchd job visible to both sides (agent, Service Management login item), not an XPC service; it can work
  from Xcode and fail from the Finder. (DTS, Sep 2022) https://developer.apple.com/forums/thread/715338
  The sandboxed side would look up a `<group id>.<name>` Mach service (entitlement doc above).

Apple's recommendation: the only data-sharing mechanism the APG documents for an extension and its
containing app is the app group shared container (a). Apple gives no supported way to launch the
container app from an extension, and it calls direct app-to-app XPC unsupported.

## 3. Developer ID signing, profiles, notarization, Gatekeeper

- `com.apple.security.application-groups`, the App Sandbox entitlements and the Hardened Runtime
  entitlements are unrestricted: no profile needed. Restricted ones such as `keychain-access-groups`
  need one. "A Mac app that uses no restricted entitlements doesn't need a provisioning profile."
  The profile sits at `Contents/embedded.provisionprofile`.
  https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Therefore an appex that claims only app-sandbox plus a Team-ID-prefixed group needs no profile of its
  own. It needs one, for its own App ID, if it claims a `group.` ID (Q2a) or a keychain access group.
  Apple's example ships separate profiles: "The app and the share extension each have their own
  profile", at `Share.appex/Contents/embedded.provisionprofile`.
  https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
- Same page: "If your product is a Mac app bundle, possibly containing nested code such as an app
  extension, that you build using Xcode, use Xcode to export a distribution-signed app." Sign inside out,
  appex before app. The example signs the appex with `--timestamp -o runtime --entitlements Share.entitlements`.
- "Don't pass the `--deep` option to `codesign` when you sign code" (one entitlement set for all items);
  verify with `codesign -vvv --deep --strict` (https://developer.apple.com/documentation/security/resolving-common-notarization-issues).
- Notarization: sign every executable with Developer ID and a timestamp, enable the Hardened Runtime, and
  do not ship `get-task-allow`. Otherwise it fails with "The executable does not have the hardened runtime
  enabled". https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Gatekeeper: outside the Mac App Store, "Gatekeeper prevents the extension from running until the user
  opens and approves the containing app" (APG ExtensionCreation, 2017; older).

## 4. NSExtensionActivationRule for images

- Keys (macOS 10.10+): `NSExtensionActivationSupportsImageWithMaxCount` ("maximum number of image files"),
  `NSExtensionActivationSupportsFileWithMaxCount` ("all types of files", so it also matches non-images),
  plus Movie/Text/WebURL/WebPage/Attachments and `NSExtensionActivationUsesStrictMatching`.
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/nsextensionactivationrule
- For images, use `...SupportsImageWithMaxCount = 1`; for exact control, use a predicate string such as
  `SUBQUERY(extensionItems, $e, SUBQUERY($e.attachments, $a, ANY $a.registeredTypeIdentifiers UTI-CONFORMS-TO "public.image").@count == $e.attachments.@count).@count == 1`
  (pattern from the APG). `TRUEPREDICATE` is for development only.
  https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html

## 5. Visibility in the Share menu and local testing

- Users choose extensions in System Settings > General > Login Items & Extensions > Extensions > By
  Category > Sharing (Info button), or from the Share menu with Edit Extensions. An enabled extension
  appears only for items it can handle. (Apple Support, macOS 27 guide)
  https://support.apple.com/guide/mac-help/change-login-items-extensions-settings-mtusr003/mac ·
  https://support.apple.com/guide/mac-help/use-the-share-menu-on-mac-mh40614/mac
- APG (2017): "you need to perform the user step of enabling an app extension before you can access it".
  Xcode registers the extension only for the debug session, so copy the app to /Applications for a lasting
  install. https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html
- Local `man pluginkit` (this host): `pluginkit -m -v -p com.apple.share-services` lists extensions with
  election prefixes (`+` use, `-` ignore, `=` superseded, `?` unknown); `pluginkit -e use|ignore|default
  -i <bundle id>` sets the election; `-a`/`-r <path>` add or remove a registration "during plug-in development".

## 6. Alternative: the Services menu (NSServices)

- Declare `NSMessage` (selector `<name>:userData:error:`), `NSPortName`, `NSSendTypes` (pasteboard types or
  UTIs) and/or `NSSendFileTypes` (UTIs only; the service receives file URLs), `NSMenuItem`, and always
  `NSRequiredContext`. Without `NSRequiredContext` the service is registered but not shown in the menu.
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html
- Provide it with `NSApp.servicesProvider` (one per app); refresh with `NSUpdateDynamicServices()`;
  `/System/Library/CoreServices/pbs` is for debugging only; an /Applications app needs a re-login to register.
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html
- Neither guide page (2016) mentions a sandbox or entitlement requirement for the provider; `NSRestricted`
  only warns when a sandboxed app invokes a restricted service.
- Location: `servicesProvider` serves "the Services menu of other apps"
  (https://developer.apple.com/documentation/appkit/nsapplication/servicesprovider); the Share menu lists
  sharing services/extensions (https://developer.apple.com/documentation/appkit/nssharingservicepicker).

## Unconfirmed

1. Whether a new third-party Share extension starts enabled on macOS 15/26 (only the 2017 APG says a user
   step is required; current Support pages are silent).
2. Whether a sandboxed macOS Share extension may launch its container app (`NSWorkspace` open/openApplication,
   custom URL scheme, `extensionContext.open`). Apple answers found are iOS-only and say "not supported";
   assume unsupported and test on 26.x before relying on it.
3. That a service never appears in the Share menu (inferred from AppKit docs); Finder Quick Actions unchecked.
4. That an NSServices provider needs no entitlement on macOS 26 (inferred from the docs' silence).
5. That the unsandboxed host reads the appex's own container without a prompt (WWDC23 same-team rule; untested).
6. That notarization requires the Hardened Runtime on the appex itself (Apple says "app and command line
   targets"; inferred from the per-executable error and Apple's `-o runtime` appex signing example).
