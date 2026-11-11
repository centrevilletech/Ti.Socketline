/**
 * Ti.Socketline — native WebSocket client for Titanium.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
package ti.socketline;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.net.SocketAddress;
import java.net.SocketException;

/**
 * The connected (and, for wss, secured) socket as Java-WebSocket sees it. It only delegates, except that
 * it watches the frame headers the server sends: Java-WebSocket reports a close frame without a status
 * code as 1000, and RFC 6455 says that is 1005 ("no status received"), which is what this module reports
 * on both platforms. The watcher reads nothing itself and never changes the bytes.
 */
final class FrameWatchingSocket extends Socket
{
	private final Socket socket;
	private final InputStream input;
	private volatile boolean lastCloseFrameEmpty;

	FrameWatchingSocket(Socket socket) throws IOException
	{
		this.socket = socket;
		this.input = new Watcher(socket.getInputStream());
	}

	/** True when the most recent close frame from the server had no payload (no status code). */
	boolean lastCloseFrameWasEmpty()
	{
		return lastCloseFrameEmpty;
	}

	Socket unwrap()
	{
		return socket;
	}

	@Override
	public InputStream getInputStream()
	{
		return input;
	}

	@Override
	public OutputStream getOutputStream() throws IOException
	{
		return socket.getOutputStream();
	}

	@Override
	public boolean isConnected()
	{
		return socket.isConnected();
	}

	@Override
	public boolean isClosed()
	{
		return socket.isClosed();
	}

	@Override
	public synchronized void close() throws IOException
	{
		socket.close();
	}

	@Override
	public void setTcpNoDelay(boolean on) throws SocketException
	{
		socket.setTcpNoDelay(on);
	}

	@Override
	public boolean getTcpNoDelay() throws SocketException
	{
		return socket.getTcpNoDelay();
	}

	@Override
	public void setReuseAddress(boolean on) throws SocketException
	{
		socket.setReuseAddress(on);
	}

	@Override
	public boolean getReuseAddress() throws SocketException
	{
		return socket.getReuseAddress();
	}

	@Override
	public synchronized void setSoTimeout(int timeout) throws SocketException
	{
		socket.setSoTimeout(timeout);
	}

	@Override
	public synchronized int getSoTimeout() throws SocketException
	{
		return socket.getSoTimeout();
	}

	@Override
	public SocketAddress getLocalSocketAddress()
	{
		return socket.getLocalSocketAddress();
	}

	@Override
	public SocketAddress getRemoteSocketAddress()
	{
		return socket.getRemoteSocketAddress();
	}

	@Override
	public InetAddress getInetAddress()
	{
		return socket.getInetAddress();
	}

	@Override
	public int getPort()
	{
		return socket.getPort();
	}

	@Override
	public void shutdownInput() throws IOException
	{
		socket.shutdownInput();
	}

	@Override
	public void shutdownOutput() throws IOException
	{
		socket.shutdownOutput();
	}

	/**
	 * Follows the frame boundaries of the server's stream (after the HTTP response) to see each frame's
	 * opcode and payload length. Server frames are not masked (RFC 6455 5.1), but a mask is skipped anyway.
	 */
	private final class Watcher extends FilterInputStream
	{
		private static final int HTTP = 0, HEAD0 = 1, HEAD1 = 2, LENGTH = 3, MASK = 4, PAYLOAD = 5;
		private int state = HTTP;
		private int httpMatch; // how much of "\r\n\r\n" has been seen
		private int opcode;
		private boolean masked;
		private int lengthBytes;
		private long length;
		private int maskBytes;
		private long payloadLeft;

		Watcher(InputStream in)
		{
			super(in);
		}

		@Override
		public int read() throws IOException
		{
			int b = super.read();
			if (b >= 0) {
				feed(b);
			}
			return b;
		}

		@Override
		public int read(byte[] buffer, int offset, int count) throws IOException
		{
			int n = super.read(buffer, offset, count);
			for (int i = 0; i < n; i++) {
				feed(buffer[offset + i] & 0xff);
			}
			return n;
		}

		private void feed(int b)
		{
			switch (state) {
				case HTTP:
					// The upgrade response ends with an empty line.
					httpMatch = (b == (httpMatch % 2 == 0 ? '\r' : '\n')) ? httpMatch + 1 : (b == '\r' ? 1 : 0);
					if (httpMatch == 4) {
						state = HEAD0;
					}
					break;
				case HEAD0:
					opcode = b & 0x0f;
					state = HEAD1;
					break;
				case HEAD1:
					masked = (b & 0x80) != 0;
					length = b & 0x7f;
					if (length == 126 || length == 127) {
						lengthBytes = length == 126 ? 2 : 8;
						length = 0;
						state = LENGTH;
					} else {
						headerDone();
					}
					break;
				case LENGTH:
					length = (length << 8) | b;
					if (--lengthBytes == 0) {
						headerDone();
					}
					break;
				case MASK:
					if (--maskBytes == 0) {
						payloadStart();
					}
					break;
				case PAYLOAD:
					if (--payloadLeft == 0) {
						state = HEAD0;
					}
					break;
				default:
					break;
			}
		}

		private void headerDone()
		{
			if (opcode == 0x8) {
				lastCloseFrameEmpty = length == 0;
			}
			if (masked) {
				maskBytes = 4;
				state = MASK;
			} else {
				payloadStart();
			}
		}

		private void payloadStart()
		{
			payloadLeft = length;
			state = payloadLeft == 0 ? HEAD0 : PAYLOAD;
		}
	}
}
