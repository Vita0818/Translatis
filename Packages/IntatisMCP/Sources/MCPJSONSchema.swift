#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisProtocol

public struct MCPJSONSchemaLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumDepth: Int
    public let maximumNodes: Int

    public init(
        maximumBytes: Int = 1_048_576,
        maximumDepth: Int = 64,
        maximumNodes: Int = 50_000
    ) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
    }
}

public enum MCPJSONSchemaError: Error, Equatable, LocalizedError, Sendable {
    case schemaTooLarge(actual: Int, maximum: Int)
    case schemaTooDeep(maximum: Int)
    case schemaHasTooManyNodes(maximum: Int)
    case malformedSchema(path: String, reason: String)
    case validationFailed(path: String, reason: String)
    case unsupportedReference(String)

    public var errorDescription: String? {
        switch self {
        case .schemaTooLarge(let actual, let maximum):
            return "JSON Schema is \(actual) bytes; maximum is \(maximum)"
        case .schemaTooDeep(let maximum):
            return "JSON Schema exceeds maximum depth \(maximum)"
        case .schemaHasTooManyNodes(let maximum):
            return "JSON Schema exceeds maximum node count \(maximum)"
        case .malformedSchema(let path, let reason):
            return "malformed JSON Schema at \(path): \(reason)"
        case .validationFailed(let path, let reason):
            return "JSON value does not match schema at \(path): \(reason)"
        case .unsupportedReference(let reference):
            return "JSON Schema reference is unsupported or unresolved: \(reference)"
        }
    }
}

/// Bounded JSON-Schema validation used at both MCP discovery and execution.
///
/// The validator supports the assertion vocabulary needed by MCP tool schemas
/// (types, object/array/string/number constraints, enum/const, combinators and
/// local `$defs`/`definitions` references). Unknown annotation keywords are
/// retained on the wire but never interpreted as authority.
public enum MCPJSONSchema {
    public static func validateSchema(
        _ schema: JSONValue,
        rootMustBeObject: Bool = false,
        limits: MCPJSONSchemaLimits = .init()
    ) throws {
        let bytes = try canonicalData(schema).count
        guard bytes <= limits.maximumBytes else {
            throw MCPJSONSchemaError.schemaTooLarge(
                actual: bytes,
                maximum: limits.maximumBytes)
        }
        var nodes = 0
        try inspect(
            schema,
            path: "$",
            depth: 0,
            nodes: &nodes,
            limits: limits)
        if rootMustBeObject {
            switch schema {
            case .bool:
                throw MCPJSONSchemaError.malformedSchema(
                    path: "$",
                    reason: "MCP tool schemas must have an object root")
            case .object(let object):
                if let type = object["type"],
                   !schemaTypeIncludesObject(type) {
                    throw MCPJSONSchemaError.malformedSchema(
                        path: "$.type",
                        reason: "MCP tool schemas must allow object values")
                }
            default:
                throw MCPJSONSchemaError.malformedSchema(
                    path: "$",
                    reason: "schema must be an object or boolean")
            }
        }
    }

    public static func validate(
        _ value: JSONValue,
        against schema: JSONValue
    ) throws {
        try validateSchema(schema)
        try validateValue(
            value,
            schema: schema,
            rootSchema: schema,
            path: "$",
            referenceDepth: 0)
    }

