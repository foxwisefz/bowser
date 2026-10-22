import Foundation
import BackendRuntime

func runMCP() throws {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: ((env["BOWSER_HOME"] ?? "~/.bowser") as NSString).expandingTildeInPath)
    let allTools = try JSONSerialization.jsonObject(with: Data(toolCatalogJSON.utf8)) as? [Message] ?? []
    let taskTools: Set<String> = ["list_tabs", "page_html", "page_eval", "page_screenshot", "ask_user", "save_task_file", "task_files"]
    let catalog = allTools.filter { tool in
        let name = tool["name"] as? String ?? ""
        if env["BOWSER_MODSMITH_KIND"] == "task" { return taskTools.contains(name) }
        return !["save_task_file", "task_files"].contains(name)
    }
    while let line = readLine() {
        guard let message = try? json(Data(line.utf8)) else { continue }
        let id = message["id"] ?? NSNull()
        let params = message["params"] as? Message ?? [:]
        var result: Message
        switch message["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] ?? "2024-11-05", "capabilities": ["tools": Message()], "serverInfo": ["name": "bowser", "version": "1.0"]]
        case "tools/list": result = ["tools": catalog]
        case "tools/call":
            var args = params["arguments"] as? Message ?? [:]
            if let site = env["BOWSER_SITE_APP_ID"] { args["site_app"] = site }
            var response: Message
            do { response = try lineRequest(child(root, "agent.sock"), ["tool": params["name"] ?? NSNull(), "args": args, "run": env["BOWSER_MODSMITH_RUN"] ?? ""]) }
            catch { response = ["ok": false, "error": "agent.sock unreachable: \(error)"] }
            let image = response.removeValue(forKey: "image")
            var content: [Message] = [["type": "text", "text": String(decoding: try encode(response), as: UTF8.self)]]
            if let image, response["ok"] as? Bool == true { content.append(["type": "image", "data": image, "mimeType": response["mimeType"] ?? "image/png"]) }
            result = ["content": content, "isError": response["ok"] as? Bool != true]
        default:
            if message["id"] == nil { continue }
            result = [:]
        }
        var output = try encode(["jsonrpc": "2.0", "id": id, "result": result]); output.append(10)
        try FileHandle.standardOutput.write(contentsOf: output)
    }
}
