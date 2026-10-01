import Domain
import Features
import Foundation
import Imaging

/// User-visible names for editor values. Every string lives in the "Editor" table
/// (Editor.xcstrings) with English and pt-BR translations.
enum EditorStrings {
    static func name(_ tool: EditorTool) -> String {
        switch tool {
        case .select: String(localized: "Select", table: "Editor")
        case .hand: String(localized: "Pan", table: "Editor")
        case .crop: String(localized: "Crop", table: "Editor")
        case .text: String(localized: "Text", table: "Editor")
        case .arrow: String(localized: "Arrow", table: "Editor")
        case .rectangle: String(localized: "Rectangle", table: "Editor")
        case .ellipse: String(localized: "Ellipse", table: "Editor")
        case .freehand: String(localized: "Pen", table: "Editor")
        case .highlighter: String(localized: "Highlighter", table: "Editor")
        case .step: String(localized: "Numbered Step", table: "Editor")
        case .redact: String(localized: "Redact (secure, solid)", table: "Editor")
        case .blur: String(localized: "Blur (cosmetic, not secure)", table: "Editor")
        case .pixelate: String(localized: "Pixelate (cosmetic, not secure)", table: "Editor")
        case .spotlight: String(localized: "Spotlight", table: "Editor")
        case .magnifier: String(localized: "Magnifier", table: "Editor")
        case .loupe: String(localized: "Loupe", table: "Editor")
        case .ruler: String(localized: "Ruler", table: "Editor")
        case .colorPicker: String(localized: "Color Picker", table: "Editor")
        }
    }

