import SwiftUI
import StrandDesign
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Trends Report Renderer
//
// Renders a `TrendsReportPage` (a plain SwiftUI view) to a single-page PDF on-device and hands it to
// `FileExport`. No network. Uses SwiftUI's `ImageRenderer`, drawing into a PDF-consumer `CGContext`
// for a crisp vector PDF on both platforms from one code path.

enum TrendsReportRenderer {

    /// Renders `page` to a one-page PDF and presents the share sheet / save panel via `FileExport`.
    /// Main actor (ImageRenderer touches the view tree).
    @MainActor
    static func exportPDF<Page: View>(page: Page, suggestedName: String) {
        guard let url = makePDF(page: page, fileName: suggestedName) else { return }
        // The temp PDF is not cleaned up: the OS reclaims the temp dir and re-exports overwrite by name.
        FileExport.exportFile(at: url, suggestedName: suggestedName)
    }

    /// Renders `page` to a single-page PDF and returns its URL (nil on failure).
    @MainActor
    static func makePDF<Page: View>(page: Page, fileName: String) -> URL? {
        let renderer = ImageRenderer(content: page)
        // 2x matches on-screen scale, is print-grade and keeps the file small.
        renderer.scale = 2.0

        let url = ZoopScratch.file(fileName)
        var didRender = false

        renderer.render { size, renderInContext in
            // The media box is the view's logical (unscaled) size.
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                return
            }
            pdf.beginPDFPage(nil)
            // Paint the page background first; PDF pages start transparent.
            pdf.setFillColor(Self.pageBackgroundCGColor)
            pdf.fill(mediaBox)
            renderInContext(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            didRender = true
        }

        return didRender ? url : nil
    }

    /// Renders `page` to a PNG and presents the share sheet / save panel; the image sibling of `exportPDF`.
    @MainActor
    static func exportPNG<Page: View>(page: Page, suggestedName: String) {
        guard let url = makePNG(page: page, fileName: suggestedName) else { return }
        FileExport.exportFile(at: url, suggestedName: suggestedName)
    }

    /// Renders `page` to a PNG and returns its URL (nil on failure). The page must carry its own opaque
    /// background (e.g. `surfaceBase`); there is no media-box fill as in the PDF path.
    @MainActor
    static func makePNG<Page: View>(page: Page, fileName: String) -> URL? {
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2.0
        #if canImport(UIKit)
        guard let data = renderer.uiImage?.pngData() else { return nil }
        #elseif canImport(AppKit)
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        #else
        return nil
        #endif
        let url = ZoopScratch.file(fileName)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// The report page's canvas colour as a CGColor, from `StrandPalette.surfaceBase`, to fill the PDF media box.
    private static var pageBackgroundCGColor: CGColor {
        #if canImport(AppKit)
        return NSColor(StrandPalette.surfaceBase).cgColor
        #elseif canImport(UIKit)
        return UIColor(StrandPalette.surfaceBase).cgColor
        #else
        return CGColor(gray: 0, alpha: 1)
        #endif
    }
}
