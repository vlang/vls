#!/usr/bin/env python3
"""Compare validated end-to-end LSP latency on equivalent Go and V projects."""

import argparse
import json
import math
import os
from pathlib import Path
import queue
import statistics
import subprocess
import tempfile
import threading
import time


class Client:
    def __init__(self, command, root, log):
        self.messages = queue.Queue()
        self.sequence = 0
        env = {**os.environ, "GOTELEMETRY": "off", "VLS_DIAG_CACHE_DIR": str(root / ".diag-cache")}
        env.pop("VLS_PERF_LOG", None)
        self.process = subprocess.Popen(
            command, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, env=env,
        )
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        stream = self.process.stdout
        try:
            while header := stream.readline():
                headers = {}
                while header.strip():
                    key, value = header.split(b":", 1)
                    headers[key.lower()] = value.strip()
                    header = stream.readline()
                self.messages.put(json.loads(stream.read(int(headers[b"content-length"]))))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(EOFError("language server closed stdout"))

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        self.write(message)

    def write(self, message):
        payload = json.dumps(message).encode()
        self.process.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
        self.process.stdin.flush()

    def wait_for(self, predicate):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                break
            if isinstance(message, Exception):
                raise message
            if "id" in message and "method" in message:
                result = (
                    [None] * len(message["params"]["items"])
                    if message["method"] == "workspace/configuration" else None
                )
                self.write({"jsonrpc": "2.0", "id": message["id"], "result": result})
            elif predicate(message):
                return message
        raise TimeoutError("language server did not return the expected message within 30s")

    def request(self, method, params):
        self.sequence += 1
        self.send(method, params, self.sequence)
        reply = self.wait_for(lambda message: message.get("id") == self.sequence)
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error']}")
        return reply["result"]

    def close(self, graceful):
        try:
            if graceful and self.process.poll() is None:
                self.request("shutdown", None)
                self.send("exit", None)
                self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.reader.join(timeout=5)
            self.process.stdin.close()
            self.process.stdout.close()


def fixture(root, language, files, type_error):
    (root / "go.mod" if language == "go" else root / "v.mod").write_text(
        "module example.com/lspbench\n\ngo 1.23\n"
        if language == "go" else "Module { name: 'lspbench' }\n"
    )
    header = "package main" if language == "go" else "module main"
    function = "func" if language == "go" else "fn"
    for n in range(files):
        definitions = [
            f"{function} helper{n}_{i}(x int) int {{\n\treturn x + {i}\n}}\n"
            for i in range(30)
        ]
        (root / f"helpers{n}.{language}").write_text(header + "\n\n" + "\n".join(definitions))
    main = root / f"main.{language}"
    source = f"{header}\n\n{function} main() {{\n\tx := helper0_0(1)\n\tprintln(x)\n}}\n"
    if type_error == "return-type":
        source = source.replace("helper0_0(1)", "helper0_0(1) + typed_value()")
        source += f'\n{function} typed_value() int {{\n\treturn 1\n}}\n'
    main.write_text(source)
    return main, source


