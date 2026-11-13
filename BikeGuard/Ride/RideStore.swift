import Foundation

protocol RideStoring: AnyObject, Sendable {
    func load() -> RideSession?
    func save(_ session: RideSession?)
}

enum RideCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

final class MemoryRideStore: RideStoring, @unchecked Sendable {
    private var session: RideSession?

    func load() -> RideSession? { session }

    func save(_ session: RideSession?) {
        self.session = session
    }
}

final class UserDefaultsRideStore: RideStoring, @unchecked Sendable {
    static let storageKey = "bikeguard.rideSession.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RideSession? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? RideCoding.decoder.decode(RideSession.self, from: data)
    }

    func save(_ session: RideSession?) {
        if let session {
            guard let data = try? RideCoding.encoder.encode(session) else { return }
            defaults.set(data, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}
