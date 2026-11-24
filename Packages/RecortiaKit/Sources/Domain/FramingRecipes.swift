import Foundation

public struct FramingRecipe: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let presentation: Presentation
}

public struct FramingRecipes: Hashable, Sendable, Codable {
    public enum Failure: Swift.Error, Equatable, Sendable {
        case invalidName
        case duplicateName
        case limitReached
        case invalidFraming
        case unavailable
    }

    public static let limit = 12
    public private(set) var entries: [FramingRecipe] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        guard var array = try? decoder.unkeyedContainer() else { return }
        while !array.isAtEnd, entries.count < Self.limit {
            let item = try array.superDecoder()
            guard let recipe = try? FramingRecipe(from: item) else { continue }
            try? append(recipe)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var array = encoder.unkeyedContainer()
        try array.encode(contentsOf: entries)
    }

    public mutating func save(named name: String, presentation: Presentation) throws(Failure) -> UUID {
        let id = UUID()
        try append(FramingRecipe(id: id, name: name, presentation: presentation))
        return id
    }

    public mutating func rename(_ id: UUID, to name: String) throws(Failure) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw .unavailable }
        let name = try admitName(name, excluding: id)
        entries[index] = FramingRecipe(id: id, name: name, presentation: entries[index].presentation)
    }

    public mutating func remove(_ id: UUID) throws(Failure) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw .unavailable }
        entries.remove(at: index)
    }

    private mutating func append(_ recipe: FramingRecipe) throws(Failure) {
        guard entries.count < Self.limit else { throw .limitReached }
        guard !entries.contains(where: { $0.id == recipe.id }) else { throw .unavailable }
        let name = try admitName(recipe.name)
        guard let presentation = recipe.presentation.validSavedFraming else { throw .invalidFraming }
        entries.append(FramingRecipe(id: recipe.id, name: name, presentation: presentation))
    }

    private func admitName(_ input: String, excluding id: UUID? = nil) throws(Failure) -> String {
        let name = input.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.utf8.count <= 64,
            input.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
        else { throw .invalidName }
        let locale = Locale(identifier: "en_US_POSIX")
        guard
            !entries.contains(where: {
                $0.id != id && $0.name.compare(name, options: .caseInsensitive, locale: locale) == .orderedSame
            })
        else { throw .duplicateName }
        return name
    }
}
