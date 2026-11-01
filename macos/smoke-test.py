#!/usr/bin/env python3
"""Start games unattended, one after the other, and report whether they come
up: window, picture, crash, lost GPU device, failed pipelines and shaders
Metal rejects. One run checks a runtime change against many games at once.

usage: smoke-test.py [-t SECONDS] [-o DIR] [-r RUNTIME] [APPID...]
  APPID      games from MacProton's library; default: every installed one
  -t         how long each game runs (default 240)
  -o         where results go (default: smoke-tests/DATE in MacProton's
             Application Support folder)
  -r         dist directory with run.sh (default: ../build-macos/dist next to
             the checkout, as build.sh makes it, else the runtime in
             /Applications/MacProton.app)

Steam must be running and logged in. The test waits while another Windows
game or steamcmd runs, and stops each game it started with wineserver -k.
Before a game's first start it sets up the prefix and runs the game's install
scripts the way MacProton does. The test does not click through menus, so it
shows whether a game reaches its intro or menu, not whether it plays.
"""

import argparse
import datetime
import json
import os
import re
import shlex
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SUPPORT = os.path.expanduser("~/Library/Application Support/MacProton")
UTF8 = dict(os.environ, LC_ALL="en_US.UTF-8")

# Log lines that point at a problem, by the column they are counted in
SIGNATURES = {
    "pipelines": re.compile(r"Failed to create Vulkan (graphics|compute) pipeline"),
    "device_lost": re.compile(r"VK_ERROR_DEVICE_LOST|Lost VkDevice|DXGI_ERROR_DEVICE_(REMOVED|HUNG)"),
    "crash": re.compile(r"Unhandled exception|Unhandled page fault|wine: Assertion|err:seh:.*unhandled"),
}

WINDOWS_SWIFT = r"""
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String)?.lowercased() == "wine" {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, w[kCGWindowOwnerPID as String] ?? 0,
          (b["Width"] as? Double ?? 0) * (b["Height"] as? Double ?? 0))
}
"""


def default_runtime():
    dev = os.path.join(HERE, "..", "..", "build-macos", "dist")
    if os.path.isfile(os.path.join(dev, "run.sh")):
        return os.path.abspath(dev)
    return "/Applications/MacProton.app/Contents/Resources/runtime"


def processes():
    out = subprocess.run(["/bin/ps", "-axww", "-o", "command="], capture_output=True, text=True, env=UTF8).stdout
    return out.splitlines()


def windows_game_running():
    # Wine names its processes by their Windows path; other command lines may mention .exe too.
    return any(re.match(r"[a-z]:\\.*\.exe\b", p, re.I) and "\\windows\\system32\\" not in p.lower()
               for p in processes())


def steamcmd_running():
    return any(p.split(" ")[0].endswith("/steamcmd") for p in processes())


def steam_running():
    return subprocess.run(["/usr/bin/pgrep", "-q", "steam_osx"]).returncode == 0


# Valve's text KeyValues, as far as installscript.vdf uses them
def parse_vdf(text):
    root = {}
    stack, node, key = [], root, None
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"|([{}])|//[^\n]*', text):
        if m.group(2) == "{":
            child = {}
            if key is not None:
                node[key] = child
            stack.append(node)
            node, key = child, None
        elif m.group(2) == "}":
            node, key = (stack.pop() if stack else root), None
        elif m.group(1) is not None:
            if key is None:
                key = m.group(1)
            else:
                node[key], key = m.group(1), None
    return root


def lookup(node, *keys):
    for k in keys:
        if not isinstance(node, dict):
            return None
        node = next((v for kk, v in node.items() if kk.lower() == k.lower()), None)
    return node


