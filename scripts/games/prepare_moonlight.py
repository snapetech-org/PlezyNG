#!/usr/bin/env python3
"""Prepare a pinned, app-private Moonlight library; never download a binary APK."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = "{http://schemas.android.com/apk/res/android}"


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def private_manifest(source: Path, destination: Path) -> None:
    ET.register_namespace("android", ANDROID[1:-1])
    tree = ET.parse(source)
    app = tree.getroot().find("application")
    if app is None:
        raise ValueError("Upstream manifest has no application")
    # Host application owns icons, backup, network policy and theme.
    app.attrib.clear()
    for child in list(app):
        if child.tag not in {"activity", "service"}:
            app.remove(child)
            continue
        name = child.get(ANDROID + "name", "")
        if name.startswith("."):
            child.set(ANDROID + "name", "com.limelight" + name)
        child.set(ANDROID + "exported", "false")
        if child.tag == "activity" and ANDROID + "theme" not in child.attrib:
            child.set(ANDROID + "theme", "@style/AppTheme")
        # Embedded streaming belongs to Plezy's task and returns to Games.
        child.attrib.pop(ANDROID + "launchMode", None)
        for intent in list(child.findall("intent-filter")):
            child.remove(intent)
    for permission in list(tree.getroot().findall("uses-permission")):
        if "providers.tv" in permission.get(ANDROID + "name", ""):
            tree.getroot().remove(permission)
        elif permission.get(ANDROID + "name") == "android.permission.CHANGE_WIFI_MULTICAST_STATE":
            permission.attrib.pop(ANDROID + "maxSdkVersion", None)
    ET.indent(tree)
    tree.write(destination, encoding="utf-8", xml_declaration=True)


def patch_http(path: Path) -> None:
    source = path.read_text()
    anchor = "public class NvHTTP {"
    if source.count(anchor) != 1:
        raise ValueError("NvHTTP changed; review cancellation patch")
    source = source.replace(anchor, anchor + """
    // Pleazyng: cancellation stops a pending PIN request without unpairing the host.
    public void cancelPendingRequests() {
        httpClientLongConnectTimeout.dispatcher().cancelAll();
        httpClientLongConnectNoReadTimeout.dispatcher().cancelAll();
        httpClientShortConnectTimeout.dispatcher().cancelAll();
    }
""", 1)
    anchor = ".readTimeout(0, TimeUnit.MILLISECONDS)"
    if source.count(anchor) != 1:
        raise ValueError("NvHTTP changed; review pairing deadline")
    source = source.replace(anchor, anchor + "\n                .callTimeout(90, TimeUnit.SECONDS)", 1)
    path.write_text(source)


def patch_audio(path: Path) -> None:
    source = path.read_text()
    anchor = "    private AudioTrack track;"
    if source.count(anchor) != 1:
        raise ValueError("AndroidAudioRenderer changed; review workspace audio ownership")
    source = source.replace(anchor, anchor + """
    private volatile float outputVolume = 1.0f;

    public void setVolume(float volume) {
        outputVolume = Math.max(0.0f, Math.min(1.0f, volume));
        AudioTrack current = track;
        if (current != null) {
            current.setVolume(outputVolume);
        }
    }
""", 1)
    anchor = "                track = createAudioTrack(channelConfig, sampleRate, bufferSize, lowLatency);\n                track.play();"
    if source.count(anchor) != 1:
        raise ValueError("AndroidAudioRenderer setup changed; review workspace audio ownership")
    source = source.replace(anchor, """                track = createAudioTrack(channelConfig, sampleRate, bufferSize, lowLatency);
                track.setVolume(outputVolume);
                track.play();""", 1)
    path.write_text(source)


def patch_decoder_surface(path: Path) -> None:
    source = path.read_text()
    anchor = """    public void setRenderTarget(SurfaceHolder renderTarget) {
        this.renderTarget = renderTarget;
    }
