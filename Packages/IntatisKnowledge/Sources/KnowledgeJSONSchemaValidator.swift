import Foundation
import IntatisCore
import IntatisProtocol

/// Deterministic, network-free JSON Schema 2020-12 subset used by the frozen
/// Knowledge contracts. Unsupported assertion keywords fail closed; metadata
/// keywords are ignored. The implementation intentionally covers only the
/// keywords present in `Resources/Schemas` rather than becoming a general
/// schema runtime.
public struct KnowledgeJSONSchemaValidator: Sendable {
    public enum Schema: String, CaseIterable, Sendable {
        case store = "store-v1.schema"
        case checksums = "checksums-v1.schema"
        case sourceLocator = "source-locator-v1.schema"
        case chunk = "chunk-v1.schema"
        case validation = "validation-v1.schema"
        case searchInput = "search-knowledge-input-v2.schema"
        case searchOutput = "search-knowledge-output-v1.schema"
        case evidence = "evidence-v1.schema"
        case profile = "profile-0.1.schema"
    }

    public struct Failure: Error, Equatable, Sendable, LocalizedError {
        public let path: String
        public let reason: String

        public var errorDescription: String? {
            "JSON Schema validation failed at \(path): \(reason)"
        }
    }

    public init() {}

    public func validate<T: Encodable>(_ value: T,
                                       against schema: Schema) throws {
        let data = try KnowledgeJSON.encode(value)
        try validate(data: data, against: schema)
    }

    public func validate(data: Data, against schema: Schema) throws {
        guard data.count <= 64 * 1_024 * 1_024 else {
            throw Failure(path: "$", reason: "instance exceeds the schema validation byte limit")
        }
        let instance: JSONValue
        do {
            instance = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw Failure(path: "$", reason: "instance is not valid JSON")
        }
        try validate(instance, against: schema)
    }

    public func validate(_ value: JSONValue, against schema: Schema) throws {
        let root = try load(schema)
        try evaluate(value, schema: root, root: root, path: "$", depth: 0)
    }

    public func schemaValue(_ schema: Schema) throws -> JSONValue {
        try load(schema)
    }

    /// Evaluates a host-constructed dynamic schema (for example the exact
    /// snapshot-bound search input schema) with the same fail-closed 2020-12
    /// subset as frozen resources. The schema itself is byte-bounded and every
    /// unsupported assertion keyword is rejected by `evaluate`.
    public func validate(_ value: JSONValue,
                         againstDynamicSchema schema: JSONValue) throws {
        let schemaData = try KnowledgeJSON.encode(schema)
        guard schemaData.count <= 2 * 1_024 * 1_024 else {
            throw Failure(path: "$", reason: "dynamic schema exceeds the byte limit")
        }
        try evaluate(value, schema: schema, root: schema, path: "$", depth: 0)
    }

    public func validate(data: Data,
                         againstDynamicSchema schema: JSONValue) throws {
        guard data.count <= 64 * 1_024 * 1_024 else {
            throw Failure(path: "$", reason: "instance exceeds the schema validation byte limit")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw Failure(path: "$", reason: "instance is not valid JSON")
        }
        try validate(value, againstDynamicSchema: schema)
    }

