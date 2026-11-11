import AppKit
import ImageIO
import SwiftUI

/// The phone's photos and videos, newest first. Click opens one; it's copied from the phone only then.
struct GalleryTab: View {
    let model: AppModel
    let peer: Peer

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 8)]

    var body: some View {
        let data = model.phone(peer.id)
        if !data.features.contains("gallery") {
            FeatureOffCard(title: "Gallery")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(data.gallery.isEmpty ? "" : "\(data.gallery.count)\(data.galleryEnd ? "" : "+") photos and videos")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button { model.loadGallery(peer.id, reset: true) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.mint)
                }
                if let error = data.galleryError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                }
                ForEach(model.transfers.filter { $0.peerId == peer.id && !$0.outgoing && $0.status == .active }) { TransferRow(transfer: $0) }
                if data.gallery.isEmpty {
                    EmptyCard(text: data.galleryLoading ? "Loading photos…" : "No photos on the phone.")
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(data.gallery) { item in
                            GalleryCell(item: item, peerId: peer.id)
                                .onTapGesture { model.galleryItem(item, on: peer.id, action: .open) }
                                .contextMenu {
                                    Button("Open") { model.galleryItem(item, on: peer.id, action: .open) }
                                    Button("Save to Downloads") { model.galleryItem(item, on: peer.id, action: .save) }
                                }
                                .onAppear {
                                    // The next page loads as the end comes into view.
                                    if item.id == data.gallery.last?.id { model.loadGallery(peer.id) }
                                }
                        }
                    }
                    if data.galleryLoading {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    }
                }
                Text("Click to open, right-click to save. Opened copies are kept in the cache, so they open right away next time.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

private struct GalleryCell: View {
    let item: GalleryItem
    let peerId: String

    var body: some View {
        // A square that never grows: the thumbnail fills it and is cut at the edges, whatever its shape.
        Color.white.opacity(0.04)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = GalleryThumbs.slot(item, peerId: peerId).image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo").font(.system(size: 22)).foregroundStyle(Theme.textFaint)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        if let ms = item.durationMs { Text(Self.duration(ms)).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
                    }
                    .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule()).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help("\(item.name) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
    }

    static func duration(_ ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// One thumbnail, filled in once it's decoded. Each cell watches only its own.
@MainActor
@Observable
final class ThumbSlot {
    var image: NSImage?
    @ObservationIgnored var started = false
}

/// Decoded thumbnails, so scrolling doesn't decode them again. Decoding runs off the main thread, at about twice
/// the largest cell size, and the cache has a limit.
@MainActor
enum GalleryThumbs {
    /// Pixels on the longer side: cells are at most 160 points, shown on Retina displays.
    nonisolated static let maxPixels = 320
    private static let cache: NSCache<NSString, ThumbSlot> = {
        let cache = NSCache<NSString, ThumbSlot>()
        cache.countLimit = 600
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// The slot for this item, decoding its thumbnail the first time.
    static func slot(_ item: GalleryItem, peerId: String) -> ThumbSlot {
        let key = "\(peerId)/\(item.id)" as NSString
        let slot = cache.object(forKey: key) ?? ThumbSlot()
        guard !slot.started else { return slot }
        slot.started = true
        cache.setObject(slot, forKey: key, cost: 1024)
        guard let thumb = item.thumb else { return slot }
        Task {
            let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let data = Data(base64Encoded: thumb) else { return nil }
                return decode(data, maxPixels: maxPixels)
            }.value
            guard let decoded else { return }
            slot.image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            cache.setObject(slot, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        }
        return slot
    }

    nonisolated static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