"""
    replacement = anchor + """
    // Pleazyng: a retained workspace surface can be recreated while the codec is running.
    // Rebind only to another valid SurfaceView-backed target; callers handle a failed switch.
    public boolean rebindRenderTarget(SurfaceHolder renderTarget) {
        if (renderTarget == null || renderTarget.getSurface() == null ||
                !renderTarget.getSurface().isValid()) {
            LimeLog.warning("Cannot rebind Moonlight decoder to an invalid surface");
            return false;
        }

        if (videoDecoder != null) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                LimeLog.warning("Moonlight decoder surface rebinding requires Android 6.0 or newer");
                return false;
            }
            try {
                videoDecoder.setOutputSurface(renderTarget.getSurface());
            } catch (IllegalArgumentException | IllegalStateException error) {
                LimeLog.warning("Moonlight decoder surface rebind failed: " + error.getMessage());
                return false;
            }
        }

        this.renderTarget = renderTarget;
        return true;
    }
"""
    if source.count(anchor) != 1:
        raise ValueError("MediaCodecDecoderRenderer changed; review retained-surface rebind")
    source = source.replace(anchor, replacement, 1)
    path.write_text(source)


def patch_connection(path: Path) -> None:
    source = path.read_text()
    anchor = "    private final Context appContext;"
    if source.count(anchor) != 1:
        raise ValueError("NvConnection changed; review retained-surface cancellation")
    source = source.replace(anchor, anchor + """
    // Pleazyng: a workspace surface may be retired before HTTP app launch finishes.
    private volatile boolean stopRequested;
    private boolean connectionPermitHeld;
    private volatile NvHTTP activeHttpRequest;
""", 1)
    start = """    public void stop() {
        // Interrupt any pending connection. This is thread-safe.
        MoonBridge.interruptConnection();

        // Moonlight-core is not thread-safe with respect to connection start and stop, so
        // we must not invoke that functionality in parallel.
        synchronized (MoonBridge.class) {
            MoonBridge.stopConnection();
            MoonBridge.cleanupBridge();
        }

        // Now a pending connection can be processed
        connectionAllowed.release();
    }
"""
    replacement = """    public void stop() {
        NvHTTP request;
        synchronized (this) {
            stopRequested = true;
            request = activeHttpRequest;
            activeHttpRequest = null;
        }
        if (request != null) {
            request.cancelPendingRequests();
        }
        // A connection that has not acquired the process-wide permit has no native state
        // to stop and must not release another session's permit.
        synchronized (MoonBridge.class) {
            if (!connectionPermitHeld) {
                return;
            }
            MoonBridge.interruptConnection();
            MoonBridge.stopConnection();
            MoonBridge.cleanupBridge();
            connectionPermitHeld = false;
            connectionAllowed.release();
        }
    }
