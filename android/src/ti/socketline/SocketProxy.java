/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
package ti.socketline;

import android.os.Handler;
import android.os.Looper;
import android.security.NetworkSecurityPolicy;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.nio.ByteBuffer;
import java.security.cert.CertificateException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

import javax.net.SocketFactory;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLException;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

import org.appcelerator.kroll.KrollDict;
import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.kroll.common.Log;
import org.appcelerator.titanium.util.TiConvert;
import org.java_websocket.WebSocketImpl;
import org.java_websocket.client.WebSocketClient;
import org.java_websocket.drafts.Draft;
import org.java_websocket.drafts.Draft_6455;
import org.java_websocket.enums.Opcode;
import org.java_websocket.exceptions.InvalidDataException;
import org.java_websocket.extensions.IExtension;
import org.java_websocket.framing.CloseFrame;
import org.java_websocket.framing.Framedata;
import org.java_websocket.handshake.ServerHandshake;
import org.java_websocket.protocols.IProtocol;
import org.java_websocket.protocols.Protocol;

/**
 * One WebSocket connection. Single use, like a browser WebSocket: connect() once, close() once, then
 * create a new socket to reconnect.
 *
 * The state machine is SocketCore (shared contract with iOS, tested on the JVM). This class connects the
 * transport: DNS, TCP and TLS are done here with the platform's default SSLSocketFactory (system TLS
 * versions, the app's network security config, hostname verification) under one connect deadline, then
 * Java-WebSocket (the copy Titanium ships) runs the HTTP upgrade and the framing on that socket.
 *
 * Events: open { protocol }, message { data }, error { error, code }, close { code, reason, wasClean }.
 * They are always delivered on the main (JavaScript) thread, after the call that caused them returned.
 */
@Kroll.proxy(creatableInModule = SocketlineModule.class)
public class SocketProxy extends KrollProxy
{
	private static final String TAG = "TiSocketline";
	private static final int DEFAULT_CONNECT_TIMEOUT = 15000;
	private static final int DEFAULT_CLOSE_TIMEOUT = 5000;
	private static final ScheduledExecutorService TIMERS = Executors.newSingleThreadScheduledExecutor(runnable -> {
		Thread thread = new Thread(runnable, "Ti.Socketline timers");
		thread.setDaemon(true);
		return thread;
	});
	private static final Handler MAIN = new Handler(Looper.getMainLooper());

	private final SocketCore core = new SocketCore();
	private volatile Socket transport;
	private volatile WebSocketClient client;
	private volatile ScheduledFuture<?> connectTimer;
	private volatile ScheduledFuture<?> closeTimer;
	private volatile String protocol = "";
	private volatile Exception lastError;
	private volatile FrameWatchingSocket watched;
	private volatile boolean closeFrameSent;
	private List<String> offeredProtocols = Collections.emptyList();
	private long connectDeadline;
	private int closeTimeout = DEFAULT_CLOSE_TIMEOUT;

	@Override
	public String getApiName()
	{
		return "Ti.Socketline.Socket";
	}

	@Kroll.getProperty
	public int getReadyState()
	{
		return core.getState();
	}

	@Kroll.getProperty
	public String getUrl()
	{
		return TiConvert.toString(getProperty("url"));
	}

	/** The subprotocol the server selected ("" for none, or before open). */
	@Kroll.getProperty
	public String getProtocol()
	{
		return protocol;
	}

