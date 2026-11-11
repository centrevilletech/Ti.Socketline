/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
package ti.socketline;

import java.net.URI;
import java.net.URISyntaxException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import org.appcelerator.kroll.KrollDict;
import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.kroll.common.Log;
import org.appcelerator.titanium.util.TiConvert;
import org.java_websocket.client.WebSocketClient;
import org.java_websocket.drafts.Draft_6455;
import org.java_websocket.handshake.ServerHandshake;

/**
 * One WebSocket connection. Single use, like a browser WebSocket: connect() once, close() once, then
 * create a new socket to reconnect.
 *
 * Events: open, message { data }, error { error }, close { code, reason, wasClean }.
 * Events are fired from the socket's thread; Titanium delivers them on the JavaScript thread.
 */
@Kroll.proxy(creatableInModule = SocketlineModule.class)
public class SocketProxy extends KrollProxy
{
	private static final String TAG = "TiSocketline";
	private static final int DEFAULT_CONNECT_TIMEOUT = 15000;

	private WebSocketClient client;
	private volatile int readyState = SocketlineModule.CONNECTING;
	private boolean started = false;

	@Override
	public String getApiName()
	{
		return "Ti.Socketline.Socket";
	}

	@Kroll.getProperty
	public int getReadyState()
	{
		return readyState;
	}

	@Kroll.getProperty
	public String getUrl()
	{
		return TiConvert.toString(getProperty("url"));
	}

	/** Opens the connection. Fires "open", or "error" then "close" when it fails. */
	@Kroll.method
	public void connect()
	{
		if (started) {
			Log.w(TAG, "connect() called twice: create a new socket to reconnect");
			return;
		}
		started = true;

		URI uri;
		try {
			uri = new URI(getUrl());
		} catch (URISyntaxException | NullPointerException e) {
			fail("Invalid url: " + getUrl());
			return;
		}
		String scheme = uri.getScheme();
		if (!"ws".equals(scheme) && !"wss".equals(scheme)) {
			fail("The url must start with ws:// or wss://");
			return;
		}

		Map<String, String> headers = new HashMap<>();
		Object headersValue = getProperty("headers");
		if (headersValue instanceof HashMap) {
			for (Map.Entry<?, ?> entry : ((HashMap<?, ?>) headersValue).entrySet()) {
				headers.put(String.valueOf(entry.getKey()), TiConvert.toString(entry.getValue()));
			}
		}
		int timeout = TiConvert.toInt(getProperty("connectTimeout"), DEFAULT_CONNECT_TIMEOUT);

		client = new WebSocketClient(uri, new Draft_6455(), headers, timeout) {
			@Override
			public void onOpen(ServerHandshake handshake)
			{
				readyState = SocketlineModule.OPEN;
				fireEvent("open", new KrollDict());
			}

			@Override
			public void onMessage(String message)
			{
				KrollDict event = new KrollDict();
				event.put("data", message);
				fireEvent("message", event);
			}

			@Override
			public void onMessage(ByteBuffer bytes)
			{
				// Binary frames are passed on as UTF-8 text, as on iOS.
				onMessage(StandardCharsets.UTF_8.decode(bytes).toString());
			}

			@Override
			public void onError(Exception error)
			{
				KrollDict event = new KrollDict();
				event.put("error", error.getMessage() != null ? error.getMessage() : error.toString());
				fireEvent("error", event);
			}

			@Override
			public void onClose(int code, String reason, boolean remote)
			{
				readyState = SocketlineModule.CLOSED;
				KrollDict event = new KrollDict();
				event.put("code", code);
				event.put("reason", reason != null ? reason : "");
				event.put("wasClean", code == 1000 || code == 1001);
				fireEvent("close", event);
			}
		};
		// Keep-alive is the application's job (most protocols define their own ping), as on iOS.
		client.setConnectionLostTimeout(0);
		client.connect();
	}

	/** Sends a text frame. Returns false when the socket is not open. */
	@Kroll.method
	public boolean send(String text)
	{
		if (client == null || readyState != SocketlineModule.OPEN) {
			return false;
		}
		try {
			client.send(text);
			return true;
		} catch (Exception e) {
			Log.w(TAG, "send failed: " + e.getMessage());
			return false;
		}
	}

	/** Starts the closing handshake (code defaults to 1000). "close" fires when it is done. */
	@Kroll.method
	public void close(@Kroll.argument(optional = true) Object code, @Kroll.argument(optional = true) String reason)
	{
		if (client == null || readyState >= SocketlineModule.CLOSING) {
			return;
		}
		readyState = SocketlineModule.CLOSING;
		client.close(code == null ? 1000 : TiConvert.toInt(code), reason == null ? "" : reason);
	}

	@Override
	public void release()
	{
		if (client != null && readyState < SocketlineModule.CLOSING) {
			client.close();
		}
		super.release();
	}

	private void fail(String message)
	{
		readyState = SocketlineModule.CLOSED;
		KrollDict error = new KrollDict();
		error.put("error", message);
		fireEvent("error", error);
		KrollDict close = new KrollDict();
		close.put("code", 1006);
		close.put("reason", message);
		close.put("wasClean", false);
		fireEvent("close", close);
	}
}