    public static func hash(_ schema: JSONValue) throws -> String {
        let digest = SHA256.hash(data: try canonicalData(schema))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalData(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func inspect(
        _ value: JSONValue,
        path: String,
        depth: Int,
        nodes: inout Int,
        limits: MCPJSONSchemaLimits
    ) throws {
        guard depth <= limits.maximumDepth else {
            throw MCPJSONSchemaError.schemaTooDeep(
                maximum: limits.maximumDepth)
        }
        nodes += 1
        guard nodes <= limits.maximumNodes else {
            throw MCPJSONSchemaError.schemaHasTooManyNodes(
                maximum: limits.maximumNodes)
        }
        switch value {
        case .bool:
            return
        case .object(let object):
            try validateKeywordTypes(object, path: path)
            for (key, child) in object {
                try inspect(
                    child,
                    path: "\(path).\(key)",
                    depth: depth + 1,
                    nodes: &nodes,
                    limits: limits)
            }
        case .array(let values):
            for (index, child) in values.enumerated() {
                try inspect(
                    child,
                    path: "\(path)[\(index)]",
                    depth: depth + 1,
                    nodes: &nodes,
                    limits: limits)
            }
        case .null, .number, .string:
            if path == "$" {
                throw MCPJSONSchemaError.malformedSchema(
                    path: path,
                    reason: "schema root must be an object or boolean")
            }
        }
    }

    private static func validateKeywordTypes(
        _ object: [String: JSONValue],
        path: String
    ) throws {
        if let type = object["type"] {
            let valid: Bool
            switch type {
            case .string(let value):
                valid = validTypes.contains(value)
            case .array(let values):
                let names = values.compactMap { value -> String? in
                    guard case .string(let name) = value else { return nil }
                    return name
                }
                valid = names.count == values.count
                    && !names.isEmpty
                    && Set(names).count == names.count
                    && names.allSatisfy(validTypes.contains)
            default:
                valid = false
            }
            guard valid else {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).type",
                    reason: "type must be a valid string or unique string array")
            }
        }
        for key in ["properties", "patternProperties", "$defs", "definitions",
                    "dependentSchemas"] {
            if let value = object[key], case .object = value {
                // valid
            } else if object[key] != nil {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).\(key)",
                    reason: "must be an object")
            }
        }
        if let required = object["required"] {
            guard case .array(let values) = required else {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).required",
                    reason: "must be an array")
            }
            let names = values.compactMap { value -> String? in
                guard case .string(let name) = value else { return nil }
                return name
            }
            guard names.count == values.count,
                  Set(names).count == names.count else {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).required",
                    reason: "must contain unique strings")
            }
        }
        for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            if let value = object[key] {
                guard case .array(let values) = value, !values.isEmpty else {
                    throw MCPJSONSchemaError.malformedSchema(
                        path: "\(path).\(key)",
                        reason: "must be a non-empty array")
                }
            }
        }
        for key in ["minimum", "maximum", "exclusiveMinimum",
                    "exclusiveMaximum", "multipleOf",
                    "minLength", "maxLength", "minItems", "maxItems",
                    "minProperties", "maxProperties"] {
            if let value = object[key], case .number(let number) = value {
                guard number.isFinite else {
                    throw MCPJSONSchemaError.malformedSchema(
                        path: "\(path).\(key)",
                        reason: "must be finite")
                }
            } else if object[key] != nil {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).\(key)",
                    reason: "must be a number")
            }
        }
        if let multiple = number(object["multipleOf"]), multiple <= 0 {
            throw MCPJSONSchemaError.malformedSchema(
                path: "\(path).multipleOf",
                reason: "must be greater than zero")
        }
        for key in ["pattern", "$ref"] {
            if let value = object[key], case .string = value {
                // valid
            } else if object[key] != nil {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).\(key)",
                    reason: "must be a string")
            }
        }
        if case .string(let pattern)? = object["pattern"] {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw MCPJSONSchemaError.malformedSchema(
                    path: "\(path).pattern",
                    reason: "invalid regular expression")
            }
        }
    }

    private static func validateValue(
        _ value: JSONValue,
        schema: JSONValue,
        rootSchema: JSONValue,
        path: String,
        referenceDepth: Int
    ) throws {
        switch schema {
        case .bool(true):
            return
        case .bool(false):
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "boolean schema rejects every value")
        case .object(let object):
            break
        default:
            throw MCPJSONSchemaError.malformedSchema(
                path: path,
                reason: "schema must be an object or boolean")
        }
        guard case .object(let object) = schema else { return }

        if case .string(let reference)? = object["$ref"] {
            guard referenceDepth < 64,
                  let target = resolve(reference, in: rootSchema) else {
                throw MCPJSONSchemaError.unsupportedReference(reference)
            }
            try validateValue(
                value,
                schema: target,
                rootSchema: rootSchema,
                path: path,
                referenceDepth: referenceDepth + 1)
        }

        if let expected = object["type"],
           !matchesType(value, declaration: expected) {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "value has the wrong type")
        }
        if case .array(let allowed)? = object["enum"],
           !allowed.contains(value) {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "value is not in enum")
        }
        if let constant = object["const"], constant != value {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "value does not equal const")
        }
        if case .array(let schemas)? = object["allOf"] {
            for child in schemas {
                try validateValue(
                    value,
                    schema: child,
                    rootSchema: rootSchema,
                    path: path,
                    referenceDepth: referenceDepth)
            }
        }
        if case .array(let schemas)? = object["anyOf"] {
            let matches = schemas.filter {
                (try? validateValue(
                    value,
                    schema: $0,
                    rootSchema: rootSchema,
                    path: path,
                    referenceDepth: referenceDepth)) != nil
            }
            if matches.isEmpty {
                throw MCPJSONSchemaError.validationFailed(
                    path: path,
                    reason: "value matches no anyOf branch")
            }
        }
        if case .array(let schemas)? = object["oneOf"] {
            let count = schemas.reduce(into: 0) { count, child in
                if (try? validateValue(
                    value,
                    schema: child,
                    rootSchema: rootSchema,
                    path: path,
                    referenceDepth: referenceDepth)) != nil {
                    count += 1
                }
            }
            if count != 1 {
                throw MCPJSONSchemaError.validationFailed(
                    path: path,
                    reason: "value must match exactly one oneOf branch")
            }
        }
        if let rejected = object["not"],
           (try? validateValue(
                value,
                schema: rejected,
                rootSchema: rootSchema,
                path: path,
                referenceDepth: referenceDepth)) != nil {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "value matches prohibited not schema")
        }

        switch value {
        case .object(let valueObject):
            try validateObject(
                valueObject,
                schema: object,
                rootSchema: rootSchema,
                path: path,
                referenceDepth: referenceDepth)
        case .array(let values):
            try validateArray(
                values,
                schema: object,
                rootSchema: rootSchema,
                path: path,
                referenceDepth: referenceDepth)
        case .string(let string):
            try validateString(string, schema: object, path: path)
        case .number(let number):
            try validateNumber(number, schema: object, path: path)
        case .null, .bool:
            return
        }
    }

    private static func validateObject(
        _ value: [String: JSONValue],
        schema: [String: JSONValue],
        rootSchema: JSONValue,
        path: String,
        referenceDepth: Int
    ) throws {
        let required: Set<String>
        if case .array(let values)? = schema["required"] {
            required = Set(values.compactMap {
                guard case .string(let name) = $0 else { return nil }
                return name
            })
        } else {
            required = []
        }
        let missing = required.subtracting(value.keys)
        guard missing.isEmpty else {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "missing required properties: \(missing.sorted().joined(separator: ", "))")
        }
        if let minimum = integer(schema["minProperties"]),
           value.count < minimum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "too few properties")
        }
        if let maximum = integer(schema["maxProperties"]),
           value.count > maximum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "too many properties")
        }
        let properties: [String: JSONValue]
        if case .object(let map)? = schema["properties"] {
            properties = map
        } else {
            properties = [:]
        }
        for (name, childValue) in value {
            if let childSchema = properties[name] {
                try validateValue(
                    childValue,
                    schema: childSchema,
                    rootSchema: rootSchema,
                    path: "\(path).\(name)",
                    referenceDepth: referenceDepth)
            } else if let additional = schema["additionalProperties"] {
                switch additional {
                case .bool(true):
                    break
                case .bool(false):
                    throw MCPJSONSchemaError.validationFailed(
                        path: "\(path).\(name)",
                        reason: "additional property is not allowed")
                default:
                    try validateValue(
                        childValue,
                        schema: additional,
                        rootSchema: rootSchema,
                        path: "\(path).\(name)",
                        referenceDepth: referenceDepth)
                }
            }
        }
    }

    private static func validateArray(
        _ values: [JSONValue],
        schema: [String: JSONValue],
        rootSchema: JSONValue,
        path: String,
        referenceDepth: Int
    ) throws {
        if let minimum = integer(schema["minItems"]), values.count < minimum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "too few array items")
        }
        if let maximum = integer(schema["maxItems"]), values.count > maximum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "too many array items")
        }
        if case .bool(true)? = schema["uniqueItems"] {
            var seen: Set<Data> = []
            for value in values {
                let encoded = try canonicalData(value)
                guard seen.insert(encoded).inserted else {
                    throw MCPJSONSchemaError.validationFailed(
                        path: path,
                        reason: "array items must be unique")
                }
            }
        }
        if let items = schema["items"] {
            for (index, value) in values.enumerated() {
                try validateValue(
                    value,
                    schema: items,
                    rootSchema: rootSchema,
                    path: "\(path)[\(index)]",
                    referenceDepth: referenceDepth)
            }
        }
    }

    private static func validateString(
        _ value: String,
        schema: [String: JSONValue],
        path: String
    ) throws {
        if let minimum = integer(schema["minLength"]),
           value.count < minimum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "string is shorter than minLength")
        }
        if let maximum = integer(schema["maxLength"]),
           value.count > maximum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "string is longer than maxLength")
        }
        if case .string(let pattern)? = schema["pattern"] {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if expression.firstMatch(in: value, range: range) == nil {
                throw MCPJSONSchemaError.validationFailed(
                    path: path,
                    reason: "string does not match pattern")
            }
        }
    }

    private static func validateNumber(
        _ value: Double,
        schema: [String: JSONValue],
        path: String
    ) throws {
        if let minimum = number(schema["minimum"]), value < minimum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "number is below minimum")
        }
        if let maximum = number(schema["maximum"]), value > maximum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "number is above maximum")
        }
        if let minimum = number(schema["exclusiveMinimum"]),
           value <= minimum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "number is not above exclusiveMinimum")
        }
        if let maximum = number(schema["exclusiveMaximum"]),
           value >= maximum {
            throw MCPJSONSchemaError.validationFailed(
                path: path,
                reason: "number is not below exclusiveMaximum")
        }
        if let multiple = number(schema["multipleOf"]) {
            let quotient = value / multiple
            if abs(quotient - quotient.rounded()) > 1e-9 {
                throw MCPJSONSchemaError.validationFailed(
                    path: path,
                    reason: "number is not a multipleOf value")
            }
        }
    }

    private static func matchesType(
        _ value: JSONValue,
        declaration: JSONValue
    ) -> Bool {
        let names: [String]
        switch declaration {
        case .string(let name):
            names = [name]
        case .array(let values):
            names = values.compactMap {
                guard case .string(let name) = $0 else { return nil }
                return name
            }
        default:
            return false
        }
        return names.contains { name in
            switch (name, value) {
            case ("null", .null), ("boolean", .bool), ("number", .number),
                    ("string", .string), ("array", .array),
                    ("object", .object):
                return true
            case ("integer", .number(let number)):
                return number.isFinite
                    && number.rounded(.towardZero) == number
            default:
                return false
            }
        }
    }

    private static func resolve(
        _ reference: String,
        in root: JSONValue
    ) -> JSONValue? {
        guard reference == "#" || reference.hasPrefix("#/") else {
            return nil
        }
        if reference == "#" { return root }
        let components = reference.dropFirst(2).split(
            separator: "/",
            omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "~1", with: "/")
                    .replacingOccurrences(of: "~0", with: "~")
            }
        var current = root
        for component in components {
            switch current {
            case .object(let object):
                guard let next = object[component] else { return nil }
                current = next
            case .array(let values):
                guard let index = Int(component),
                      values.indices.contains(index) else { return nil }
                current = values[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func schemaTypeIncludesObject(_ value: JSONValue) -> Bool {
        switch value {
        case .string("object"):
            return true
        case .array(let values):
            return values.contains(.string("object"))
        default:
            return false
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value else { return nil }
        return number
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let number = number(value),
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private static let validTypes: Set<String> = [
        "null", "boolean", "object", "array", "number", "string", "integer",
    ]
}
