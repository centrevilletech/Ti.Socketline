/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
package ti.socketline;

import org.appcelerator.kroll.KrollModule;
import org.appcelerator.kroll.annotations.Kroll;

/**
 * Native WebSocket client (RFC 6455) for Titanium: ws:// and wss:// with the platform's TLS.
 * Create sockets with createSocket({ url, headers, connectTimeout }).
 */
@Kroll.module(name = "Socketline", id = "ti.socketline")
public class SocketlineModule extends KrollModule
{
	@Kroll.constant
	public static final int CONNECTING = 0;
	@Kroll.constant
	public static final int OPEN = 1;
	@Kroll.constant
	public static final int CLOSING = 2;
	@Kroll.constant
	public static final int CLOSED = 3;

	public SocketlineModule()
	{
		super();
	}
}