    static func symbol(_ tool: EditorTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .crop: "crop"
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .step: "1.circle"
        case .redact: "rectangle.fill"
        case .blur: "drop"
        case .pixelate: "square.grid.3x3"
        case .spotlight: "light.max"
        case .magnifier: "plus.magnifyingglass"
        case .loupe: "scope"
        case .ruler: "ruler"
        case .colorPicker: "eyedropper"
        }
    }

    /// Tooltip: the name plus its single-key shortcut.
    static func help(_ tool: EditorTool) -> String {
        let key = String(tool.shortcutKey).uppercased()
        return String(localized: "\(name(tool)) (\(key))", table: "Editor")
    }

    static func name(_ kind: EditorItemKind) -> String {
        switch kind {
        case .text: String(localized: "Text", table: "Editor")
        case .arrow: String(localized: "Arrow", table: "Editor")
        case .rectangle: String(localized: "Rectangle", table: "Editor")
        case .ellipse: String(localized: "Ellipse", table: "Editor")
        case .freehand: String(localized: "Drawing", table: "Editor")
        case .highlighter: String(localized: "Highlight", table: "Editor")
        case .step: String(localized: "Step", table: "Editor")
        case .image: String(localized: "Image", table: "Editor")
        case .redaction: String(localized: "Redaction", table: "Editor")
        case .blur: String(localized: "Blur", table: "Editor")
        case .pixelate: String(localized: "Pixelation", table: "Editor")
        case .spotlight: String(localized: "Spotlight", table: "Editor")
        case .magnifier: String(localized: "Magnifier", table: "Editor")
        }
    }

    static func symbol(_ kind: EditorItemKind) -> String {
        switch kind {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .step: "1.circle"
        case .image: "photo"
        case .redaction: "rectangle.fill"
        case .blur: "drop"
        case .pixelate: "square.grid.3x3"
        case .spotlight: "light.max"
        case .magnifier: "plus.magnifyingglass"
        }
    }

    /// "Arrow 2", or "Step 3" using the step's own number.
    static func label(_ item: EditorListItem) -> String {
        if let number = item.stepNumber {
            return String(localized: "Step \(number)", table: "Editor")
        }
        return String(localized: "\(name(item.kind)) \(item.ordinal)", table: "Editor")
    }

    /// Text badge so security never depends on color or icon alone (RED-04, UX-01).
    static func securityBadge(_ kind: EditorItemKind) -> String? {
        if kind.isSecure { return String(localized: "Secure", table: "Editor") }
        if kind.isCosmetic { return String(localized: "Not secure", table: "Editor") }
        return nil
    }

    static func name(_ mode: OCRTextMode) -> String {
        switch mode {
        case .raw: String(localized: "Exact", table: "Editor")
        case .normalizedWhitespace: String(localized: "Single Line", table: "Editor")
        case .preserveLineBreaks: String(localized: "Keep Line Breaks", table: "Editor")
        }
    }

    static func name(_ alignment: EditorAlignment) -> String {
        switch alignment {
        case .left: String(localized: "Align Left", table: "Editor")
        case .horizontalCenter: String(localized: "Align Centers Horizontally", table: "Editor")
        case .right: String(localized: "Align Right", table: "Editor")
        case .top: String(localized: "Align Top", table: "Editor")
        case .verticalCenter: String(localized: "Align Centers Vertically", table: "Editor")
        case .bottom: String(localized: "Align Bottom", table: "Editor")
        }
    }

    static func symbol(_ alignment: EditorAlignment) -> String {
        switch alignment {
        case .left: "align.horizontal.left"
        case .horizontalCenter: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .verticalCenter: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }

    static func payloadKind(_ kind: QRPayload.Kind) -> String {
        switch kind {
        case .text: String(localized: "Text", table: "Editor")
        case .webURL: String(localized: "Web link", table: "Editor")
        case .otherScheme(let scheme): String(localized: "Link (\(scheme)), not opened by Recortia", table: "Editor")
        case .wifi: String(localized: "Wi-Fi settings, not applied by Recortia", table: "Editor")
        case .payment: String(localized: "Payment request, not opened by Recortia", table: "Editor")
        case .binary: String(localized: "Binary data", table: "Editor")
        }
    }

    /// Nonblocking status text. Content-free: never includes recognized text, payloads, or paths.
    static func message(_ notice: EditorNotice) -> String {
        switch notice {
        case .noTextFound: String(localized: "No text found. The clipboard was not changed.", table: "Editor")
        case .recognitionLanguagesUnavailable:
            String(
                localized:
                    "Text recognition for English or Portuguese is not available on this Mac, so other languages were used.",
                table: "Editor")
        case .textCopied: String(localized: "Text copied.", table: "Editor")
        case .copyFailed: String(localized: "Could not copy the text.", table: "Editor")
        case .recognitionFailed: String(localized: "Recognition failed.", table: "Editor")
        case .recognitionDiscarded:
            String(localized: "The image changed during recognition. Run it again.", table: "Editor")
        case .recognitionInvalidated:
            String(localized: "The image changed, so earlier results were cleared.", table: "Editor")
        case .noQRCodeFound: String(localized: "No QR code found.", table: "Editor")
        case .payloadCopied: String(localized: "QR content copied.", table: "Editor")
        case .linkNotAllowed: String(localized: "Only web links (http or https) can be opened.", table: "Editor")
        case .colorCopied: String(localized: "Color copied.", table: "Editor")
        case .previewNotReady: String(localized: "The preview is updating. Try again in a moment.", table: "Editor")
        case .previewFailed: String(localized: "The preview could not be rendered.", table: "Editor")
        case .redactionRefused:
            String(
                localized: "This redaction cannot be mapped onto the image safely, so it was not added.",
                table: "Editor")
        case .importFailed(let failure): importMessage(failure)
        case .pinned: String(localized: "Pinned.", table: "Editor")
        case .pinFailed(let error):
            switch error {
            case .limitReached: String(localized: "You can keep up to 5 pins. Close one first.", table: "Editor")
            case .memoryBudgetExceeded:
                String(localized: "The pins already use their memory budget. Close a pin first.", table: "Editor")
            case .renderFailed: String(localized: "The pin could not be rendered.", table: "Editor")
            case .staleDocument: String(localized: "The image changed while pinning. Try again.", table: "Editor")
            }
        case .pinsInvalidated(let count):
            String(localized: "Redactions changed, so \(count) older pins were closed.", table: "Editor")
        case .exported(let outcome): exportMessage(outcome)
        case .noPreferredFolder:
            String(localized: "No save folder is set. Choose one in Settings › Export.", table: "Editor")
        case .undoHistoryTrimmed:
            String(localized: "The oldest undo steps were discarded to limit memory use.", table: "Editor")
        }
    }

    /// "Not available on this Mac: English, Portuguese" with language names in the user's locale.
    static func unavailableLanguages(_ codes: [String]) -> String {
        let names = codes.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        let list = ListFormatter.localizedString(byJoining: names)
        return String(localized: "Not available on this Mac: \(list)", table: "Editor")
    }

    static func importMessage(_ failure: ImportFailure) -> String {
        switch failure {
        case .busy:
            String(localized: "Another image is still being opened. Try again when it finishes.", table: "Editor")
        case .cancelled: String(localized: "Opening the image was canceled.", table: "Editor")
        case .nothingToPaste: String(localized: "The clipboard does not contain a PNG or JPEG image.", table: "Editor")
        case .tooLarge: String(localized: "The file is larger than 64 MB.", table: "Editor")
        case .tooManyPixels: String(localized: "The image is larger than 40 megapixels.", table: "Editor")
        case .invalidDimensions: String(localized: "The image has invalid dimensions.", table: "Editor")
        case .unsupportedFormat: String(localized: "Only PNG and JPEG images are supported.", table: "Editor")
        case .multipleFrames: String(localized: "Animated or multi-page images are not supported.", table: "Editor")
        case .corrupt: String(localized: "The image data is damaged.", table: "Editor")
        case .unreadable: String(localized: "The file could not be read.", table: "Editor")
        }
    }

    static func exportMessage(_ outcome: ExportOutcome) -> String {
        switch outcome {
        case .copied: String(localized: "Image copied.", table: "Editor")
        case .saved: String(localized: "Image saved.", table: "Editor")
        case .dragged: String(localized: "Image delivered.", table: "Editor")
        case .uploaded: String(localized: "Image uploaded to GitHub.", table: "Editor")
        case .alreadyCompleted:
            String(localized: "The export had already finished and cannot be undone.", table: "Editor")
        case .canceled: String(localized: "Export canceled. Nothing was written.", table: "Editor")
        case .rejectedBusy: String(localized: "Another export is still running.", table: "Editor")
        case .failed(let failure): exportFailure(failure)
        }
    }

    static func exportFailure(_ failure: ExportFailure) -> String {
        switch failure {
        case .busy: String(localized: "Automatic export was skipped because another export is still running.")
        case .upload(let failure): GitHubUploadStrings.message(failure)
        case .renderFailed, .encodeFailed:
            String(localized: "Nothing was exported: the image could not be rendered.", table: "Editor")
        case .budgetExceeded: String(localized: "Nothing was exported: the image is too large.", table: "Editor")
        case .clipboardFailed:
            String(localized: "The image could not be copied.", table: "Editor")
        case .accessDenied:
            String(localized: "Nothing was saved: Recortia cannot write to that folder.", table: "Editor")
        case .destinationExists: String(localized: "Nothing was saved: a file with that name exists.", table: "Editor")
        case .diskFull: String(localized: "Nothing was saved: the disk is full.", table: "Editor")
        case .volumeUnavailable: String(localized: "Nothing was saved: the volume is not available.", table: "Editor")
        case .staleDocument:
            String(localized: "Nothing was exported: the image changed meanwhile. Try again.", table: "Editor")
        case .system(let code):
            String(localized: "Nothing was exported: the system reported error \(code).", table: "Editor")
        }
    }
}
