import AppKit
import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@MainActor private final class DisplayTestState {
    var created: [UInt32] = []
    var removed: [UInt32] = []
}

@main
struct AddonAPITest {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let api = root.appendingPathComponent("api")
        let ui = root.appendingPathComponent("ui")
        let panels = ui.appendingPathComponent("panels")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AddonAPIServer(directory: api, panels: panels)
        let displays = DisplayTestState()
        server.start(cameraAllowed: { true }, createDisplay: { index in
            let id = UInt32(100 + index); displays.created.append(id); return id
        }, removeDisplay: { displays.removed.append($0) }) { true }
        for _ in 0..<200 where !server.running && server.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard server.running else { fatalError("API failed to start: \(server.error ?? "timeout")") }
        let duplicate = AddonAPIServer(directory: api, panels: panels)
        duplicate.start { false }
        require(duplicate.error != nil, "second server must not overwrite credentials")
        let infoURL = api.appendingPathComponent("connection.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: infoURL.path)
        require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "credentials must be private")
        let connectionInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: infoURL)) as! [String: Any]
        let hostPort = (connectionInfo["port"] as! NSNumber).uint16Value
        let auth = connectionInfo["token"] as! String
        let task = Task.detached {
            let bad = socket(AF_INET, SOCK_STREAM, 0)
            require(bad >= 0, "unauthorized socket")
            var badAddress = sockaddr_in()
            badAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            badAddress.sin_family = sa_family_t(AF_INET)
            badAddress.sin_port = hostPort.bigEndian
            badAddress.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
            let badRC = withUnsafePointer(to: &badAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(bad, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            require(badRC == 0, "unauthorized connect")
            let wrong = Data("{\"id\":\"bad\",\"apiVersion\":1,\"token\":\"invalid\",\"method\":\"status\"}\n".utf8)
            _ = wrong.withUnsafeBytes { Darwin.send(bad, $0.baseAddress, $0.count, 0) }
            var byte: UInt8 = 0
            require(Darwin.recv(bad, &byte, 1, 0) == 0, "invalid credentials must close connection")
            close(bad)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            require(fd >= 0, "socket")
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = hostPort.bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
            let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            require(rc == 0, "connect")
            func request(_ method: String, extra: [String: Any] = [:]) throws -> [String: Any] {
                var msg: [String: Any] = ["id": UUID().uuidString, "apiVersion": 1, "token": auth, "method": method]
                for (key, value) in extra { msg[key] = value }
                let data = try JSONSerialization.data(withJSONObject: msg) + Data([10])
                try data.withUnsafeBytes { bytes in
                    var sent = 0
                    while sent < bytes.count {
                        let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                        guard n > 0 else { throw NSError(domain: "send", code: Int(errno)) }
                        sent += n
                    }
                }
                var result = Data(); var byte: UInt8 = 0
                while Darwin.recv(fd, &byte, 1, 0) == 1 && byte != 10 { result.append(byte) }
                return try JSONSerialization.jsonObject(with: result) as! [String: Any]
            }
            let status = try request("status")
            require(status["ok"] as? Bool == true && ((status["result"] as? [String: Any])?["sessionRunning"] as? Bool) == true, "status")
            let display = try request("display.create", extra: ["displayId": "one", "index": 0])
            require((display["result"] as? [String: Any])?["displayID"] as? Int == 100, "create display")
            let duplicateDisplay = try request("display.create", extra: ["displayId": "one", "index": 1])
            let missingDisplay = try request("display.remove", extra: ["displayId": "missing"])
            let removedDisplay = try request("display.remove", extra: ["displayId": "one"])
            let disconnectDisplay = try request("display.create", extra: ["displayId": "two", "index": 1])
            require(duplicateDisplay["ok"] as? Bool == false, "duplicate display")
            require(missingDisplay["ok"] as? Bool == false, "unowned display")
            require(removedDisplay["ok"] as? Bool == true, "remove display")
            require(disconnectDisplay["ok"] as? Bool == true, "create display for disconnect")
            let waitingInput = try request("input.controllers")
            require(((waitingInput["result"] as? [String: Any])?["available"] as? Bool) == false, "controller waits for fresh state")
            let inputDir = ui.appendingPathComponent("api-input")
            let inputLease = try String(contentsOf: inputDir.appendingPathComponent("controllers.request"), encoding: .utf8)
            let inputSnapshot: [String: Any] = ["lease": inputLease, "focused": true, "left": ["primary": ["active": true, "pressed": true]], "right": [:]]
            try JSONSerialization.data(withJSONObject: inputSnapshot).write(to: inputDir.appendingPathComponent("controllers.json"))
            let inputReply = try request("input.controllers")
            let inputResult = inputReply["result"] as? [String: Any]
            let left = inputResult?["left"] as? [String: Any]
            require((inputResult?["available"] as? Bool) == true && ((left?["primary"] as? [String: Any])?["pressed"] as? Bool) == true, "controller state")
            let denied = try request("camera.frame", extra: ["eye": "left"])
            require(denied["ok"] as? Bool == false, "camera must default to disabled")
            await MainActor.run { server.setCameraAccess(true) }
            let invalidEye = try request("camera.frame", extra: ["eye": "../../secret"])
            require(invalidEye["ok"] as? Bool == false, "invalid camera eye")
            let waiting = try request("camera.frame", extra: ["eye": "left"])
            require(((waiting["result"] as? [String: Any])?["available"] as? Bool) == false, "camera waits for fresh frame")
            let cameraDir = ui.appendingPathComponent("api-camera")
            let lease = try String(contentsOf: cameraDir.appendingPathComponent("left.request"), encoding: .utf8)
            let snapshot: [String: Any] = ["lease": lease, "eye": "left", "format": "jpeg", "width": 1, "height": 1, "captureTimestampNs": "123", "data": "AA=="]
            try JSONSerialization.data(withJSONObject: snapshot).write(to: cameraDir.appendingPathComponent("left.json"))
            let camera = try request("camera.frame", extra: ["eye": "left"])
            require(((camera["result"] as? [String: Any])?["data"] as? String) == "AA==", "camera delivers frame")
            await MainActor.run { server.setCameraAccess(false) }
            require(!FileManager.default.fileExists(atPath: cameraDir.appendingPathComponent("left.json").path), "camera disable removes frame")
            let disabled = try request("camera.frame", extra: ["eye": "left"])
            require(disabled["ok"] as? Bool == false, "camera revoked")
            let modelPath = root.appendingPathComponent("test.usdz")
            try Data([1, 2, 3]).write(to: modelPath)
            let badModel = try request("model.load", extra: ["modelId": "../../bad", "path": modelPath.path])
            require(badModel["ok"] as? Bool == false, "reject invalid model ID")
            let modelLoad = try request("model.load", extra: ["modelId": "demo-model", "path": modelPath.path, "rotation": ["mode": "spin", "degreesPerSecond": 12]])
            require(modelLoad["ok"] as? Bool == true, "queue model")
            let modelFiles = try FileManager.default.contentsOfDirectory(at: ui.appendingPathComponent("api-models"), includingPropertiesForKeys: nil)
            require(modelFiles.count == 1, "model request file")
            let modelRequest = try JSONSerialization.jsonObject(with: Data(contentsOf: modelFiles[0])) as! [String: Any]
            let pendingModel = try request("model.status", extra: ["modelId": "demo-model"])
            require(((pendingModel["result"] as? [String: Any])?["state"] as? String) == "pending", "pending model status")
            let modelStatusURL = ui.appendingPathComponent("api-model-status").appendingPathComponent(modelFiles[0].lastPathComponent)
            try JSONSerialization.data(withJSONObject: ["state": "ready", "revision": modelRequest["revision"]!]).write(to: modelStatusURL)
            let readyModel = try request("model.status", extra: ["modelId": "demo-model"])
            require(((readyModel["result"] as? [String: Any])?["state"] as? String) == "ready", "ready model status")
            let removedModel = try request("model.remove", extra: ["modelId": "demo-model"])
            require(removedModel["ok"] as? Bool == true && !FileManager.default.fileExists(atPath: modelFiles[0].path) && !FileManager.default.fileExists(atPath: modelStatusURL.path), "model cleanup")
            let panel: [String: Any] = ["title": "Example", "lines": ["Hello"], "buttons": [["id": "go", "label": "Go"]], "anchor": "dashboard", "position": [0.0, 0.0, -1.0], "orientation": [0.0, 0.0, 0.0, 1.0], "rotation": ["mode": "spin", "degreesPerSecond": 25], "decoration": ["shape": "fractal", "size": 0.15, "color": [0.2, 0.8, 0.6]]]
            let created = try request("panel.set", extra: ["panelId": "demo", "panel": panel])
            require(created["ok"] as? Bool == true, "create")
            let name = (created["result"] as! [String: Any])["panel"] as! String
            let invalidAttachment = try request("model.load", extra: ["modelId": "bad-attachment", "path": modelPath.path, "panelId": "not-owned", "size": 0.22])
            require(invalidAttachment["ok"] as? Bool == false, "reject attachment to an unowned panel")
            let attached = try request("model.load", extra: ["modelId": "attached", "path": modelPath.path, "panelId": "demo", "size": 0.22])
            require(attached["ok"] as? Bool == true, "queue attached model")
            let attachedFiles = try FileManager.default.contentsOfDirectory(at: ui.appendingPathComponent("api-models"), includingPropertiesForKeys: nil)
            let attachedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: attachedFiles[0])) as! [String: Any]
            require(attachedObject["parentPanel"] as? String == name && abs((attachedObject["size"] as? Double ?? 0) - 0.22) < 0.00001, "model attachment target and size")
            let attachedRemove = try request("model.remove", extra: ["modelId": "attached"])
            require(attachedRemove["ok"] as? Bool == true, "remove attached model")
            let panelObject = try JSONSerialization.jsonObject(with: Data(contentsOf: panels.appendingPathComponent(name + ".json"))) as! [String: Any]
            require((panelObject["orientation"] as? [Double])?.count == 4 && (panelObject["rotation"] as? [String: Any])?["mode"] as? String == "spin" && (panelObject["decoration"] as? [String: Any])?["shape"] as? String == "fractal", "panel transform and decoration preserved")
            var invalidPanel = panel; invalidPanel["orientation"] = [0, 0, 0, 0]
            let invalidTransform = try request("panel.set", extra: ["panelId": "bad", "panel": invalidPanel])
            require(invalidTransform["ok"] as? Bool == false, "invalid quaternion rejected")
            require(FileManager.default.fileExists(atPath: panels.appendingPathComponent(name + ".json").path), "panel file")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let imageData = bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
            let imageReply = try request("panel.image", extra: ["panelId": "demo", "data": imageData])
            require(imageReply["ok"] as? Bool == true, "panel image")
            let rendered = try JSONSerialization.jsonObject(with: Data(contentsOf: panels.appendingPathComponent(name + ".json"))) as! [String: Any]
            let imagePath = rendered["image"] as! String
            require(FileManager.default.fileExists(atPath: imagePath), "panel image file")
            let throttled = try request("panel.image", extra: ["panelId": "demo", "data": imageData])
            require(throttled["ok"] as? Bool == false, "image throttling")
            let audioData = Data(repeating: 0, count: 15360)
            let audioReply = try request("audio.push", extra: ["data": audioData.base64EncodedString()])
            require(audioReply["ok"] as? Bool == true && ((audioReply["result"] as? [String: Any])?["framesQueued"] as? Int) == 1920, "audio queue")
            let audioDir = ui.appendingPathComponent("addon-audio")
            let audioFiles = try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
            require(audioFiles.count == 1 && (try? Data(contentsOf: audioFiles[0])) == audioData, "audio bytes")
            var badSample = Data(repeating: 0, count: 3840)
            badSample.replaceSubrange(0..<4, with: [0, 0, 0x80, 0x7f])
            let invalidAudio = try request("audio.push", extra: ["data": badSample.base64EncodedString()])
            require(invalidAudio["ok"] as? Bool == false, "reject nonfinite audio")
            let spatialData = Data(repeating: 0, count: 1920)
            let spatialReply = try request("audio.spatial", extra: ["data": spatialData.base64EncodedString(), "mode": "cues", "itdUs": 200, "ildDb": -3, "referenceDistance": 2, "rolloff": 0.5])
            require(spatialReply["ok"] as? Bool == true && ((spatialReply["result"] as? [String: Any])?["framesQueued"] as? Int) == 480, "spatial audio queue")
            let spatialFiles = try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "spatial" }
            require(spatialFiles.count == 1, "spatial audio queued")
            let spatialPacket = try JSONSerialization.jsonObject(with: Data(contentsOf: spatialFiles[0])) as! [String: Any]
            require((spatialPacket["itdUs"] as? Int) == 200 && (spatialPacket["ildDb"] as? Int) == -3 && (spatialPacket["rolloff"] as? Double) == 0.5 && (spatialPacket["referenceDistance"] as? Int) == 2, "spatial settings")
            let invalidCue = try request("audio.spatial", extra: ["data": spatialData.base64EncodedString(), "itdUs": 2001])
            require(invalidCue["ok"] as? Bool == false, "invalid ITD rejected")
            let invalidRolloff = try request("audio.spatial", extra: ["data": spatialData.base64EncodedString(), "rolloff": -1])
            require(invalidRolloff["ok"] as? Bool == false, "invalid distance settings rejected")
            let invalidPosition = try request("audio.spatial", extra: ["data": spatialData.base64EncodedString(), "x": 0, "y": 0, "z": 0])
            require(invalidPosition["ok"] as? Bool == false, "invalid source rejected")
            let otherFD = socket(AF_INET, SOCK_STREAM, 0)
            require(otherFD >= 0, "second client socket")
            let otherConnect = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(otherFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            require(otherConnect == 0, "second client connect")
            let otherRequest = try JSONSerialization.data(withJSONObject: ["id": "other", "apiVersion": 1, "token": auth, "method": "audio.push", "data": audioData.base64EncodedString()]) + Data([10])
            _ = otherRequest.withUnsafeBytes { Darwin.send(otherFD, $0.baseAddress, $0.count, 0) }
            var otherResponse = Data(); var otherByte: UInt8 = 0
            while Darwin.recv(otherFD, &otherByte, 1, 0) == 1 && otherByte != 10 { otherResponse.append(otherByte) }
            let otherJSON = try JSONSerialization.jsonObject(with: otherResponse) as! [String: Any]
            require(otherJSON["ok"] as? Bool == false, "audio must be exclusive")
            close(otherFD)
            let releaseAudio = try request("audio.release")
            require(releaseAudio["ok"] as? Bool == true && ((try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []).isEmpty, "audio release")
            let unrelated = try JSONSerialization.data(withJSONObject: ["panel": "other-client", "event": "button", "button": "secret"]) + Data([10])
            let event = try JSONSerialization.data(withJSONObject: ["panel": name, "event": "button", "button": "go", "time": 123]) + Data([10])
            try (unrelated + event).write(to: ui.appendingPathComponent("events.jsonl"))
            let polled = try request("events.poll")
            let events = (polled["result"] as? [String: Any])?["events"] as? [[String: Any]]
            require(events?.count == 1 && events?.first?["button"] as? String == "go", "owned event")
            let removed = try request("panel.remove", extra: ["panelId": "demo"])
            require(removed["ok"] as? Bool == true && !FileManager.default.fileExists(atPath: panels.appendingPathComponent(name + ".json").path) && !FileManager.default.fileExists(atPath: imagePath), "remove")
            let createdAgain = try request("panel.set", extra: ["panelId": "demo", "panel": panel])
            require(createdAgain["ok"] as? Bool == true, "recreate")
            let modelAgain = try request("model.load", extra: ["modelId": "demo-model", "path": modelPath.path])
            require(modelAgain["ok"] as? Bool == true, "recreate model")
            return name
        }
        let name = try await task.value
        for _ in 0..<200 where FileManager.default.fileExists(atPath: panels.appendingPathComponent(name + ".json").path) { try await Task.sleep(for: .milliseconds(10)) }
        require(!FileManager.default.fileExists(atPath: panels.appendingPathComponent(name + ".json").path), "disconnect cleanup")
        require(displays.created == [100, 101] && displays.removed == [100, 101], "display removal and disconnect cleanup")
        let modelsAfterDisconnect = try FileManager.default.contentsOfDirectory(atPath: ui.appendingPathComponent("api-models").path)
        require(modelsAfterDisconnect.isEmpty, "disconnect removes model requests")
        let exampleDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("pippinVR-Server/examples/addons/api").path
        let exampleTest = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import sys
            sys.path.insert(0, sys.argv[1])
            from pippin_client import PippinClient
            with PippinClient(sys.argv[2]) as client:
                assert client.request('status')['sessionRunning']
                client.request('panel.set', panelId='python-example', panel={'title':'Python','lines':[],'buttons':[]})
                client.request('panel.remove', panelId='python-example')
            """, exampleDirectory, infoURL.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let exampleStatus = try await exampleTest.value
        require(exampleStatus == 0, "example client")
        server.stop()
        require(!FileManager.default.fileExists(atPath: infoURL.path), "stop removes credentials")
        require(!FileManager.default.fileExists(atPath: ui.appendingPathComponent("api-input/controllers.json").path), "stop removes controller state")
        print("PASS: API status, credentials, camera access, controller state, models, panels, images, spatial audio queue, events and disconnect cleanup")
    }
}
