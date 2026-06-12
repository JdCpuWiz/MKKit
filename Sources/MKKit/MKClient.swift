import Foundation

// Hono / media-kennel client. Shared between zoo-tv (tvOS), zoo-tv-ios (iOS),
// and any future MK-consuming client (mk-ios sibling) via MKKit.
//
// Base URL = the public Traefik FQDN `https://media-kennel.deckerzoo.com`.
// Resolves to the LAN IP on home network; works off-LAN (cellular, away
// from home) too. Tinyauth is bypassed on `/api/*` by the
// `media-kennel-api` router on the Traefik host, so the pair handshake +
// every JWT-gated API call go straight through to Hono. The LAN IP
// `http://192.168.7.231:3011` remains a hard-coded ATS exception in each
// consuming app's Info.plist for dispatcharr Live TV (LAN-only — no public
// route) and a possible future "local mode" toggle.
//
// Auth: every per-device call carries `Authorization: Bearer <deviceJwt>`.
// When the API returns 401, the client treats the token as revoked,
// broadcasts `Notification.Name.mkDeviceRevoked`, and AppState (also in
// MKKit) clears the keychain and transitions back to the Pair screen.

public enum MKError: Error, LocalizedError, Sendable {
    case badResponse(Int, String)
    case decodingFailed(String)
    case noToken
    case offline

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code, let detail): return "MK \(code): \(detail)"
        case .decodingFailed(let detail):        return "Decode failed: \(detail)"
        case .noToken:                           return "Not paired"
        case .offline:                           return "Cannot reach media-kennel"
        }
    }
}