"""
    if source.count(start) != 1:
        raise ValueError("NvConnection stop changed; review retained-surface cancellation")
    source = source.replace(start, replacement, 1)
    start_app = """                ByteBuffer ib = ByteBuffer.allocate(16);
                ib.putInt(context.riKeyId);

                // Acquire the connection semaphore to ensure we only have one
                // connection going at once.
                try {
                    connectionAllowed.acquire();
                } catch (InterruptedException e) {
                    context.connListener.displayMessage(e.getMessage());
                    context.connListener.stageFailed(appName, 0, 0);
                    return;
                }

                // Moonlight-core is not thread-safe with respect to connection start and stop, so
                // we must not invoke that functionality in parallel.
                synchronized (MoonBridge.class) {
                    MoonBridge.setupBridge(videoDecoderRenderer, audioRenderer, connectionListener);
"""
    replacement_start = """                if (stopRequested) {
                    return;
                }

                ByteBuffer ib = ByteBuffer.allocate(16);
                ib.putInt(context.riKeyId);

                // Acquire in bounded intervals so a retired workspace session cannot
                // wait indefinitely behind another receiver.
                boolean acquired = false;
                while (!stopRequested && !acquired) {
                    try {
                        acquired = connectionAllowed.tryAcquire(100, java.util.concurrent.TimeUnit.MILLISECONDS);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
                if (!acquired) {
                    return;
                }

                synchronized (MoonBridge.class) {
                    if (stopRequested) {
                        connectionAllowed.release();
                        return;
                    }
                    connectionPermitHeld = true;
                    MoonBridge.setupBridge(videoDecoderRenderer, audioRenderer, connectionListener);
"""
    if source.count(start_app) != 1:
        raise ValueError("NvConnection start changed; review retained-surface cancellation")
    source = source.replace(start_app, replacement_start, 1)
    anchor = """    private boolean startApp() throws XmlPullParserException, IOException
    {
        NvHTTP h = new NvHTTP(context.serverAddress, context.httpsPort, uniqueId, context.serverCert, cryptoProvider);
"""
    replacement = """    private boolean startApp() throws XmlPullParserException, IOException
    {
        NvHTTP h = new NvHTTP(context.serverAddress, context.httpsPort, uniqueId, context.serverCert, cryptoProvider);
        synchronized (this) {
            if (stopRequested) {
                return false;
            }
            activeHttpRequest = h;
        }
"""
    if source.count(anchor) != 1:
        raise ValueError("NvConnection app launch changed; review HTTP cancellation")
    source = source.replace(anchor, replacement, 1)
    anchor = """                ByteBuffer ib = ByteBuffer.allocate(16);
                ib.putInt(context.riKeyId);"""
    replacement = """                synchronized (NvConnection.this) {
                    activeHttpRequest = null;
                    if (stopRequested) {
                        return;
                    }
                }

                ByteBuffer ib = ByteBuffer.allocate(16);
                ib.putInt(context.riKeyId);"""
    if source.count(anchor) != 1:
        raise ValueError("NvConnection start stage changed; review cancellation boundary")
    source = source.replace(anchor, replacement, 1)
    failed_start = """                        // LiStartConnection() failed, so the caller is not expected
                        // to stop the connection themselves. We need to release their
                        // semaphore count for them.
                        connectionAllowed.release();
                        return;
"""
    if source.count(failed_start) != 1:
        raise ValueError("NvConnection failure cleanup changed; review semaphore ownership")
    source = source.replace(
        failed_start,
        """                        // LiStartConnection() failed, so the caller is not expected
                        // to stop the connection themselves. We need to release their
                        // semaphore count for them.
                        connectionPermitHeld = false;
                        connectionAllowed.release();
                        return;
""",
        1,
    )
    path.write_text(source)


def prepare(destination: Path) -> None:
    lock = json.loads((ROOT / "games-native.lock.json").read_text())["moonlightAndroid"]
    recipe = hashlib.sha256(Path(__file__).read_bytes() + json.dumps(lock, sort_keys=True).encode()).hexdigest()
    marker = destination / ".plezy-recipe"
    if marker.exists() and marker.read_text() == recipe:
        return
    # Never replace someone's checkout or edits. Regeneration requires an explicit clean.
    if destination.exists():
        raise SystemExit(f"Stale prepared sources: remove {destination} and rerun after reviewing the lock/recipe change")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="moonlight-", dir=destination.parent) as staging:
        checkout = Path(staging) / "source"
        run("git", "init", "--quiet", str(checkout))
        run("git", "remote", "add", "origin", lock["repository"], cwd=checkout)
        run("git", "fetch", "--quiet", "--depth=1", "origin", lock["revision"], cwd=checkout)
        run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=checkout)
        if run("git", "rev-parse", "HEAD", cwd=checkout) != lock["revision"]:
            raise ValueError("Unexpected Moonlight revision")
        run("git", "submodule", "update", "--init", "--recursive", "--depth=1", cwd=checkout)
        common = checkout / "app/src/main/jni/moonlight-core/moonlight-common-c"
        if run("git", "rev-parse", "HEAD", cwd=common) != lock["commonRevision"]:
            raise ValueError("Unexpected Moonlight common revision")
        private_manifest(checkout / "app/src/main/AndroidManifest.xml", checkout / "EmbeddedManifest.xml")
        patch_http(checkout / "app/src/main/java/com/limelight/nvstream/http/NvHTTP.java")
        patch_connection(checkout / "app/src/main/java/com/limelight/nvstream/NvConnection.java")
        patch_audio(checkout / "app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java")
        patch_decoder_surface(checkout / "app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java")
        (checkout / ".plezy-recipe").write_text(recipe)
        shutil.move(str(checkout), destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".dart_tool/games/moonlight-android")
    prepare(parser.parse_args().output.resolve())
