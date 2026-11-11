/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
package ti.socketline;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * The socket's state machine and argument validation, free of Android and Titanium types so it can be
 * tested on a plain JVM (test/run-android-unit.sh). The iOS module has the same class (TiSocketlineCore),
 * checked against the same test vectors.
 *
 * Every transition returns a Result: what the caller must do with the transport (action) and which
 * events to fire, in order. "close" is produced exactly once.
 */
final class SocketCore
{
	static final int CONNECTING = 0;
	static final int OPEN = 1;
	static final int CLOSING = 2;
	static final int CLOSED = 3;

	/** Nothing to do with the transport. */
	static final int ACTION_NONE = 0;
	/** Start connecting. */
	static final int ACTION_CONNECT = 1;
	/** Send a close frame with the requested code and reason and close the connection. */
	static final int ACTION_SEND_CLOSE = 2;
	/** Tear the transport down now (abort a connect, release). */
	static final int ACTION_TEARDOWN = 3;

	static final String ERROR_INVALID_OPTIONS = "INVALID_OPTIONS";
	static final String ERROR_CLEARTEXT_NOT_PERMITTED = "CLEARTEXT_NOT_PERMITTED";
	static final String ERROR_CONNECT_FAILED = "CONNECT_FAILED";
	static final String ERROR_TLS_FAILED = "TLS_FAILED";
	static final String ERROR_CONNECT_TIMEOUT = "CONNECT_TIMEOUT";
	static final String ERROR_HANDSHAKE_FAILED = "HANDSHAKE_FAILED";
	static final String ERROR_CONNECTION_LOST = "CONNECTION_LOST";
	static final String ERROR_BINARY_FRAME = "BINARY_FRAME";

	static final int ABNORMAL_CLOSURE = 1006;
	static final int NO_STATUS_RECEIVED = 1005;
	static final int DEFAULT_CLOSE_CODE = 1000;
	static final int MAX_REASON_BYTES = 123;

	static final class Event
	{
		final String type;  // open, message, error, close
		final String data;  // message: the text; open: the subprotocol ("" for none); error: the description
		final String error; // error: one of the ERROR_ codes
		final int code;     // close
		final String reason;
		final boolean wasClean;

		private Event(String type, String data, String error, int code, String reason, boolean wasClean)
		{
			this.type = type;
			this.data = data;
			this.error = error;
			this.code = code;
			this.reason = reason;
			this.wasClean = wasClean;
		}

		static Event open(String protocol)
		{
			return new Event("open", protocol == null ? "" : protocol, null, 0, null, false);
		}

		static Event message(String text)
		{
			return new Event("message", text, null, 0, null, false);
		}

		static Event error(String code, String description)
		{
			return new Event("error", description == null ? "" : description, code, 0, null, false);
		}

		static Event close(int code, String reason, boolean wasClean)
		{
			return new Event("close", null, null, code, reason == null ? "" : reason, wasClean);
		}
	}

	static final class Result
	{
		final int action;
		final List<Event> events;

		Result(int action, List<Event> events)
		{
			this.action = action;
			this.events = events;
		}
	}

	private static final Result NOTHING = new Result(ACTION_NONE, Collections.<Event>emptyList());

	private int state = CONNECTING;
	private boolean started;
	private boolean opened;
	private boolean closeRequested;
	private boolean closeFrameReceived;
	private boolean closeFired;
	private int receivedCode;
	private String receivedReason = "";
	private int requestedCode = DEFAULT_CLOSE_CODE;
	private String requestedReason = "";

	synchronized int getState()
	{
		return state;
	}

	synchronized boolean canSend()
	{
		return state == OPEN;
	}

	/** connect(): only the first call on a fresh socket starts connecting. */
	synchronized Result connect()
	{
		if (started || closeFired) {
			return NOTHING;
		}
		started = true;
		return new Result(ACTION_CONNECT, Collections.<Event>emptyList());
	}

	/** The opening handshake completed. TEARDOWN means the socket was closed meanwhile: drop the connection. */
	synchronized Result opened(String protocol)
	{
		if (state != CONNECTING || closeFired || !started) {
			return new Result(ACTION_TEARDOWN, Collections.<Event>emptyList());
		}
		state = OPEN;
		opened = true;
		return new Result(ACTION_NONE, list(Event.open(protocol)));
	}

	/** A text message arrived. Messages that arrive while closing are still delivered, as in browsers. */
	synchronized Result message(String text)
	{
		if ((state != OPEN && state != CLOSING) || closeFired) {
			return NOTHING;
		}
		return new Result(ACTION_NONE, list(Event.message(text)));
	}

