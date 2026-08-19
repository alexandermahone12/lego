import PhotosUI
import SwiftUI
import UIKit

// MARK: - How many photos a listing needs

/// Mirrors `PHOTO_RULES` in the server's `lib/moderation.js`.
///
/// Both sides check. The app checks so a seller finds out before writing a description;
/// the server checks because the app is not a control — anyone can talk to the API
/// directly. If you change these, change them there too.
enum PhotoRules {
    static let minimum = 1
    static let minimumWhenBuilt = 2
    static let maximum = 3

    /// A built set needs two. "Built" means assembled and on display, and one
    /// flattering angle of an assembled model hides exactly the damage a buyer is
    /// asking about.
    static func required(for condition: Condition) -> Int {
        condition == .built ? minimumWhenBuilt : minimum
    }

    static func shortfall(count: Int, condition: Condition) -> String? {
        let needed = required(for: condition)
        guard count < needed else { return nil }
        return needed == 1
            ? "Add a photo of the actual item."
            : "Built sets need \(needed) photos — one angle isn't enough to judge an assembled set."
    }
}

// MARK: - The gallery

/// What you swipe through on a listing.
///
/// The first slide is the set's standard catalogue image, so a buyer can see what the
/// thing is meant to look like. Everything after it is the seller's own photos, which
/// is what they are actually buying. Keeping the two visually labelled matters in a
/// used marketplace — a stock photo is not evidence of anything.
enum ListingImage: Identifiable {
    case catalog(BrickSet)
    case sellerPhoto(URL)
    case placeholder(theme: String)

    var id: String {
        switch self {
        case .catalog(let set): "catalog-\(set.id)"
        case .sellerPhoto(let url): "photo-\(url.absoluteString)"
        case .placeholder(let theme): "placeholder-\(theme)"
        }
    }

    var isCatalog: Bool {
        if case .catalog = self { return true }
        return false
    }
}

extension Listing {
    /// Catalogue image first, seller photos after. Falls back to generated artwork so
    /// a listing is never a blank rectangle — older listings predate the photo
    /// requirement and still have to render.
    var gallery: [ListingImage] {
        var images: [ListingImage] = []

        if let number = setNumber, let set = Catalog.shared.set(number) {
            images.append(.catalog(set))
        }
        images.append(contentsOf: photoURLs.map { ListingImage.sellerPhoto($0) })

        return images.isEmpty ? [.placeholder(theme: theme)] : images
    }

    /// What a card shows: the seller's first photo if there is one, because that is the
    /// actual item, and the catalogue image only when there isn't.
    var cardImage: ListingImage {
        if let first = photoURLs.first { return .sellerPhoto(first) }
        return gallery[0]
    }
}

// MARK: - Rendering one image

struct ListingImageView: View {
    let image: ListingImage
    let theme: String
    var height: CGFloat = 132

    var body: some View {
        switch image {
        case .catalog(let set):
            if let url = set.imageURL {
                remote(url)
            } else {
                // No catalogue imagery bundled yet — see the note in Catalog.swift about
                // syncing from Rebrickable. Generated artwork stands in until then.
                BrickArt(seed: Catalog.themeSeed(set.theme), height: height)
            }

        case .sellerPhoto(let url):
            remote(ServerConfig.absoluteURL(for: url))

        case .placeholder(let theme):
            BrickArt(seed: Catalog.themeSeed(theme), height: height)
        }
    }

    private func remote(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let loaded):
                loaded
                    .resizable()
                    .scaledToFill()
            case .failure:
                ZStack {
                    BrickArt(seed: Catalog.themeSeed(theme), height: height)
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.9))
                }
            case .empty:
                ZStack {
                    Rectangle().fill(Brand.lineSoft)
                    ProgressView().tint(Brand.yellowDeep)
                }
            @unknown default:
                Rectangle().fill(Brand.lineSoft)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

// MARK: - Swipeable gallery

struct PhotoCarousel: View {
    let listing: Listing
    var height: CGFloat = 260

    @State private var index = 0