public actor MKClient {
    public static let shared = MKClient()

    // Public Traefik FQDN — reachable on any network. `nonisolated` because
    // it's a `let` constant of a Sendable type — safe to read from sync
    // contexts without actor hops.
    public nonisolated let baseURL: URL = URL(string: "https://media-kennel.deckerzoo.com")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Custom ISO8601 strategy that tolerates BOTH the default plain form
        // (`2024-01-01T12:00:00Z`) AND the fractional-seconds form
        // (`2024-01-01T12:00:00.000Z`). MK's Hono server serializes Date via
        // JSON.stringify(new Date()) which emits the fractional form — the
        // default `.iso8601` strategy throws dataCorrupted on that.
        // Latent bug — only surfaces when the keychain JWT is cleared and the
        // device needs to re-pair (PairStartResponse.expiresAt has fractional
        // seconds). Existing paired devices never hit this code path. Caught
        // via pawprint-ios first-time-pair failure on iPad 2026-05-25.
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withFracs = ISO8601DateFormatter()
            withFracs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFracs.date(from: str) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(str)",
            )
        }
        return d
    }()

    // MARK: - Pairing (no auth)

    public struct PairStartResponse: Decodable, Sendable {
        public let code: String
        public let expiresAt: Date
    }

    public enum PairStatus: Decodable, Sendable {
        case pending
        case ready(jwt: String, profileId: String)
        case expired

        private enum Keys: String, CodingKey { case status, jwt, profileId }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let status = try c.decode(String.self, forKey: .status)
            switch status {
            case "pending": self = .pending
            case "expired": self = .expired
            case "ready":
                let jwt = try c.decode(String.self, forKey: .jwt)
                let pid = try c.decode(String.self, forKey: .profileId)
                self = .ready(jwt: jwt, profileId: pid)
            default:
                self = .expired
            }
        }
    }

    public func pairStart() async throws -> PairStartResponse {
        try await postUnwrapped("/api/external/pair/start", body: nil as String?, requireAuth: false)
    }

    public func pairStatus(code: String) async throws -> PairStatus {
        try await getUnwrapped("/api/external/pair/status?code=\(code)", requireAuth: false)
    }

    // MARK: - Library rails (device JWT)

    public struct RecentItem: Decodable, Identifiable, Sendable {
        public let mediaType: String        // "movie" | "episode"
        public let mediaId: String
        public let title: String?
        public let year: Int?
        public let posterUrl: String?
        public let runtime: Int?
        public let seriesId: String?
        public let seriesTitle: String?
        public let seasonNumber: Int?
        public let episodeNumber: Int?
        public let airDate: Date?

        public var id: String { "\(mediaType):\(mediaId)" }
    }

    public func recentlyAdded(limit: Int = 20, profileId: String? = nil) async throws -> [RecentItem] {
        var path = "/api/external/library/recent?limit=\(limit)"
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "&profileId=\(encoded)"
        }
        return try await getUnwrapped(path)
    }

    // ContinueItem extends RecentItem's playable-thing fields with playback
    // progress so the rail can render a progress bar overlay on each card.
    // The wire shape mirrors RecentItem's flat layout — no nested
    // mediaSnapshot wrapper — so a single PosterCard view can render both rails.
    public struct ContinueItem: Decodable, Identifiable, Sendable {
        public let mediaType: String        // "movie" | "episode"
        public let mediaId: String
        public let title: String?
        public let year: Int?
        public let posterUrl: String?
        public let runtime: Int?
        public let seriesId: String?
        public let seriesTitle: String?
        public let seasonNumber: Int?
        public let episodeNumber: Int?
        public let airDate: Date?
        public let positionMs: Int
        public let durationMs: Int
        public let updatedAt: Date?

        public var id: String { "\(mediaType):\(mediaId)" }

        /// 0.0–1.0 — fraction of the item already watched. Used to paint the
        /// progress bar overlay on the poster.
        public var progress: Double {
            guard durationMs > 0 else { return 0 }
            return min(1, max(0, Double(positionMs) / Double(durationMs)))
        }
    }

    /// Continue Watching rail. Pass the runtime-selected `profileId` so the
    /// rail tracks the user picked from the launch picker, not the JWT-paired
    /// profile. MK side defaults to the JWT profile when the param is absent
    /// — single-profile households can keep calling without a profileId.
    public func continueWatching(profileId: String? = nil, limit: Int = 20) async throws -> [ContinueItem] {
        var path = "/api/external/library/continue?limit=\(limit)"
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "&profileId=\(encoded)"
        }
        return try await getUnwrapped(path)
    }

    // MARK: - Movies grid (device JWT)

    public struct MovieItem: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let sortTitle: String
        public let year: Int?
        public let runtime: Int?
        public let posterUrl: String?
        public let qualitySection: String?  // "HD" | "UHD"
        public let resolution: String?      // "2160p" | "1080p" | ...
        public let addedAt: Date?
    }

    public struct MoviesPage: Decodable, Sendable {
        public let data: [MovieItem]
        public let meta: Meta
        public struct Meta: Decodable, Sendable {
            public let page: Int
            public let limit: Int
            public let total: Int
        }
    }

    /// Returns ALL movies in one page by default (limit=2000 — the alphabet-nav
    /// pattern per the global UI standard). Use `search` to filter server-side.
    public func listMovies(page: Int = 1, limit: Int = 2000, search: String? = nil, profileId: String? = nil) async throws -> MoviesPage {
        var path = "/api/external/library/movies?page=\(page)&limit=\(limit)"
        if let search, !search.isEmpty {
            let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
            path += "&search=\(encoded)"
        }
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "&profileId=\(encoded)"
        }
        // Movies endpoint returns { success, data, meta } at the envelope level,
        // so we decode the full envelope's data+meta together via a custom shape.
        return try await getUnwrappedWithMeta(path)
    }

    /// Full movie detail for the Movie Detail screen — overview, ratings,
    /// content warnings, fanart, source + resolution badges. The `ratings`
    /// JSON has the OMDb shape: an array of `{ Source, Value }` rows.
    public struct MovieDetail: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let year: Int?
        public let overview: String?
        public let runtime: Int?
        public let qualitySection: String?
        public let resolution: String?
        public let source: String?
        public let posterUrl: String?
        public let fanartUrl: String?
        public let releaseDate: Date?
        public let addedAt: Date?
        public let ratings: Ratings?
        public let contentWarnings: [ContentWarning]
        /// Phase 5 muxarr — true once the file on disk has been
        /// successfully remuxed (track-drop and/or HEVC re-encode). MK
        /// flips it on live remux completion. UI shows a small "Remuxed"
        /// pill near the source/resolution badges.
        public let remuxed: Bool?
        public let remuxedAt: Date?
        /// Change #146 — TMDB-derived trailer video key (e.g. YouTube
        /// videoId). nil when no trailer was found at metadata fetch
        /// time. Pair with `trailerSite` to know which platform served
        /// it; today only "YouTube" is supported end-to-end.
        public let trailerKey: String?
        public let trailerSite: String?

        /// OMDb returns ratings as `{ "Ratings": [ { "Source": "Internet Movie Database", "Value": "8.4/10" }, ... ] }`.
        /// Some MK rows store the full OMDb payload (object), some store just the array. Decode both.
        public struct Ratings: Decodable, Sendable {
            public let entries: [Entry]

            public struct Entry: Decodable, Sendable {
                public let source: String
                public let value: String
                private enum Keys: String, CodingKey { case source = "Source", value = "Value" }
                public init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: Keys.self)
                    self.source = try c.decode(String.self, forKey: .source)
                    self.value  = try c.decode(String.self, forKey: .value)
                }
            }

            public init(from decoder: Decoder) throws {
                // Try the OMDb full payload first: { "Ratings": [...] }
                if let container = try? decoder.container(keyedBy: TopKeys.self),
                   let arr = try? container.decode([Entry].self, forKey: .ratings) {
                    self.entries = arr
                    return
                }
                // Fall back to a bare array.
                if var unkeyed = try? decoder.unkeyedContainer() {
                    var rows: [Entry] = []
                    while !unkeyed.isAtEnd {
                        if let row = try? unkeyed.decode(Entry.self) { rows.append(row) }
                        else { _ = try? unkeyed.decode(EmptyDecodable.self) }
                    }
                    self.entries = rows
                    return
                }
                self.entries = []
            }
            private enum TopKeys: String, CodingKey { case ratings = "Ratings" }
            private struct EmptyDecodable: Decodable {}
        }

        public struct ContentWarning: Decodable, Identifiable, Sendable {
            public let id: String
            public let topic: String
            public let yesVotes: Int
            public let noVotes: Int

            /// Heuristic: a warning is "confirmed" if more people said yes
            /// than no. Surfaced as the badge color in the UI.
            public var confirmed: Bool { yesVotes > noVotes }
        }
    }

    public func getMovieDetail(id: String) async throws -> MovieDetail {
        try await getUnwrapped("/api/external/library/movies/\(id)")
    }

    /// Change #146 — resolve a Movie's trailerKey to a direct CDN
    /// stream URL via MK's yt-dlp-backed extractor. URLs expire ~6h
    /// after extraction (YouTube tokens); callers refetch on 403 and
    /// hand the new URL to AVPlayer / TVVLCKit. expiresAt is unix
    /// seconds for cheap client-side cache-validity checks.
    public struct TrailerStream: Decodable, Sendable {
        public let url: URL
        public let expiresAt: TimeInterval
    }

    public func getMovieTrailerStream(id: String) async throws -> TrailerStream {
        try await getUnwrapped("/api/external/library/movies/\(id)/trailer-stream")
    }

    // MARK: - Profiles (device JWT)

    public struct ProfileItem: Decodable, Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let color: String       // hex, drives tile background
        public let avatarPath: String? // optional, served via /artwork/profile/:id
        /// ISO-639-1 audio language ("en", "es", ...). Defaults to "en" when
        /// MK responds without the field — covers backward-compat with any
        /// MK instance running pre-v0.104.0 before the migration lands.
        public let preferredAudioLanguage: String?
        /// nil / missing = "off" — VLCPlayerView reads this as "no subtitle
        /// auto-select". Empty-string is treated as nil to defend against
        /// any caller that sets it that way.
        public let preferredSubtitleLanguage: String?

        public var audioLanguageOrDefault: String { preferredAudioLanguage ?? "en" }
    }

    /// Lists every Profile on the household's MK instance so the client
    /// can let the user pick which one they're using this session. The
    /// device JWT is the credential — there's no admin gate on the read.
    public func listProfiles() async throws -> [ProfileItem] {
        try await getUnwrapped("/api/external/library/profiles")
    }

    /// Updates the per-profile playback language defaults that the client
    /// player auto-selects on every play. Pass `audio = nil` to leave the
    /// audio field unchanged; pass `subtitle = .some(nil)` to explicitly
    /// turn subtitles off, or `.some("en")` to set a subtitle language.
    public func updateProfilePreferences(
        profileId: String,
        audioLanguage: String?,
        subtitleLanguage: String??,
    ) async throws {
        let body = ProfilePreferencesUpdateBody(
            preferredAudioLanguage: audioLanguage,
            includeSubtitle: subtitleLanguage != nil,
            preferredSubtitleLanguage: subtitleLanguage ?? nil,
        )
        let _: EmptyResponse = try await putUnwrapped(
            "/api/external/library/profiles/\(profileId)/preferences",
            body: body,
        )
    }

    /// Encodes only the fields the caller actually wants to update. Swift's
    /// nested Optional encoding via Encodable is awkward when "null" must
    /// be distinguished from "missing" — we hand-roll the encode.
    private struct ProfilePreferencesUpdateBody: Encodable {
        let preferredAudioLanguage: String?
        let includeSubtitle: Bool
        let preferredSubtitleLanguage: String?

        private enum CodingKeys: String, CodingKey {
            case preferredAudioLanguage, preferredSubtitleLanguage
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let audio = preferredAudioLanguage {
                try c.encode(audio, forKey: .preferredAudioLanguage)
            }
            if includeSubtitle {
                // Encode either the string OR explicit JSON null — server
                // distinguishes "field absent" from "null = subtitles off".
                if let sub = preferredSubtitleLanguage {
                    try c.encode(sub, forKey: .preferredSubtitleLanguage)
                } else {
                    try c.encodeNil(forKey: .preferredSubtitleLanguage)
                }
            }
        }
    }

    // MARK: - TV grid + detail (device JWT)

    public struct SeriesItem: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let sortTitle: String
        public let year: Int?
        public let posterUrl: String?
        public let fanartUrl: String?
        public let network: String?
        public let firstAirDate: Date?
        public let qualitySection: String?
        public let addedAt: Date?
        public let seasonCount: Int
        public let episodes: EpisodeCounts

        public struct EpisodeCounts: Decodable, Sendable {
            public let downloaded: Int
            public let missing: Int
            public let wanted: Int
        }
    }

    public struct SeriesPage: Decodable, Sendable {
        public let data: [SeriesItem]
        public let meta: Meta
        public struct Meta: Decodable, Sendable {
            public let page: Int
            public let limit: Int
            public let total: Int
        }
    }

    /// Series detail with all watchable seasons + episodes. Episodes already
    /// filtered to filePath != null on the server, so the picker only shows
    /// playable rows.
    public struct SeriesDetail: Decodable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let year: Int?
        public let overview: String?
        public let posterUrl: String?
        public let fanartUrl: String?
        public let network: String?
        public let firstAirDate: Date?
        public let qualitySection: String?
        public let seasons: [Season]

        public struct Season: Decodable, Identifiable, Sendable {
            public let id: String
            public let number: Int
            public let posterUrl: String?
            public let episodeCount: Int
            public let episodes: [Episode]
        }

        public struct Episode: Decodable, Identifiable, Sendable {
            public let id: String
            public let number: Int
            public let endNumber: Int?    // for double-episode files (e.g. "S01E12-13")
            public let title: String?
            public let overview: String?
            public let airDate: Date?
            public let runtime: Int?
            public let fileSize: Int?
            public let source: String?
            public let resolution: String?
            /// Phase 5 muxarr — see MovieDetail.remuxed.
            public let remuxed: Bool?
            public let remuxedAt: Date?
        }
    }

    public func listSeries(page: Int = 1, limit: Int = 2000, search: String? = nil, profileId: String? = nil) async throws -> SeriesPage {
        var path = "/api/external/library/tv?page=\(page)&limit=\(limit)"
        if let search, !search.isEmpty {
            let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
            path += "&search=\(encoded)"
        }
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "&profileId=\(encoded)"
        }
        return try await getUnwrappedWithMeta(path)
    }

    public func getSeriesDetail(id: String, profileId: String? = nil) async throws -> SeriesDetail {
        var path = "/api/external/library/tv/\(id)"
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "?profileId=\(encoded)"
        }
        return try await getUnwrapped(path)
    }

    /// Lightweight per-episode metadata used by the player to render the
    /// Skip Intro / Skip Credits pills. Fetched in parallel with the
    /// resume + prefs probes during PlayerScreen's `.task`. All four
    /// `*Ms` fields are nullable on the wire — populated by the chapter-
    /// marker probe when the file ships labeled mkv/mp4 chapters; absent
    /// otherwise (the player simply doesn't render the corresponding
    /// pill).
    public struct EpisodeDetail: Decodable, Identifiable, Sendable {
        public let id: String
        public let seriesId: String
        public let seriesTitle: String
        public let seasonNumber: Int
        public let episodeNumber: Int
        public let endEpisodeNumber: Int?
        public let title: String?
        public let runtimeMinutes: Int?
        public let durationMs: Int?
        public let introStartMs: Int?
        public let introEndMs: Int?
        public let creditsStartMs: Int?
        public let creditsEndMs: Int?
        /// Phase-6 thumbnail-sprite presence flag. When true, the player
        /// fetches `/thumbnails/tv/<id>.jpg` + `.json` and renders frame
        /// previews above the scrub thumb during interactive scrub.
        public let hasThumbnails: Bool?
    }

    public func getEpisodeDetail(id: String) async throws -> EpisodeDetail {
        try await getUnwrapped("/api/external/library/episodes/\(id)")
    }

    // MARK: - Thumbnail sprites (no auth)

    /// JSON manifest written alongside each thumbnail sprite. Geometry is
    /// authoritative — the player must not assume tile size or grid
    /// dimensions from MKClient constants.
    public struct ThumbnailManifest: Decodable, Sendable {
        public let durationMs: Int
        public let intervalMs: Int
        public let count: Int
        public let tileWidth: Int
        public let tileHeight: Int
        public let cols: Int
        public let rows: Int
    }

    public func getThumbnailManifest(mediaType: String, mediaId: String) async throws -> ThumbnailManifest {
        // /thumbnails/<type>/<id>.json — public, no auth, mirrors
        // /artwork pattern. sendRaw avoids the { success, data } unwrap
        // because the route serves the manifest verbatim.
        let req = try makeRequest(
            method: "GET",
            path: "/thumbnails/\(mediaType)/\(mediaId).json",
            body: nil,
            requireAuth: false,
        )
        return try await sendRaw(req)
    }

    /// URL for the sprite jpg. The client fetches via URLSession during
    /// scrub and crops tiles in-process — see each app's VLCPlayerView.
    /// `nonisolated` so a sync caller (PlayerScreen body init) can build
    /// the URL without hopping the actor.
    public nonisolated func thumbnailSpriteURL(mediaType: String, mediaId: String) -> URL? {
        URL(string: "/thumbnails/\(mediaType)/\(mediaId).jpg", relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Search (device JWT)

    public struct SearchResults: Decodable, Sendable {
        public let movies: [MovieItem]
        public let series: [SeriesItem]
    }

    /// Unified library search across Movies + TvSeries. Empty `q` returns
    /// empty arrays — caller is expected to debounce so we don't fire on
    /// every keystroke.
    public func searchLibrary(q: String, limit: Int = 60) async throws -> SearchResults {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return SearchResults(movies: [], series: []) }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return try await getUnwrapped("/api/external/library/search?q=\(encoded)&limit=\(limit)")
    }

    // MARK: - Playback progress

    public struct PlaybackProgress: Codable, Sendable {
        public let positionMs: Int
        public let durationMs: Int
        public let updatedAt: Date?
    }

    public struct PlaybackUpsertBody: Encodable, Sendable {
        public let positionMs: Int
        public let durationMs: Int
    }

    public func playback(profileId: String, mediaType: String, mediaId: String) async throws -> PlaybackProgress? {
        do {
            return try await getUnwrapped("/api/external/playback/\(profileId)/\(mediaType)/\(mediaId)")
        } catch MKError.badResponse(let code, _) where code == 404 {
            return nil
        }
    }

    public func upsertPlayback(profileId: String, mediaType: String, mediaId: String, positionMs: Int, durationMs: Int) async throws {
        let body = PlaybackUpsertBody(positionMs: positionMs, durationMs: durationMs)
        let _: EmptyResponse = try await putUnwrapped(
            "/api/external/playback/\(profileId)/\(mediaType)/\(mediaId)",
            body: body
        )
    }

    // MARK: - Streaming URLs

    /// Returns a URL to the file with `?token=<jwt>` so VLCKit can request it
    /// without a custom Authorization header. The raw endpoint also accepts
    /// the Bearer header — query-token is the path of least resistance for VLC.
    /// `nonisolated` so sync callers (e.g. PlaybackTarget.init) can build URLs
    /// without hopping the actor — these touch no mutable state.
    ///
    /// Paths use the `/api/external/library/...` prefix (NOT the bare
    /// `/library/...` mount) so they clear Traefik's tinyauth forwardAuth
    /// off-LAN: tinyauth only bypasses `/api/external/*`, so the bare
    /// `/library/*/file` paths got a 401 at the proxy on cellular (bug #32).
    /// media-kennel mounts streamRoutes at both prefixes (v0.143.6) — the
    /// device-JWT `?token=` is the real gate either way.
    public nonisolated func movieStreamURL(_ id: String, profileId: String? = nil) -> URL? {
        guard let jwt = Keychain.read(.deviceJwt) else { return nil }
        var path = "/api/external/library/movies/\(id)/file?token=\(jwt)"
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "&profileId=\(encoded)"
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    public nonisolated func episodeStreamURL(_ id: String, profileId: String? = nil) -> URL? {
        guard let jwt = Keychain.read(.deviceJwt) else { return nil }
        var path = "/api/external/library/episodes/\(id)/file?token=\(jwt)"
        if let profileId, !profileId.isEmpty {
            let encoded = profileId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profileId
            path += "&profileId=\(encoded)"
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Wire helpers

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
        let error: String?
    }

    private struct EmptyResponse: Decodable {}

    private func makeRequest(method: String, path: String, body: Data?, requireAuth: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw MKError.badResponse(0, "bad url \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if requireAuth {
            guard let jwt = Keychain.read(.deviceJwt) else { throw MKError.noToken }
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    /// A 401 on a request that carried a Bearer token means the device JWT
    /// was revoked. Broadcast so AppState clears the keychain and returns
    /// to the Pair screen. A 401 on an unauthenticated call (e.g.
    /// /pair/start hitting a misconfigured proxy) says nothing about the
    /// pairing, so a valid session stays intact.
    nonisolated private func broadcastRevocationIfAuthenticated(_ req: URLRequest) {
        guard req.value(forHTTPHeaderField: "Authorization") != nil else { return }
        NotificationCenter.default.post(name: .mkDeviceRevoked, object: nil)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw MKError.offline
        }
        guard let http = resp as? HTTPURLResponse else {
            throw MKError.badResponse(0, "no HTTP response")
        }
        if http.statusCode == 401 {
            broadcastRevocationIfAuthenticated(req)
            throw MKError.badResponse(401, "Unauthorized")
        }
        if !(200...299).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw MKError.badResponse(http.statusCode, detail)
        }
        do {
            let env = try decoder.decode(Envelope<T>.self, from: data)
            if !env.success {
                throw MKError.badResponse(http.statusCode, env.error ?? "unknown")
            }
            guard let payload = env.data else {
                // Server returned `{ success: true }` with no data; for
                // EmptyResponse this is valid.
                if T.self is EmptyResponse.Type {
                    return EmptyResponse() as! T
                }
                throw MKError.decodingFailed("missing data field")
            }
            return payload
        } catch let err as MKError {
            throw err
        } catch {
            throw MKError.decodingFailed(String(describing: error))
        }
    }

    private func getUnwrapped<T: Decodable>(_ path: String, requireAuth: Bool = true) async throws -> T {
        let req = try makeRequest(method: "GET", path: path, body: nil, requireAuth: requireAuth)
        return try await send(req)
    }

    /// Variant of `send` that returns the FULL response decoded as T — useful
    /// when the wire shape includes top-level fields besides `data` (e.g.
    /// pagination `meta`). The caller's T must include `success`, `data`,
    /// and any additional top-level keys.
    private func sendRaw<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw MKError.offline
        }
        guard let http = resp as? HTTPURLResponse else {
            throw MKError.badResponse(0, "no HTTP response")
        }
        if http.statusCode == 401 {
            broadcastRevocationIfAuthenticated(req)
            throw MKError.badResponse(401, "Unauthorized")
        }
        if !(200...299).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw MKError.badResponse(http.statusCode, detail)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MKError.decodingFailed(String(describing: error))
        }
    }

    private func getUnwrappedWithMeta<T: Decodable>(_ path: String, requireAuth: Bool = true) async throws -> T {
        let req = try makeRequest(method: "GET", path: path, body: nil, requireAuth: requireAuth)
        return try await sendRaw(req)
    }

    private func postUnwrapped<T: Decodable, B: Encodable>(_ path: String, body: B?, requireAuth: Bool = true) async throws -> T {
        let data: Data? = try body.map { try JSONEncoder().encode($0) }
        let req = try makeRequest(method: "POST", path: path, body: data, requireAuth: requireAuth)
        return try await send(req)
    }

    private func putUnwrapped<T: Decodable, B: Encodable>(_ path: String, body: B, requireAuth: Bool = true) async throws -> T {
        let data = try JSONEncoder().encode(body)
        let req = try makeRequest(method: "PUT", path: path, body: data, requireAuth: requireAuth)
        return try await send(req)
    }
}