	/** A binary message arrived: it is dropped and reported; the connection stays open. */
	synchronized Result binaryMessage()
	{
		if ((state != OPEN && state != CLOSING) || closeFired) {
			return NOTHING;
		}
		return new Result(ACTION_NONE,
						  list(Event.error(ERROR_BINARY_FRAME, "A binary frame was received and dropped: only text frames are supported")));
	}

	/**
	 * close(code, reason), after validateCloseArguments() accepted them. On an open socket the close frame
	 * is sent and the connection closed without waiting for the server's answer (neither platform's
	 * WebSocket stack reads it), so "close" reports this code and reason, clean.
	 */
	synchronized Result requestClose(int code, String reason)
	{
		if (closeFired || state == CLOSING || state == CLOSED) {
			return NOTHING;
		}
		closeRequested = true;
		requestedCode = code;
		requestedReason = reason == null ? "" : reason;
		if (state == CONNECTING) {
			// Never opened: nothing to hand-shake with. Stop connecting and report an abnormal closure.
			return finish(started ? ACTION_TEARDOWN : ACTION_NONE, null, null);
		}
		state = CLOSING;
		return new Result(ACTION_SEND_CLOSE, Collections.<Event>emptyList());
	}

	/** The server's close frame arrived (code 1005 when it carried none) before the app asked to close. */
	synchronized void closeFrameReceived(int code, String reason)
	{
		if (!opened || closeFired || closeFrameReceived || closeRequested) {
			return;
		}
		closeFrameReceived = true;
		receivedCode = code;
		receivedReason = reason == null ? "" : reason;
		if (state == OPEN) {
			state = CLOSING; // the transport answers it and then closes
		}
	}

	/** Connecting failed (also: connect timeout). */
	synchronized Result connectFailed(String errorCode, String description)
	{
		if (closeFired) {
			return NOTHING;
		}
		if (state != CONNECTING) {
			return transportClosed(errorCode, description);
		}
		return finish(ACTION_TEARDOWN, closeRequested ? null : errorCode, description);
	}

	/** The transport is gone. errorCode is null when it closed without an error. */
	synchronized Result transportClosed(String errorCode, String description)
	{
		if (closeFired) {
			return NOTHING;
		}
		if (!opened) {
			String code = errorCode != null ? errorCode : ERROR_CONNECT_FAILED;
			return finish(ACTION_NONE, closeRequested ? null : code, description);
		}
		if (closeFrameReceived) {
			closeFired = true;
			state = CLOSED;
			int code = normalizeReceivedCode(receivedCode);
			boolean clean = code != ABNORMAL_CLOSURE;
			return new Result(ACTION_NONE, list(Event.close(code, clean ? receivedReason : "", clean)));
		}
		if (closeRequested) {
			// The app's close frame was sent on the open connection.
			closeFired = true;
			state = CLOSED;
			return new Result(ACTION_NONE, list(Event.close(requestedCode, requestedReason, true)));
		}
		// Lost without a close frame.
		return finish(ACTION_NONE, ERROR_CONNECTION_LOST, description);
	}

	/** The proxy is being released: stop everything, fire nothing. */
	synchronized Result release()
	{
		if (closeFired) {
			return NOTHING;
		}
		closeFired = true;
		state = CLOSED;
		return new Result(started ? ACTION_TEARDOWN : ACTION_NONE, Collections.<Event>emptyList());
	}

	private Result finish(int action, String errorCode, String description)
	{
		closeFired = true;
		state = CLOSED;
		List<Event> events = new ArrayList<>(2);
		if (errorCode != null) {
			events.add(Event.error(errorCode, description));
		}
		events.add(Event.close(ABNORMAL_CLOSURE, "", false));
		return new Result(action, events);
	}

	private static List<Event> list(Event event)
	{
		List<Event> events = new ArrayList<>(1);
		events.add(event);
		return events;
	}

	// Codes and arguments

	/** A code received in a close frame, as reported by the close event: 1006 when it is not a valid wire code. */
	static int normalizeReceivedCode(int code)
	{
		if (code == NO_STATUS_RECEIVED || isValidWireCode(code)) {
			return code;
		}
		return ABNORMAL_CLOSURE;
	}