def benchmark(command, root, language, files, samples, edits, type_error, log):
    main, source = fixture(root, language, files, type_error)
    document = {"uri": main.as_uri()}
    location = {"textDocument": document, "position": {"line": 3, "character": 10}}
    measurements = {}

    def record(label, started):
        measurements.setdefault(label, []).append((time.perf_counter_ns() - started) / 1e6)

    def query(method, label):
        started = time.perf_counter_ns()
        result = client.request("textDocument/" + method, location)
        record(label, started)
        if method == "completion":
            items = result["items"] if isinstance(result, dict) else result
            assert items and any(item["label"] == "helper0_0" for item in items), result
        elif method == "definition":
            locations = result if isinstance(result, list) else [result]
            assert locations and locations[0]["uri"].endswith(f"/helpers0.{language}"), result
        else:
            assert result and "helper0_0" in str(result["contents"]), result

    def diagnostic(version, label, expected):
        last = None

        def matches(message):
            nonlocal last
            if message.get("method") != "textDocument/publishDiagnostics":
                return False
            params = message["params"]
            if params["uri"] == document["uri"]:
                last = params
            return (
                params["uri"] == document["uri"]
                and params.get("version") == version
                and expected(params["diagnostics"])
            )

        try:
            client.wait_for(matches)
        except TimeoutError as error:
            raise TimeoutError(f"{label} at version {version}. Last publish: {last}") from error

    def change(version, text):
        client.send("textDocument/didChange", {
            "textDocument": {**document, "version": version},
            "contentChanges": [{"text": text}],
        })

    started = time.perf_counter_ns()
    client = Client(command, root, log)
    complete = False
    try:
        client.request("initialize", {
            "processId": os.getpid(), "rootUri": root.as_uri(), "rootPath": str(root),
            "workspaceFolders": [{"uri": root.as_uri(), "name": root.name}],
            "capabilities": {"textDocument": {"publishDiagnostics": {"versionSupport": True}}},
        })
        record("initialize", started)
        client.send("initialized", {})
        client.send("textDocument/didOpen", {"textDocument": {
            **document, "languageId": language, "version": 1, "text": source,
        }})
        query("completion", "first completion")
        for _ in range(samples):
            for method in ("completion", "hover", "definition"):
                query(method, method)
        version = 1
        for i in range(edits):
            for method in ("completion", "hover", "definition"):
                version += 1
                change(version, source.replace("(1)", f"({version})"))
                query(method, "edit + " + method)
            for kind in ("syntax", "type"):
                version += 1
                if kind == "syntax":
                    broken = source + f"}} // {i}\n"
                    line, expected_text = len(source.splitlines()), ()
                elif type_error == "return-type":
                    broken = source.replace("return 1", f'return "bad {i}"')
                    line = source.splitlines().index("\treturn 1")
                    expected_text = ("string", "int", "return")
                else:
                    broken = source.replace("println(x)", f"println(missing{i})")
                    line, expected_text = 4, (f"missing{i}",)
                started = time.perf_counter_ns()
                change(version, broken)
                diagnostic(version, kind, lambda items: any(
                    d["range"]["start"]["line"] == line and d.get("severity") == 1
                    and all(text in d["message"] for text in expected_text)
                    for d in items
                ))
                record(kind + " diagnostic", started)
                version += 1
                started = time.perf_counter_ns()
                change(version, source.replace("(1)", f"({version})"))
                diagnostic(version, kind + " recovery", lambda items: not items)
                record(kind + " recovery", started)
        complete = True
    finally:
        client.close(complete)
    return measurements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vls", default="./vls", type=lambda p: str(Path(p).resolve()))
    parser.add_argument("--gopls", default="gopls")
    parser.add_argument("--only", choices=["v", "go"])
    parser.add_argument("--files", type=int, nargs="+", default=[1, 40])
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--edits", type=int, default=5)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--type-error", choices=["undefined-name", "return-type"],
                        default="undefined-name")
    options = parser.parse_args()
    if min(*options.files, options.samples, options.runs) < 1 or options.edits < 0:
        parser.error("files, samples and runs must be positive; edits can be zero")

    for files in options.files:
        print(f"\nSibling files: {files} ({30 * files} declarations), type error: {options.type_error}", flush=True)
        totals = {}
        for run in range(options.runs):
            servers = [("v", [options.vls]), ("go", [options.gopls, "serve"])]
            for language, command in servers[::1 if run % 2 == 0 else -1]:
                if options.only and options.only != language:
                    continue
                with tempfile.TemporaryDirectory(prefix="lsp-latency-") as temp:
                    root = Path(temp).resolve()
                    with tempfile.TemporaryFile(mode="w+b") as log:
                        try:
                            result = benchmark(
                                command, root, language, files, options.samples, options.edits,
                                options.type_error, log
                            )
                        except Exception:
                            log.seek(0)
                            print(log.read().decode(errors="replace"), flush=True)
                            raise
                for metric, values in result.items():
                    totals.setdefault(metric, {}).setdefault(language, []).extend(values)
        print(f"{'milliseconds':<22} {'VLS p50/p95':>18} {'gopls p50/p95':>18}")
        for metric, results in totals.items():
            cells = []
            for language in ("v", "go"):
                values = sorted(results.get(language, []))
                cells.append(
                    f"{statistics.median(values):.2f} / {values[math.ceil(.95 * len(values)) - 1]:.2f}"
                    if values else "–"
                )
            print(f"{metric:<22} {cells[0]:>18} {cells[1]:>18}")


if __name__ == "__main__":
    main()