    private func load(_ schema: Schema) throws -> JSONValue {
        guard let url = Bundle.module.url(
            forResource: schema.rawValue,
            withExtension: "json",
            subdirectory: "Schemas")
            ?? Bundle.module.url(
                forResource: schema.rawValue,
                withExtension: "json"),
              let data = try? Data(contentsOf: url),
              data.count <= 2 * 1_024 * 1_024,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Failure(path: "$", reason: "frozen schema resource is unavailable")
        }
        return Self.hostAdjustedSchema(value)
    }

    /// The checked-in schemas are the canonical Intatis templates. An
    /// embedding host uses the same assertions with only product-owned string
    /// identities adjusted; keywords, structure, bounds, and patterns remain
    /// otherwise byte-equivalent in meaning.
    private static func hostAdjustedSchema(_ value: JSONValue) -> JSONValue {
        let identity = IntatisHostApplication.identity
        guard identity != .intatis else { return value }
        switch value {
        case .string(let string):
            return .string(string
                .replacingOccurrences(
                    of: ".intatis-rag",
                    with: identity.knowledgeBundleDirectoryName)
                .replacingOccurrences(
                    of: "schemas.intatis.local",
                    with: "schemas.\(identity.fileNameStem).local")
                .replacingOccurrences(
                    of: "org.vita.intatis.",
                    with: "org.vita.\(identity.fileNameStem).")
                .replacingOccurrences(
                    of: "intatis-",
                    with: identity.fileNameStem + "-")
                .replacingOccurrences(
                    of: "Intatis",
                    with: identity.name))
        case .array(let array):
            return .array(array.map(hostAdjustedSchema))
        case .object(let object):
            return .object(object.mapValues(hostAdjustedSchema))
        case .null, .bool, .number:
            return value
        }
    }

    private func evaluate(_ value: JSONValue,
                          schema: JSONValue,
                          root: JSONValue,
                          path: String,
                          depth: Int) throws {
        guard depth <= 128 else {
            throw Failure(path: path, reason: "schema recursion exceeds the depth limit")
        }
        if case .bool(let accepted) = schema {
            guard accepted else { throw Failure(path: path, reason: "false schema") }
            return
        }
        guard case .object(let object) = schema else {
            throw Failure(path: path, reason: "schema node is not an object")
        }

        let supported: Set<String> = [
            "$schema", "$id", "$defs", "$ref", "title", "default",
            "type", "const", "enum", "oneOf", "allOf", "anyOf", "not",
            "if", "then", "else", "required", "properties",
            "additionalProperties", "items", "minItems", "maxItems",
            "uniqueItems", "minLength", "maxLength", "pattern", "format",
            "minimum", "maximum",
        ]
        if let unsupported = object.keys.first(where: { !supported.contains($0) }) {
            throw Failure(path: path, reason: "unsupported schema assertion keyword \(unsupported)")
        }

        if let reference = object.string("$ref") {
            guard reference.hasPrefix("#/") else {
                throw Failure(path: path, reason: "external schema references are forbidden")
            }
            let target = try resolve(reference, root: root)
            try evaluate(value, schema: target, root: root, path: path, depth: depth + 1)
        }
        if let type = object.string("type"), !matchesType(value, type: type) {
            throw Failure(path: path, reason: "expected type \(type)")
        }
        if let constant = object["const"], constant != value {
            throw Failure(path: path, reason: "value does not equal const")
        }
        if case .array(let alternatives)? = object["enum"],
           !alternatives.contains(value) {
            throw Failure(path: path, reason: "value is outside enum")
        }

        if case .array(let branches)? = object["oneOf"] {
            let successes = branches.reduce(into: 0) { count, branch in
                if (try? evaluate(value, schema: branch, root: root, path: path, depth: depth + 1)) != nil {
                    count += 1
                }
            }
            guard successes == 1 else {
                throw Failure(path: path, reason: "oneOf matched \(successes) branches")
            }
        }
        if case .array(let branches)? = object["allOf"] {
            for branch in branches {
                try evaluate(value, schema: branch, root: root, path: path, depth: depth + 1)
            }
        }
        if case .array(let branches)? = object["anyOf"] {
            guard branches.contains(where: {
                (try? evaluate(value, schema: $0, root: root, path: path, depth: depth + 1)) != nil
            }) else {
                throw Failure(path: path, reason: "no anyOf branch matched")
            }
        }
        if let forbidden = object["not"],
           (try? evaluate(value, schema: forbidden, root: root, path: path, depth: depth + 1)) != nil {
            throw Failure(path: path, reason: "not schema matched")
        }
        if let condition = object["if"],
           (try? evaluate(value, schema: condition, root: root, path: path, depth: depth + 1)) != nil {
            if let thenSchema = object["then"] {
                try evaluate(value, schema: thenSchema, root: root, path: path, depth: depth + 1)
            }
        } else if let elseSchema = object["else"] {
            try evaluate(value, schema: elseSchema, root: root, path: path, depth: depth + 1)
        }

        switch value {
        case .object(let instance):
            try validateObject(instance, schema: object, root: root, path: path, depth: depth)
        case .array(let instance):
            try validateArray(instance, schema: object, root: root, path: path, depth: depth)
        case .string(let instance):
            try validateString(instance, schema: object, path: path)
        case .number(let instance):
            try validateNumber(instance, schema: object, path: path)
        case .null, .bool:
            break
        }
    }

    private func validateObject(_ value: [String: JSONValue],
                                schema: [String: JSONValue],
                                root: JSONValue,
                                path: String,
                                depth: Int) throws {
        if case .array(let required)? = schema["required"] {
            for item in required {
                guard let key = item.nonEmptyString, value[key] != nil else {
                    throw Failure(path: path, reason: "required property is missing")
                }
            }
        }
        let properties: [String: JSONValue]
        if case .object(let declared)? = schema["properties"] {
            properties = declared
        } else {
            properties = [:]
        }
        if schema.bool("additionalProperties") == false,
           let unknown = value.keys.first(where: { properties[$0] == nil }) {
            throw Failure(path: path, reason: "additional property \(unknown) is forbidden")
        }
        for key in value.keys.sorted() {
            guard let childSchema = properties[key], let child = value[key] else { continue }
            try evaluate(
                child,
                schema: childSchema,
                root: root,
                path: path + "." + key,
                depth: depth + 1)
        }
    }

    private func validateArray(_ value: [JSONValue],
                               schema: [String: JSONValue],
                               root: JSONValue,
                               path: String,
                               depth: Int) throws {
        if let minimum = schema.integer("minItems"), value.count < minimum {
            throw Failure(path: path, reason: "array has fewer than \(minimum) items")
        }
        if let maximum = schema.integer("maxItems"), value.count > maximum {
            throw Failure(path: path, reason: "array has more than \(maximum) items")
        }
        if schema.bool("uniqueItems") == true {
            for index in value.indices {
                if value[..<index].contains(value[index]) {
                    throw Failure(path: path + "[\(index)]", reason: "array item is not unique")
                }
            }
        }
        if let itemSchema = schema["items"] {
            for (index, item) in value.enumerated() {
                try evaluate(item, schema: itemSchema, root: root, path: path + "[\(index)]", depth: depth + 1)
            }
        }
    }

    private func validateString(_ value: String,
                                schema: [String: JSONValue],
                                path: String) throws {
        let length = value.unicodeScalars.count
        if let minimum = schema.integer("minLength"), length < minimum {
            throw Failure(path: path, reason: "string is shorter than \(minimum) code points")
        }
        if let maximum = schema.integer("maxLength"), length > maximum {
            throw Failure(path: path, reason: "string is longer than \(maximum) code points")
        }
        if let pattern = schema.string("pattern") {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(pattern: pattern)
            } catch {
                throw Failure(path: path, reason: "frozen schema contains an invalid regex")
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard expression.firstMatch(in: value, range: range) != nil else {
                throw Failure(path: path, reason: "string does not match pattern")
            }
        }
        if let format = schema.string("format") {
            guard format == "date-time" else {
                throw Failure(path: path, reason: "unsupported format assertion \(format)")
            }
            guard ISO8601DateFormatter().date(from: value) != nil else {
                throw Failure(path: path, reason: "string is not an RFC 3339 date-time")
            }
        }
    }

    private func validateNumber(_ value: Double,
                                schema: [String: JSONValue],
                                path: String) throws {
        guard value.isFinite else {
            throw Failure(path: path, reason: "number is not finite")
        }
        if schema.string("type") == "integer", value.rounded() != value {
            throw Failure(path: path, reason: "number is not an integer")
        }
        if let minimum = schema.number("minimum"), value < minimum {
            throw Failure(path: path, reason: "number is below minimum")
        }
        if let maximum = schema.number("maximum"), value > maximum {
            throw Failure(path: path, reason: "number is above maximum")
        }
    }

    private func matchesType(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("number", .number), ("boolean", .bool), ("null", .null):
            return true
        case ("integer", .number(let value)):
            return value.isFinite && value.rounded() == value
        default:
            return false
        }
    }

    private func resolve(_ reference: String, root: JSONValue) throws -> JSONValue {
        var current = root
        for raw in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = raw
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard case .object(let object) = current, let next = object[key] else {
                throw Failure(path: "$", reason: "schema reference cannot be resolved")
            }
            current = next
        }
        return current
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.nonEmptyString }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        guard case .number(let value)? = self[key], value.isFinite else { return nil }
        return value
    }

    func integer(_ key: String) -> Int? {
        guard let value = number(key), value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}

private extension JSONValue {
    var nonEmptyString: String? {
        guard case .string(let value) = self, !value.isEmpty else { return nil }
        return value
    }
}
