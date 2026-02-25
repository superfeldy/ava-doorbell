"""
AVA Doorbell v4.0 — WebSocket Routes

Native FastAPI WebSocket proxies for MSE video streams and two-way audio.
Replaces V3's flask-sock + websocket-client threading relay with clean async code.
"""

import asyncio
import logging
import ssl as ssl_module
from urllib.parse import quote

import aiohttp
from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from .. import auth, config as config_module

logger = logging.getLogger(__name__)
router = APIRouter(tags=["websocket"])


@router.websocket("/api/ws-proxy")
async def ws_proxy(ws: WebSocket, src: str = Query("")):
    """WebSocket proxy to go2rtc for MSE video streams.

    Browser connects: wss://host:5000/api/ws-proxy?src=camera_id
    This relays to: ws://localhost:1984/api/ws?src=camera_id
    """
    if not src:
        await ws.accept()
        await ws.send_json({"error": "Missing src parameter"})
        await ws.close()
        return

    await ws.accept()

    config = config_module.load_config()
    server = config.get("server", {})
    go2rtc_port = server.get("go2rtc_port", 1984)
    go2rtc_url = f"ws://localhost:{go2rtc_port}/api/ws?src={quote(src)}"

    logger.info(f"[ws-proxy] Opening connection to go2rtc for stream: {src}")

    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(go2rtc_url, timeout=10) as go2rtc_ws:
                # Bidirectional relay using asyncio tasks
                async def browser_to_go2rtc():
                    try:
                        while True:
                            msg = await ws.receive()
                            if msg["type"] == "websocket.disconnect":
                                break
                            if "text" in msg:
                                await go2rtc_ws.send_str(msg["text"])
                            elif "bytes" in msg:
                                await go2rtc_ws.send_bytes(msg["bytes"])
                    except WebSocketDisconnect:
                        pass
                    except Exception as e:
                        logger.debug(f"[ws-proxy] browser→go2rtc ended: {e}")

                async def go2rtc_to_browser():
                    try:
                        async for msg in go2rtc_ws:
                            if msg.type == aiohttp.WSMsgType.BINARY:
                                await ws.send_bytes(msg.data)
                            elif msg.type == aiohttp.WSMsgType.TEXT:
                                await ws.send_text(msg.data)
                            elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                                break
                    except Exception as e:
                        logger.debug(f"[ws-proxy] go2rtc→browser ended: {e}")

                # Run both directions; cancel peer when one side disconnects
                tasks = [
                    asyncio.create_task(browser_to_go2rtc()),
                    asyncio.create_task(go2rtc_to_browser()),
                ]
                try:
                    done, pending = await asyncio.wait(
                        tasks, return_when=asyncio.FIRST_COMPLETED
                    )
                    for t in pending:
                        t.cancel()
                    # Await cancelled tasks to suppress warnings
                    await asyncio.gather(*pending, return_exceptions=True)
                except Exception:
                    for t in tasks:
                        t.cancel()

    except aiohttp.ClientError as e:
        logger.error(f"[ws-proxy] Failed to connect to go2rtc: {e}")
        try:
            await ws.send_json({"error": f"Cannot reach go2rtc: {e}"})
        except Exception:
            pass
    except Exception as e:
        logger.debug(f"[ws-proxy] Connection ended: {e}")
    finally:
        try:
            await ws.close()
        except Exception:
            pass
        logger.info(f"[ws-proxy] Connection closed for stream: {src}")


@router.websocket("/api/ws-talk")
async def ws_talk_proxy(ws: WebSocket, token: str = Query("")):
    """WebSocket proxy to ava-talk relay for two-way audio.

    Browser connects: wss://host:5000/api/ws-talk?token=<api_token>
    This relays to: ws(s)://localhost:5001 (talk relay)
    Requires a valid API token (talk sends audio to doorbell speaker).
    """
    # Validate API token before accepting the connection
    config = config_module.load_config()
    token_hash = config.get("admin", {}).get("api_token_hash", "")
    if not token or not token_hash or not auth.verify_token(token, token_hash):
        await ws.close(code=4401, reason="Unauthorized — valid API token required")
        return

    await ws.accept()

    server = config.get("server", {})
    talk_port = server.get("talk_port", 5001)

    # Try wss first, fall back to ws
    talk_ws = None
    talk_session = None

    try:
        talk_session = aiohttp.ClientSession()

        for proto in ("wss", "ws"):
            talk_url = f"{proto}://localhost:{talk_port}"
            try:
                ssl_ctx = None
                if proto == "wss":
                    ssl_ctx = ssl_module.SSLContext(ssl_module.PROTOCOL_TLS_CLIENT)
                    ssl_ctx.check_hostname = False
                    ssl_ctx.verify_mode = ssl_module.CERT_NONE

                talk_ws = await talk_session.ws_connect(
                    talk_url, timeout=30, ssl=ssl_ctx
                )
                logger.info(f"[ws-talk] Connected to talk relay at {talk_url}")
                break
            except Exception as e:
                logger.debug(f"[ws-talk] {proto} connection failed: {e}")
                talk_ws = None
    except Exception as e:
        logger.error(f"[ws-talk] Failed to create session: {e}")
        if talk_session:
            await talk_session.close()
        await ws.close()
        return

    if talk_ws is None:
        logger.warning(f"[ws-talk] Talk relay unreachable on port {talk_port}")
        try:
            await ws.send_json({"error": "Cannot reach talk relay — is ava-talk running?"})
        except Exception:
            pass
        await talk_session.close()
        await ws.close()
        return

    try:
        async def browser_to_talk():
            try:
                while True:
                    msg = await ws.receive()
                    if msg["type"] == "websocket.disconnect":
                        break
                    if "text" in msg:
                        await talk_ws.send_str(msg["text"])
                    elif "bytes" in msg:
                        await talk_ws.send_bytes(msg["bytes"])
            except WebSocketDisconnect:
                pass
            except Exception as e:
                logger.debug(f"[ws-talk] browser→talk ended: {e}")

        async def talk_to_browser():
            try:
                async for msg in talk_ws:
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        await ws.send_bytes(msg.data)
                    elif msg.type == aiohttp.WSMsgType.TEXT:
                        await ws.send_text(msg.data)
                    elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                        break
            except Exception as e:
                logger.debug(f"[ws-talk] talk→browser ended: {e}")

        async def heartbeat():
            """Ping talk relay every 10s to keep connection alive."""
            try:
                while True:
                    await asyncio.sleep(10)
                    if talk_ws and not talk_ws.closed:
                        await talk_ws.ping()
                    else:
                        break
            except Exception:
                pass

        # Run all directions; cancel peers when one side disconnects
        tasks = [
            asyncio.create_task(browser_to_talk()),
            asyncio.create_task(talk_to_browser()),
            asyncio.create_task(heartbeat()),
        ]
        try:
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_COMPLETED
            )
            for t in pending:
                t.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        except Exception:
            for t in tasks:
                t.cancel()
    except Exception as e:
        logger.debug(f"[ws-talk] Relay error: {e}")
    finally:
        try:
            await talk_ws.close()
        except Exception:
            pass
        try:
            await talk_session.close()
        except Exception:
            pass
        try:
            await ws.close()
        except Exception:
            pass
        logger.info("[ws-talk] Connection closed")
