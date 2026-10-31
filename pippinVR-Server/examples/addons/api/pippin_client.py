"""Small example client for PippinVR's local integration API."""
import base64
import json
import os
import socket
from pathlib import Path


class PippinClient:
    def __init__(self, connection_file=None):
        path = Path(connection_file) if connection_file else Path.home() / "Library/Application Support/PippinVR/API/connection.json"
        config = json.loads(path.read_text())
        if config.get("apiVersion") != 1 or config.get("host") != "127.0.0.1":
            raise ValueError("Unsupported or non-local PippinVR API")
        self.token = config["token"]
        self.socket = socket.create_connection((config["host"], config["port"]), timeout=5)
        self.reader = self.socket.makefile("rb")
        self.next_id = 0

    def request(self, method, **fields):
        self.next_id += 1
        request_id = str(self.next_id)
        request = {"apiVersion": 1, "token": self.token, "id": request_id, "method": method, **fields}
        self.socket.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        line = self.reader.readline(65537)
        if not line or len(line) > 65536:
            raise ConnectionError("PippinVR closed the connection or sent a large response")
        reply = json.loads(line)
        if reply.get("id") != request_id:
            raise ConnectionError("Unexpected response")
        if not reply.get("ok"):
            raise RuntimeError(reply.get("error", "Request failed"))
        return reply["result"]

    def set_image(self, panel_id, image_bytes):
        return self.request("panel.image", panelId=panel_id, data=base64.b64encode(image_bytes).decode("ascii"))

    def load_model(self, model_id, path, mode="fixed", degrees_per_second=30, panel_id=None, size=0.22):
        options = {"panelId": panel_id, "size": size} if panel_id is not None else {}
        return self.request("model.load", modelId=model_id, path=str(Path(path).resolve()),
                            rotation={"mode": mode, "degreesPerSecond": degrees_per_second}, **options)

    def model_status(self, model_id):
        return self.request("model.status", modelId=model_id)

    def remove_model(self, model_id):
        return self.request("model.remove", modelId=model_id)

    def controllers(self):
        return self.request("input.controllers")

    def camera_frame(self, eye="left"):
        frame = self.request("camera.frame", eye=eye)
        if frame.get("available"):
            frame["data"] = base64.b64decode(frame["data"])
        return frame

    def push_audio(self, pcm_float32_stereo):
        return self.request("audio.push", data=base64.b64encode(pcm_float32_stereo).decode("ascii"))

    def push_spatial_audio(self, pcm_float32_mono, mode="hrtf", x=0, y=0, z=-1, itd_us=0, ild_db=0, gain=1,
                           reference_distance=1, rolloff=1):
        return self.request("audio.spatial", data=base64.b64encode(pcm_float32_mono).decode("ascii"),
                            mode=mode, x=x, y=y, z=z, itdUs=itd_us, ildDb=ild_db, gain=gain,
                            referenceDistance=reference_distance, rolloff=rolloff)

    def release_audio(self):
        return self.request("audio.release")

    def close(self):
        self.reader.close()
        self.socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


if __name__ == "__main__":
    with PippinClient(os.environ.get("PIPPINVR_API_CONNECTION")) as client:
        print(client.request("status"))
        client.request("panel.set", panelId="example", panel={
            "title": "External application", "lines": ["This panel came from a local API client."],
            "buttons": [{"id": "hello", "label": "Hello"}], "anchor": "dashboard"
        })
        print("Open the headset dashboard and press Hello; press Enter here to read events and close.")
        input()
        print(client.request("events.poll"))
