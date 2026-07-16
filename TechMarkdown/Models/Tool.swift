import Foundation

struct ToolDefinition: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var description: String
    var parameters: [ToolParameter]
    var requiredParameters: [String]
    
    var openAISchema: [String: Any] {
        var properties: [String: Any] = [:]
        for param in parameters {
            properties[param.name] = param.schema
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": requiredParameters
                ]
            ]
        ]
    }
}

struct ToolParameter: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var type: String
    var description: String
    var `enum`: [String]?
    
    var schema: [String: Any] {
        var result: [String: Any] = [
            "type": type,
            "description": description
        ]
        if let enumValues = `enum` {
            result["enum"] = enumValues
        }
        return result
    }
}

struct ToolResult: Identifiable {
    let id = UUID()
    var toolCallID: String
    var name: String
    var output: String
    var isError: Bool = false
}

protocol ToolExecutable: AnyObject {
    var definition: ToolDefinition { get }
    func execute(arguments: [String: Any]) async throws -> String
}
