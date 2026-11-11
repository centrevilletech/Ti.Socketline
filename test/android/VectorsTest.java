/**
 * Ti.Socketline — runs test/vectors.json against SocketCore.java on a plain JVM.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
package ti.socketline;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public final class VectorsTest
{
	private static int passed, failed;

	public static void main(String[] args) throws Exception
	{
		Map<String, Object> v = asMap(new Json(new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8)).value());

		for (Object o : asList(v.get("closeArguments"))) {
			Map<String, Object> c = asMap(o);
			String message = SocketCore.validateCloseArguments(c.get("code"), c.get("reason"));
			boolean valid = Boolean.TRUE.equals(c.get("valid"));
			if (valid && message == null) {
				pass();
			} else if (!valid && message != null && (!c.containsKey("error") || Objects.equals(c.get("error"), message))) {
				pass();
			} else {
				fail("closeArguments: " + c.get("name"), "expected " + (valid ? "valid" : "error '" + c.get("error") + "'") + ", got " + (message == null ? "valid" : "'" + message + "'"));
			}
		}

		for (Object o : asList(v.get("options"))) {
			Map<String, Object> c = asMap(o);
			String message = SocketCore.validateOptions(c.get("url"), c.get("headers"), c.get("protocols"), c.get("connectTimeout"), c.get("closeTimeout"));
			boolean valid = Boolean.TRUE.equals(c.get("valid"));
			if (valid == (message == null)) {
				pass();
			} else {
				fail("options: " + c.get("name"), "expected " + (valid ? "valid" : "invalid") + ", got " + (message == null ? "valid" : "'" + message + "'"));
			}
		}

		for (Object o : asList(v.get("normalizeReceivedCode"))) {
			List<Object> pair = asList(o);
			int in = ((Number) pair.get(0)).intValue();
			int expected = ((Number) pair.get(1)).intValue();
			int actual = SocketCore.normalizeReceivedCode(in);
			if (actual == expected) {
				pass();
			} else {
				fail("normalizeReceivedCode " + in, "expected " + expected + ", got " + actual);
			}
		}

		for (Object o : asList(v.get("sequences"))) {
			Map<String, Object> c = asMap(o);
			String name = "sequence: " + c.get("name");
			SocketCore core = new SocketCore();
			List<String> actions = new ArrayList<>();
			List<String> events = new ArrayList<>();
			boolean ok = true;
			for (Object s : asList(c.get("steps"))) {
				List<Object> step = asList(s);
				String op = (String) step.get(0);
				SocketCore.Result r = null;
				switch (op) {
					case "connect": r = core.connect(); break;
					case "opened": r = core.opened((String) step.get(1)); break;
					case "message": r = core.message((String) step.get(1)); break;
					case "binary": r = core.binaryMessage(); break;
					case "requestClose": r = core.requestClose(); break;
					case "closeFrame": core.closeFrameReceived(((Number) step.get(1)).intValue(), (String) step.get(2)); break;
					case "connectFailed": r = core.connectFailed((String) step.get(1), "test"); break;
					case "closeTimedOut": r = core.closeTimedOut(); break;
					case "transportClosed": r = core.transportClosed((String) step.get(1), "test"); break;
					case "release": r = core.release(); break;
					case "canSend":
						if (core.canSend() != Boolean.TRUE.equals(step.get(1))) {
							fail(name, "canSend expected " + step.get(1) + " before step " + actions.size());
							ok = false;
						}
						break;
					default: throw new IllegalArgumentException("unknown step " + op);
				}
				if (r != null) {
					if (r.action != SocketCore.ACTION_NONE) {
						actions.add(new String[] { "NONE", "CONNECT", "SEND_CLOSE", "TEARDOWN" }[r.action]);
					}
					for (SocketCore.Event e : r.events) {
						events.add(describe(e));
					}
				}
			}
			ok &= expect(name, "actions", c.get("actions"), actions);
			ok &= expect(name, "events", c.get("events"), events);
			ok &= expect(name, "state", ((Number) c.get("state")).intValue(), core.getState());
			if (ok) {
				pass();
			}
		}

		System.out.println("android: " + passed + " passed, " + failed + " failed");
		System.exit(failed == 0 ? 0 : 1);
	}

	static String describe(SocketCore.Event e)
	{
		switch (e.type) {
			case "open": return "open:" + e.data;
			case "message": return "message:" + e.data;
			case "error": return "error:" + e.error;
			default: return "close:" + e.code + ":" + e.reason + ":" + e.wasClean;
		}
	}

	static boolean expect(String name, String what, Object expected, Object actual)
	{
		if (Objects.equals(String.valueOf(expected), String.valueOf(actual))) {
			return true;
		}
		fail(name, what + ": expected " + expected + ", got " + actual);
		return false;
	}

	static void pass()
	{
		passed++;
	}

	static void fail(String name, String why)
	{
		failed++;
		System.out.println("FAIL " + name + ": " + why);
	}

	@SuppressWarnings("unchecked")
	static Map<String, Object> asMap(Object o)
	{
		return (Map<String, Object>) o;
	}

	@SuppressWarnings("unchecked")
	static List<Object> asList(Object o)
	{
		return (List<Object>) o;
	}

	/** Minimal JSON reader: objects become LinkedHashMap, numbers Long or Double, like Titanium's bridge. */
	static final class Json
	{
		private final String s;
		private int i;

		Json(String s)
		{
			this.s = s;
		}

		Object value()
		{
			ws();
			char c = s.charAt(i);
			if (c == '{') {
				i++;
				Map<String, Object> m = new LinkedHashMap<>();
				ws();
				if (s.charAt(i) == '}') {
					i++;
					return m;
				}
				while (true) {
					ws();
					String k = string();
					ws();
					i++; // :
					m.put(k, value());
					ws();
					if (s.charAt(i++) == '}') {
						return m;
					}
				}
			}
			if (c == '[') {
				i++;
				List<Object> l = new ArrayList<>();
				ws();
				if (s.charAt(i) == ']') {
					i++;
					return l;
				}
				while (true) {
					l.add(value());
					ws();
					if (s.charAt(i++) == ']') {
						return l;
					}
				}
			}
			if (c == '"') {
				return string();
			}
			if (s.startsWith("true", i)) {
				i += 4;
				return Boolean.TRUE;
			}
			if (s.startsWith("false", i)) {
				i += 5;
				return Boolean.FALSE;
			}
			if (s.startsWith("null", i)) {
				i += 4;
				return null;
			}
			int start = i;
			while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) {
				i++;
			}
			String n = s.substring(start, i);
			return n.contains(".") || n.contains("e") || n.contains("E") ? (Object) Double.valueOf(n) : (Object) Long.valueOf(n);
		}

		private String string()
		{
			StringBuilder b = new StringBuilder();
			i++; // opening quote
			while (true) {
				char c = s.charAt(i++);
				if (c == '"') {
					return b.toString();
				}
				if (c == '\\') {
					char e = s.charAt(i++);
					switch (e) {
						case 'n': b.append('\n'); break;
						case 'r': b.append('\r'); break;
						case 't': b.append('\t'); break;
						case 'u': b.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
						default: b.append(e);
					}
				} else {
					b.append(c);
				}
			}
		}

		private void ws()
		{
			while (i < s.length() && Character.isWhitespace(s.charAt(i))) {
				i++;
			}
		}
	}
}