    private var images: [ListingImage] { listing.gallery }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.element.id) { offset, image in
                    ListingImageView(image: image, theme: listing.theme, height: height)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: height)

            HStack(alignment: .bottom) {
                if images.indices.contains(index), images[index].isCatalog {
                    // Say so. A stock photo is not a photo of the item being sold, and
                    // pretending otherwise is how a marketplace loses trust.
                    Text("Catalogue photo")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.92))
                        .clipShape(BrickFace(cornerRadius: 4))
                }
                Spacer()
                if images.count > 1 { studDots }
            }
            .padding(12)
        }
        .frame(height: height)
    }

    /// Page dots, but as studs.
    private var studDots: some View {
        HStack(spacing: 5) {
            ForEach(images.indices, id: \.self) { position in
                Circle()
                    .fill(position == index ? Brand.yellow : Color.white.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Brand.ink.opacity(0.15), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.22))
        .clipShape(Capsule())
        .accessibilityLabel("Photo \(index + 1) of \(images.count)")
    }
}

// MARK: - Preparing a photo for upload

extension UIImage {
    /// Downscale and compress before uploading.
    ///
    /// A modern phone photo is 4000px and several megabytes. Sending that costs the
    /// seller their data allowance, costs you bandwidth twice, and gets thrown away by
    /// a 180pt-wide card anyway. Doing it here also means the server needs no image
    /// library at all, which is what keeps it dependency-free and easy to host.
    func preparedForUpload(maxDimension: CGFloat = 1600, quality: CGFloat = 0.75) -> Data? {
        let longestEdge = max(size.width, size.height)
        let target: UIImage

        if longestEdge > maxDimension {
            let scale = maxDimension / longestEdge
            let newSize = CGSize(width: (size.width * scale).rounded(),
                                 height: (size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            target = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
                draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            target = self
        }

        // JPEG, always: the server sniffs the bytes and HEIC would be refused.
        return target.jpegData(compressionQuality: quality)
    }
}

// MARK: - Picking photos

/// One photo the seller has added: uploaded already, with the thumbnail kept around so
/// the row doesn't have to fetch back what we just sent.
struct PendingPhoto: Identifiable, Equatable {
    let id = UUID()
    let path: URL          // e.g. /v1/photos/<uuid>.jpg — resolved against the server
    let thumbnail: UIImage

    static func == (lhs: PendingPhoto, rhs: PendingPhoto) -> Bool { lhs.id == rhs.id }
}

/// The photo strip in the Sell form.
struct PhotoPickerStrip: View {
    @Binding var photos: [PendingPhoto]
    let condition: Condition

    @State private var selection: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var errorMessage: String?

    private var remaining: Int { max(0, PhotoRules.maximum - photos.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(photos) { photo in
                        thumbnail(photo)
                    }
                    if remaining > 0 { addButton }
                }
                .padding(.vertical, 2)
            }

            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(shortfall == nil ? Brand.muted : Brand.ink)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task { await upload(items) }
        }
    }

    private var shortfall: String? {
        PhotoRules.shortfall(count: photos.count, condition: condition)
    }

    private var statusText: String {
        if isUploading { return "Uploading…" }
        if let shortfall { return shortfall }
        return "\(photos.count) of \(PhotoRules.maximum) photos. Buyers scroll past listings without them."
    }

    private func thumbnail(_ photo: PendingPhoto) -> some View {
        Image(uiImage: photo.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 78, height: 78)
            .clipShape(BrickFace(cornerRadius: 7))
            .overlay(BrickFace(cornerRadius: 7).stroke(Brand.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button {
                    photos.removeAll { $0.id == photo.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white, Brand.ink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove photo")
            }
    }

    private var addButton: some View {
        PhotosPicker(selection: $selection,
                     maxSelectionCount: remaining,
                     matching: .images,
                     photoLibrary: .shared()) {
            VStack(spacing: 4) {
                Image(systemName: "camera.fill").font(.system(size: 17))
                Text("Add").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Brand.ink)
            .frame(width: 78, height: 78)
            .background(Brand.yellowSoft)
            .clipShape(BrickFace(cornerRadius: 7))
            .overlay(
                BrickFace(cornerRadius: 7)
                    .stroke(Brand.yellowDeep, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .disabled(isUploading)
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        isUploading = true
        errorMessage = nil
        defer {
            isUploading = false
            selection = []
        }

        for item in items.prefix(remaining) {
            guard
                let data = try? await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data),
                let prepared = image.preparedForUpload()
            else {
                errorMessage = "That photo couldn't be read. Try another."
                continue
            }

            do {
                let path = try await BackendClient.shared.uploadPhoto(prepared)
                photos.append(PendingPhoto(path: path, thumbnail: image))
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }
}