	/** Codes an endpoint may send in a close frame (RFC 6455 section 7.4, IANA registry). */
	static boolean isValidWireCode(int code)
	{
		return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999);
	}

	/**
	 * Validates close([code], [reason]). Returns null when valid, otherwise the message of the exception to
	 * throw. code: undefined/null (1000), 1000, or an integer from 3000 to 4999. reason: a string of at most
	 * 123 UTF-8 bytes.
	 */
	static String validateCloseArguments(Object code, Object reason)
	{
		if (code != null) {
			if (!(code instanceof Number)) {
				return "Ti.Socketline: close code must be a number";
			}
			double value = ((Number) code).doubleValue();
			if (value != Math.rint(value) || !(value == 1000 || (value >= 3000 && value <= 4999))) {
				return "Ti.Socketline: close code must be 1000 or an integer from 3000 to 4999";
			}
		}
		if (reason != null) {
			if (!(reason instanceof String)) {
				return "Ti.Socketline: close reason must be a string";
			}
			if (((String) reason).getBytes(StandardCharsets.UTF_8).length > MAX_REASON_BYTES) {
				return "Ti.Socketline: close reason must be at most 123 bytes in UTF-8";
			}
		}
		return null;
	}

	static int closeCodeOrDefault(Object code)
	{
		return code == null ? DEFAULT_CLOSE_CODE : ((Number) code).intValue();
	}

	/**
	 * Validates the createSocket() options read at connect(). Returns null when valid, otherwise a
	 * description for the INVALID_OPTIONS error.
	 */
	static String validateOptions(Object url, Object headers, Object protocols, Object connectTimeout)
	{
		if (!(url instanceof String)) {
			return "url must be a string starting with ws:// or wss://";
		}
		URI uri;
		try {
			uri = new URI((String) url);
		} catch (Exception e) {
			return "url is not a valid URL: " + url;
		}
		String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
		if (!scheme.equals("ws") && !scheme.equals("wss")) {
			return "url must start with ws:// or wss://";
		}
		if (uri.getHost() == null || uri.getHost().isEmpty()) {
			return "url has no host: " + url;
		}
		if (uri.getRawFragment() != null) {
			return "url must not have a fragment";
		}
		String message = validateTimeout("connectTimeout", connectTimeout);
		if (message == null) {
			message = validateHeaders(headers);
		}
		if (message == null) {
			message = validateProtocols(protocols);
		}
		return message;
	}

	private static String validateTimeout(String name, Object value)
	{
		if (value == null) {
			return null;
		}
		if (!(value instanceof Number)) {
			return name + " must be a number of milliseconds";
		}
		double ms = ((Number) value).doubleValue();
		if (!(ms > 0) || ms > Integer.MAX_VALUE) {
			return name + " must be greater than 0";
		}
		return null;
	}

	private static String validateHeaders(Object headers)
	{
		if (headers == null) {
			return null;
		}
		if (!(headers instanceof Map)) {
			return "headers must be an object of strings";
		}
		for (Map.Entry<?, ?> entry : ((Map<?, ?>) headers).entrySet()) {
			String name = String.valueOf(entry.getKey());
			Object value = entry.getValue();
			if (!isToken(name)) {
				return "header name is not valid: " + name;
			}
			if (name.toLowerCase(Locale.ROOT).startsWith("sec-websocket-")) {
				return "header " + name + " is set by the module (use the protocols option for subprotocols)";
			}
			if (!(value instanceof String) && !(value instanceof Number) && !(value instanceof Boolean)) {
				return "header " + name + " must be a string";
			}
			String text = String.valueOf(value);
			if (text.indexOf('\r') >= 0 || text.indexOf('\n') >= 0) {
				return "header " + name + " must not contain line breaks";
			}
		}
		return null;
	}

	/** Returns the subprotocols from the protocols option (a string or an array of strings). Call after validation. */
	static List<String> protocolList(Object protocols)
	{
		List<String> list = new ArrayList<>();
		if (protocols instanceof String) {
			list.add((String) protocols);
		} else if (protocols instanceof Object[]) {
			for (Object item : (Object[]) protocols) {
				list.add((String) item);
			}
		} else if (protocols instanceof List) {
			for (Object item : (List<?>) protocols) {
				list.add((String) item);
			}
		}
		return list;
	}

	private static String validateProtocols(Object protocols)
	{
		if (protocols == null) {
			return null;
		}
		List<?> items;
		if (protocols instanceof String) {
			items = Collections.singletonList(protocols);
		} else if (protocols instanceof Object[]) {
			items = java.util.Arrays.asList((Object[]) protocols);
		} else if (protocols instanceof List) {
			items = (List<?>) protocols;
		} else {
			return "protocols must be a string or an array of strings";
		}
		Set<String> seen = new HashSet<>();
		for (Object item : items) {
			if (!(item instanceof String) || !isToken((String) item)) {
				return "protocol is not a valid token: " + item;
			}
			if (!seen.add((String) item)) {
				return "protocol listed twice: " + item;
			}
		}
		return null;
	}

	/** An HTTP token (RFC 7230 section 3.2.6). */
	static boolean isToken(String value)
	{
		if (value == null || value.isEmpty()) {
			return false;
		}
		for (int i = 0; i < value.length(); i++) {
			char c = value.charAt(i);
			boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
						 || "!#$%&'*+-.^_`|~".indexOf(c) >= 0;
			if (!ok) {
				return false;
			}
		}
		return true;
	}
}