	/** Opens the connection. Fires "open", or "error" then "close" when it fails. */
	@Kroll.method
	public void connect()
	{
		if (core.connect().action != SocketCore.ACTION_CONNECT) {
			Log.w(TAG, "connect() ignored: a socket connects once (create a new socket to reconnect)");
			return;
		}
		Object url = getProperty("url");
		Object headers = getProperty("headers");
		Object protocols = getProperty("protocols");
		Object connectTimeoutValue = getProperty("connectTimeout");
		Object closeTimeoutValue = getProperty("closeTimeout");
		String invalid = SocketCore.validateOptions(url, headers, protocols, connectTimeoutValue, closeTimeoutValue);
		if (invalid != null) {
			step(c -> c.connectFailed(SocketCore.ERROR_INVALID_OPTIONS, invalid));
			return;
		}
		final URI uri = URI.create((String) url);
		final String host = uri.getHost();
		final boolean secure = "wss".equals(uri.getScheme().toLowerCase(Locale.ROOT));
		final int port = uri.getPort() != -1 ? uri.getPort() : (secure ? 443 : 80);
		if (!secure && !NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(host)) {
			step(c
				 -> c.connectFailed(SocketCore.ERROR_CLEARTEXT_NOT_PERMITTED,
									"Cleartext ws:// to " + host
										+ " is not permitted by the app's network security config: use wss://"));
			return;
		}
		final int connectTimeout = connectTimeoutValue == null ? DEFAULT_CONNECT_TIMEOUT : ((Number) connectTimeoutValue).intValue();
		closeTimeout = closeTimeoutValue == null ? DEFAULT_CLOSE_TIMEOUT : ((Number) closeTimeoutValue).intValue();
		offeredProtocols = SocketCore.protocolList(protocols);
		final Map<String, String> headerMap = new HashMap<>();
		if (headers instanceof Map) {
			for (Map.Entry<?, ?> entry : ((Map<?, ?>) headers).entrySet()) {
				headerMap.put(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
			}
		}

		connectDeadline = System.currentTimeMillis() + connectTimeout;
		connectTimer = TIMERS.schedule(()
										   -> step(c
												   -> c.connectFailed(SocketCore.ERROR_CONNECT_TIMEOUT,
																	  "No connection within " + connectTimeout + " ms")),
									   connectTimeout, TimeUnit.MILLISECONDS);
		Thread connector =
			new Thread(() -> openTransport(uri, host, port, secure, headerMap), "Ti.Socketline connect");
		connector.setDaemon(true);
		connector.start();
	}

	/** Sends a text frame. Returns false when the socket is not open. */
	@Kroll.method
	public boolean send(String text)
	{
		WebSocketClient c = client;
		if (c == null || text == null || !core.canSend()) {
			return false;
		}
		try {
			c.send(text);
			return true;
		} catch (Exception e) {
			Log.w(TAG, "send failed: " + e.getMessage());
			return false;
		}
	}

	/**
	 * Starts the closing handshake. code: 1000 (default) or 3000 to 4999; reason: at most 123 UTF-8 bytes.
	 * Invalid arguments throw. "close" fires when the server answered, the close timer expired or, while
	 * still connecting, at once with 1006.
	 */
	@Kroll.method
	public void close(@Kroll.argument(optional = true) Object code, @Kroll.argument(optional = true) Object reason)
	{
		String invalid = SocketCore.validateCloseArguments(code, reason);
		if (invalid != null) {
			throw new IllegalArgumentException(invalid);
		}
		final int closeCode = SocketCore.closeCodeOrDefault(code);
		final String closeReason = reason == null ? "" : (String) reason;
		SocketCore.Result result = step(SocketCore::requestClose);
		if (result.action == SocketCore.ACTION_SEND_CLOSE) {
			closeTimer = TIMERS.schedule(() -> step(SocketCore::closeTimedOut), closeTimeout, TimeUnit.MILLISECONDS);
			WebSocketClient c = client;
			if (c != null) {
				// Java-WebSocket's own close() stops reading at once and never sees the server's answer, so the
				// close frame is sent directly; TrackingDraft completes the handshake when the answer arrives.
				try {
					CloseFrame frame = new CloseFrame();
					frame.setCode(closeCode);
					frame.setReason(closeReason);
					closeFrameSent = true;
					c.sendFrame(frame);
				} catch (Exception e) {
					Log.w(TAG, "could not send the close frame: " + e.getMessage()); // the close timer ends it
				}
			}
		}
	}

	@Override
	public void release()
	{
		step(SocketCore::release);
		super.release();
	}

	// Transport

	private void openTransport(URI uri, String host, int port, boolean secure, Map<String, String> headers)
	{
		try {
			Socket socket = connectTcp(host, port);
			if (secure) {
				socket = startTls(socket, host, port);
			}
			if (core.getState() != SocketCore.CONNECTING) {
				closeQuietly(socket);
				return;
			}
			List<IProtocol> protocols = new ArrayList<>();
			for (String p : offeredProtocols) {
				protocols.add(new Protocol(p));
			}
			protocols.add(new Protocol("")); // accept a response without a subprotocol (checked again in onOpen)
			final Socket ready = socket;
			watched = new FrameWatchingSocket(ready);
			Client c = new Client(uri, new TrackingDraft(protocols), headers);
			c.setSocketFactory(new PreparedSocketFactory(watched)); // used as is: no second connect, no TLS wrap
			c.setConnectionLostTimeout(0); // keep-alive is the application's job, as on iOS
			client = c;
			if (core.getState() != SocketCore.CONNECTING) {
				closeQuietly(ready);
				return;
			}
			c.connect();
		} catch (Exception e) {
			step(c -> c.connectFailed(classifyConnectError(e), describe(e)));
		}
	}

	private Socket connectTcp(String host, int port) throws IOException
	{
		InetAddress[] addresses = InetAddress.getAllByName(host);
		IOException last = null;
		for (InetAddress address : addresses) {
			Socket socket = new Socket();
			transport = socket;
			if (core.getState() != SocketCore.CONNECTING) {
				closeQuietly(socket);
				throw new IOException("closed");
			}
			try {
				socket.connect(new InetSocketAddress(address, port), remaining());
				socket.setTcpNoDelay(true);
				socket.setSoTimeout(remaining()); // bounds the TLS and HTTP upgrade reads; cleared on open
				return socket;
			} catch (IOException e) {
				closeQuietly(socket);
				last = e;
			}
		}
		throw last != null ? last : new IOException("No address for " + host);
	}

	private Socket startTls(Socket socket, String host, int port) throws IOException
	{
		// The platform's default factory: system TLS versions (1.3 where available) and the app's network
		// security config (trust anchors, pinning). Certificate validation is never relaxed.
		SSLSocketFactory factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
		SSLSocket ssl = (SSLSocket) factory.createSocket(socket, host, port, true);
		transport = ssl;
		SSLParameters parameters = ssl.getSSLParameters();
		parameters.setEndpointIdentificationAlgorithm("HTTPS");
		ssl.setSSLParameters(parameters);
		ssl.startHandshake();
		// Checked explicitly as well: SSLSocket alone does not verify the host name on every Android version.
		if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, ssl.getSession())) {
			closeQuietly(ssl);
			throw new SSLPeerUnverifiedException("The server's certificate is not valid for " + host);
		}
		return ssl;
	}

	private int remaining()
	{
		long ms = connectDeadline - System.currentTimeMillis();
		return (int) Math.max(1, Math.min(Integer.MAX_VALUE, ms));
	}

	private void teardown()
	{
		cancel(connectTimer);
		cancel(closeTimer);
		Socket socket = transport;
		if (socket != null) {
			closeQuietly(socket); // unblocks the connect thread and Java-WebSocket's read loop
		}
	}

	private class Client extends WebSocketClient
	{
		Client(URI uri, Draft draft, Map<String, String> headers)
		{
			super(uri, draft, headers, 0);
		}

		@Override
		public void onOpen(ServerHandshake handshake)
		{
			String selected = handshake.getFieldValue("Sec-WebSocket-Protocol");
			selected = selected == null ? "" : selected.trim();
			if (!selected.isEmpty() && !offeredProtocols.contains(selected)) {
				final String unexpected = selected;
				step(c -> c.connectFailed(SocketCore.ERROR_HANDSHAKE_FAILED,
										  "The server selected a subprotocol that was not offered: " + unexpected));
				return;
			}
			try {
				Socket socket = transport;
				if (socket != null) {
					socket.setSoTimeout(0); // open: an idle connection must not time out (keep-alive is the app's)
				}
			} catch (IOException e) {
				Log.w(TAG, "could not clear the read timeout: " + e.getMessage());
			}
			cancel(connectTimer);
			protocol = selected;
			final String negotiated = selected;
			step(c -> c.opened(negotiated));
		}

		@Override
		public void onMessage(String message)
		{
			step(c -> c.message(message));
		}

		@Override
		public void onMessage(ByteBuffer bytes)
		{
			step(SocketCore::binaryMessage);
		}

		@Override
		public void onError(Exception error)
		{
			lastError = error;
		}

		@Override
		public void onClose(int code, String reason, boolean remote)
		{
			cancel(connectTimer);
			cancel(closeTimer);
			final Exception error = lastError;
			if (core.getState() == SocketCore.CONNECTING) {
				// TCP and TLS succeeded (they are done before Java-WebSocket starts): the upgrade failed.
				final String errorCode = error instanceof SocketTimeoutException ? SocketCore.ERROR_CONNECT_TIMEOUT
																				 : SocketCore.ERROR_HANDSHAKE_FAILED;
				final String description = error != null ? describe(error) : "The server did not accept the WebSocket upgrade";
				step(c -> c.connectFailed(errorCode, description));
			} else {
				final String description = error != null ? describe(error) : "The connection closed without a closing handshake";
				step(c -> c.transportClosed(error != null ? SocketCore.ERROR_CONNECTION_LOST : null, description));
			}
			closeQuietly(transport);
		}
	}

	/** Draft_6455 that tells the core when the server's close frame arrives (the closing handshake). */
	private class TrackingDraft extends Draft_6455
	{
		TrackingDraft(List<IProtocol> protocols)
		{
			super(Collections.<IExtension>emptyList(), protocols);
		}

		@Override
		public void processFrame(WebSocketImpl webSocketImpl, Framedata frame) throws InvalidDataException
		{
			if (frame.getOpcode() == Opcode.CLOSING) {
				int code = SocketCore.NO_STATUS_RECEIVED;
				String reason = "";
				FrameWatchingSocket socket = watched;
				if (frame instanceof CloseFrame && (socket == null || !socket.lastCloseFrameWasEmpty())) {
					code = ((CloseFrame) frame).getCloseCode();
					reason = ((CloseFrame) frame).getMessage();
				}
				core.closeFrameReceived(code, reason);
				if (closeFrameSent) {
					// The answer to our close frame: the closing handshake is complete, disconnect.
					webSocketImpl.closeConnection(code, reason, true);
					return;
				}
			}
			super.processFrame(webSocketImpl, frame);
		}

		@Override
		public Draft copyInstance()
		{
			List<IProtocol> protocols = new ArrayList<>();
			for (IProtocol p : getKnownProtocols()) {
				protocols.add(p.copyInstance());
			}
			return new TrackingDraft(protocols);
		}
	}

	/** Hands Java-WebSocket the socket this proxy already connected (and secured). */
	private static final class PreparedSocketFactory extends SocketFactory
	{
		private final Socket socket;

		PreparedSocketFactory(Socket socket)
		{
			this.socket = socket;
		}

		@Override
		public Socket createSocket()
		{
			return socket;
		}

		@Override
		public Socket createSocket(String host, int port)
		{
			throw new UnsupportedOperationException();
		}

		@Override
		public Socket createSocket(String host, int port, InetAddress localHost, int localPort)
		{
			throw new UnsupportedOperationException();
		}

		@Override
		public Socket createSocket(InetAddress host, int port)
		{
			throw new UnsupportedOperationException();
		}

		@Override
		public Socket createSocket(InetAddress address, int port, InetAddress localAddress, int localPort)
		{
			throw new UnsupportedOperationException();
		}
	}

	// Events

	private interface Step {
		SocketCore.Result apply(SocketCore core);
	}

	/**
	 * Runs one state-machine step and queues its events on the main thread while holding the core's lock,
	 * so events from different threads are delivered in the order the core decided them.
	 */
	private SocketCore.Result step(Step step)
	{
		SocketCore.Result result;
		synchronized (core)
		{
			result = step.apply(core);
			for (SocketCore.Event event : result.events) {
				post(event);
			}
		}
		if (result.action == SocketCore.ACTION_TEARDOWN) {
			teardown();
		}
		return result;
	}

	private void post(SocketCore.Event event)
	{
		final KrollDict data = new KrollDict();
		switch (event.type) {
			case "open":
				data.put("protocol", event.data);
				break;
			case "message":
				data.put("data", event.data);
				break;
			case "error":
				data.put("error", event.data);
				data.put("code", event.error);
				break;
			default:
				data.put("code", event.code);
				data.put("reason", event.reason);
				data.put("wasClean", event.wasClean);
				break;
		}
		final String type = event.type;
		MAIN.post(() -> fireEvent(type, data));
	}

	// Helpers

	private static String classifyConnectError(Exception e)
	{
		if (e instanceof SocketTimeoutException) {
			return SocketCore.ERROR_CONNECT_TIMEOUT;
		}
		if (e instanceof SSLException || e instanceof CertificateException || e.getCause() instanceof CertificateException) {
			return SocketCore.ERROR_TLS_FAILED;
		}
		return SocketCore.ERROR_CONNECT_FAILED;
	}

	private static String describe(Exception e)
	{
		String message = e.getMessage();
		return message != null && !message.isEmpty() ? message : e.getClass().getSimpleName();
	}

	private static void cancel(ScheduledFuture<?> timer)
	{
		if (timer != null) {
			timer.cancel(false);
		}
	}

	private static void closeQuietly(Socket socket)
	{
		if (socket == null) {
			return;
		}
		try {
			socket.close();
		} catch (IOException ignored) {
			// already closed
		}
	}
}