def install_steps(install_dir):
    """Same steps and ids as InstallScripts.steps in the app."""
    windows_dir = "Z:" + install_dir.replace("/", "\\")
    steps = []
    for dirpath, dirnames, filenames in os.walk(install_dir):
        rel_dir = os.path.relpath(dirpath, install_dir)
        depth = 0 if rel_dir == "." else rel_dir.count(os.sep) + 1
        dirnames[:] = [d for d in dirnames if depth < 4 and not (depth == 0 and d.startswith("steamapps"))]
        for name in filenames:
            if name.lower() != "installscript.vdf":
                continue
            relative = os.path.normpath(os.path.join(rel_dir, name))
            if "directx/" in relative.lower():
                continue
            try:
                text = open(os.path.join(dirpath, name), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for entry_name, entry in (lookup(parse_vdf(text), "installscript", "Run Process") or {}).items():
                if not isinstance(entry, dict) or lookup(entry, "Requirement_OS", "Is64BitWindows") == "0":
                    continue
                index = 1
                while isinstance(lookup(entry, f"process {index}"), str):
                    program = re.sub("%INSTALLDIR%", lambda _: windows_dir, lookup(entry, f"process {index}"), flags=re.I)
                    if "%" not in program:
                        steps.append((f"{relative}/{entry_name}/{index}", program,
                                      shlex.split(lookup(entry, f"command {index}") or "", posix=False)))
                    index += 1
    return steps


def prepare(runtime, game, prefix, log):
    run = os.path.join(runtime, "run.sh")
    if not os.path.isfile(os.path.join(prefix, "system.reg")):
        subprocess.run([run, "--prepare", str(game["appID"])], stdout=log, stderr=log)
    done_file = os.path.join(prefix, "macproton-installscripts.txt")
    done = set(open(done_file).read().split("\n")) if os.path.exists(done_file) else set()
    for step_id, program, arguments in install_steps(game["installDir"]):
        if step_id in done:
            continue
        status = subprocess.run([run, "--exec", str(game["appID"]), program] + [a.strip('"') for a in arguments],
                                stdout=log, stderr=log).returncode
        if status in (0, 3010, 1638):
            with open(done_file, "a") as f:
                f.write(step_id + "\n")


def game_window(tool):
    """Window number, owning process and area in points of the largest Wine window."""
    out = subprocess.run([tool], capture_output=True, text=True).stdout.split()
    windows = [(float(out[i + 2]), out[i], out[i + 1]) for i in range(0, len(out) - 2, 3)]
    if not windows:
        return None, None, 0
    area, window, pid = max(windows)
    return window, pid, area


def bring_to_front(pid):
    # Many games pause while their window is in the background
    subprocess.run(["/usr/bin/osascript", "-e", 'tell application "System Events" to set frontmost of '
                    f'(first process whose unix id is {pid}) to true'], capture_output=True)


def brightness(png, workdir):
    """Mean brightness 0-255 of a screenshot, to spot black pictures."""
    bmp = os.path.join(workdir, "probe.bmp")
    subprocess.run(["/usr/bin/sips", "-Z", "64", "-s", "format", "bmp", png, "--out", bmp], capture_output=True)
    try:
        data = open(bmp, "rb").read()
    except OSError:
        return None
    offset, = struct.unpack_from("<I", data, 10)
    step = struct.unpack_from("<H", data, 28)[0] // 8
    pixels = data[offset:]
    samples = [sum(pixels[i:i + 3]) / 3 for i in range(0, len(pixels) - step + 1, step)]
    return round(sum(samples) / len(samples)) if samples else None


def new_dumps(paths, since):
    found = []
    for root in paths:
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath[len(root):].count(os.sep) >= 6:
                dirnames[:] = []
            for name in filenames:
                # exFAT drives keep AppleDouble companions named ._*
                if name.lower().endswith((".dmp", ".mdmp")) and not name.startswith("._"):
                    path = os.path.join(dirpath, name)
                    try:
                        if os.path.getmtime(path) >= since:
                            found.append(path)
                    except OSError:
                        pass
    return found


def graphics_api(log_text):
    # Unreal and others probe D3D12 before they settle on D3D11
    if "D3D11InternalCreateDevice: Using" in log_text:
        return "D3D11"
    if "vkd3d_pipeline_library" in log_text or "d3d12_command_queue" in log_text:
        return "D3D12"
    if re.search(r"D3D9DeviceEx|Direct3DCreate9", log_text):
        return "D3D9"
    return "Vulkan" if "Created VkDevice" in log_text else "OpenGL/andere"


def test_game(game, runtime, seconds, out, tool):
    appid = game["appID"]
    prefix = os.path.join(SUPPORT, "prefixes", str(appid))
    exe = game["executable"]
    game_dir = os.path.join(game["installDir"], os.path.dirname(exe))
    log_path = os.path.join(out, f"{appid}.log")
    shots = os.path.join(out, f"{appid}.png")
    dump_dir = os.path.join(out, "shaders", str(appid))
    os.makedirs(dump_dir, exist_ok=True)
    result = {"appID": appid, "name": game["name"], "window": False, "running": False,
              "brightness": None, "dumps": [], "screenshot": None}

    with open(log_path, "w") as log:
        prepare(runtime, game, prefix, log)
        args = shlex.split(game.get("arguments") or "") + shlex.split(game.get("launchOptions") or "")
        env = dict(os.environ, MVK_CONFIG_SHADER_DUMP_DIR=dump_dir)
        started = time.time()
        proc = subprocess.Popen([os.path.join(runtime, "run.sh"), str(appid), game_dir, os.path.basename(exe)] + args,
                                cwd=game_dir, stdout=log, stderr=log, env=env)
        exe_name = os.path.basename(exe).lower()
        while time.time() - started < seconds:
            time.sleep(10)
            alive = any(exe_name in p.lower() for p in processes())
            window, pid, area = game_window(tool)
            if window:
                # The game window may be off screen for a moment, as when it changes mode
                result["window_area"] = max(result.get("window_area", 0), area)
                bring_to_front(pid)
                result["window"] = True
                if subprocess.run(["/usr/sbin/screencapture", "-x", "-l", window, shots]).returncode == 0:
                    result["screenshot"] = shots
            if not alive and time.time() - started > 60:
                break
        result["running"] = any(exe_name in p.lower() for p in processes())
        result["seconds"] = round(time.time() - started)

    env = dict(os.environ, WINEPREFIX=prefix)
    subprocess.run([os.path.join(runtime, "files", "bin", "wineserver"), "-k"], env=env, capture_output=True)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
    time.sleep(3)

    text = open(log_path, encoding="utf-8", errors="replace").read()
    for column, pattern in SIGNATURES.items():
        result[column] = len(pattern.findall(text))
    result["api"] = graphics_api(text)
    result["dumps"] = new_dumps([game["installDir"], os.path.join(prefix, "drive_c", "users")], started)
    if result["screenshot"]:
        result["brightness"] = brightness(shots, out)
    check = subprocess.run([os.path.join(HERE, "check-shaders.sh"), dump_dir], capture_output=True, text=True)
    lines = check.stdout.strip().splitlines()
    m = re.match(r"(\d+) of (\d+)", lines[-1]) if lines else None
    result["shaders_failed"], result["shaders"] = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    result["shader_errors"] = [l.strip() for l in lines[:-1] if l.startswith("    ")][:5]
    return result


def verdict(r):
    if r["crash"] or r["dumps"] or not r["window"]:
        return "crash" if (r["crash"] or r["dumps"]) else "no window"
    if r["device_lost"]:
        return "device lost"
    if not r["running"]:
        return "exited"
    if r["brightness"] is not None and r["brightness"] < 4:
        return "black image"
    # An error message or a launcher rather than the game, check the picture
    if r.get("window_area", 0) < 600 * 400:
        return "message or launcher"
    if r["pipelines"] or r["shaders_failed"]:
        return "runs, shader errors"
    return "runs"


def write_report(results, out, runtime):
    lines = [f"# Smoke test {os.path.basename(out)}", "", f"Runtime: `{runtime}`", "",
             "| Game | API | Result | Pipelines failed | Shaders rejected | Device lost | Image |",
             "|---|---|---|---|---|---|---|"]
    for r in results:
        shot = f"[image]({os.path.basename(r['screenshot'])})" if r["screenshot"] else "–"
        lines.append(f"| {r['name']} | {r['api']} | {verdict(r)} | {r['pipelines']} | "
                     f"{r['shaders_failed']} of {r['shaders']} | {r['device_lost']} | {shot} |")
    for r in results:
        details = [f"- {e}" for e in r["shader_errors"]] + [f"- crash dump: `{d}`" for d in r["dumps"]]
        if details:
            lines += ["", f"## {r['name']}", ""] + details
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(results, f, indent=1, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("-t", type=int, default=240)
    parser.add_argument("-o")
    parser.add_argument("-r", default=default_runtime())
    parser.add_argument("appids", nargs="*", type=int)
    opts = parser.parse_args()

    library = json.load(open(os.path.join(SUPPORT, "library.json")))
    installed = [g for g in library if g["executable"].lower().endswith(".exe")
                 and os.path.isfile(os.path.join(g["installDir"], g["executable"]))]
    games = [g for g in installed if not opts.appids or g["appID"] in opts.appids]
    if not games:
        sys.exit("No matching installed games.")
    if not steam_running():
        sys.exit("Steam is not running; start it and sign in first.")

    out = opts.o or os.path.join(SUPPORT, "smoke-tests", datetime.datetime.now().strftime("%Y-%m-%d-%H%M"))
    os.makedirs(out, exist_ok=True)
    tool = os.path.join(out, "wine-windows")
    subprocess.run(["/usr/bin/swiftc", "-O", "-", "-o", tool], input=WINDOWS_SWIFT, text=True, check=True,
                   capture_output=True)

    results = []
    for game in games:
        while windows_game_running() or steamcmd_running():
            print("Waiting, a game or steamcmd is running …", flush=True)
            time.sleep(60)
        print(f"{game['name']} …", flush=True)
        r = test_game(game, opts.r, opts.t, out, tool)
        print(f"  {verdict(r)}", flush=True)
        results.append(r)
        write_report(results, out, opts.r)
    print(os.path.join(out, "report.md"))


if __name__ == "__main__":
    main()
