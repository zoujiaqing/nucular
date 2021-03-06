/* Copyleft meh. [http://meh.paranoid.pk | meh@paranoici.org]
 *
 * This file is part of nucular.
 *
 * nucular is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * nucular is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with nucular. If not, see <http://www.gnu.org/licenses/>.
 ****************************************************************************/

module nucular.server;

import std.exception;
import std.socket;
import std.conv;
import std.string;
import std.file;

import nucular.reactor : Reactor, SecureInternetAddress, SecureInternet6Address;
import nucular.descriptor;
import nucular.connection;

abstract class Server
{
	this (Reactor reactor, Address address)
	{
		_reactor = reactor;
		_address = address;
	}

	this (Reactor reactor, Descriptor descriptor)
	{
		_reactor    = reactor;
		_connection = (new Connection).watched(reactor, descriptor);
		_address    = new UnknownAddress;
	}

	~this ()
	{
		stop();
	}

	abstract Descriptor start ();

	void stop ()
	{
		if (!isRunning) {
			return;
		}

		_running = false;

		reactor.stopServer(this);
	}

	Connection connection ()
	{
		return _connection;
	}

	@property block (void delegate (Connection) block)
	{
		_block = block;
	}

	@property handler (TypeInfo_Class handler)
	{
		_handler = handler;
	}

	@property address ()
	{
		return _address;
	}

	@property isRunning ()
	{
		return _running;
	}

	@property reactor ()
	{
		return _reactor;
	}

	Descriptor to(T : Descriptor) ()
	{
		return _connection.to!Descriptor;
	}

	override string toString ()
	{
		return "Server(" ~ _connection.to!Descriptor.toString() ~ ")";
	}

protected:
	Reactor _reactor;

	Address    _address;
	Connection _connection;

	TypeInfo_Class             _handler;
	void delegate (Connection) _block;

	bool _running;
}

class TcpServer : Server
{
	this (Reactor reactor, Address address)
	{
		super(reactor, address);
	}

	override Descriptor start ()
	{
		if (_connection) {
			return _connection.to!Descriptor;
		}

		_socket = new TcpSocket;

		_connection = (new Connection).watched(reactor, new Descriptor(_socket));
		_connection.protocol     = "tcp";
		_connection.asynchronous = true;
		_connection.reuseAddr    = true;

		_socket.bind(address);
		_socket.listen(reactor.backlog);

		_running = true;

		return _connection.to!Descriptor;
	}

	Connection accept ()
	{
		Socket socket;

		try {
			socket = _socket.accept();
		}
		catch {
			return null;
		}

		auto connection = cast (Connection) _handler.create();
		auto descriptor = new Descriptor(socket);

		connection.protocol = "tcp";
		connection.accepted(this, descriptor);
		connection.addresses();
		if (_block) {
			_block(connection);
		}
		connection.initialized();

		if (auto security = cast (SecureInternetAddress) address) {
			connection.secure(security.context, security.verify);
		}
		else if (auto security = cast (SecureInternet6Address) address) {
			connection.secure(security.context, security.verify);
		}

		return connection;
	}

private:
	TcpSocket _socket;
}

class UdpServer : Server
{
	this (Reactor reactor, Address address)
	{
		super(reactor, address);
	}

	override Descriptor start ()
	{
		if (_connection) {
			return _connection.to!Descriptor;
		}

		_socket = new UdpSocket;

		_connection = (new Connection).watched(reactor, new Descriptor(_socket));
		_connection.protocol     = "udp";
		_connection.asynchronous = true;
		_connection.reuseAddr    = true;

		_socket.bind(address);

		_running = true;

		return _connection.to!Descriptor;
	}

	override Connection connection ()
	{
		if (_client) {
			return _client;
		}

		_client = cast (Connection) _handler.create();

		_client.protocol = "udp";
		_client.accepted(this, _connection.to!Descriptor);
		if (_block) {
			_block(_client);
		}
		_client.initialized();

		return _client;
	}

private:
	UdpSocket  _socket;
	Connection _client;
}

version (Posix) {
	public import core.sys.posix.unistd : mode_t;

	import core.sys.posix.unistd;
	import core.sys.posix.fcntl;
	import core.sys.posix.sys.socket;
	import core.sys.posix.sys.stat;
	import core.sys.posix.sys.un;

	class UnixAddress : Address
	{
		this (string path)
		{
			enforce(path.length + 1 <= _addr.sun_path.length);

			_length = cast (socklen_t) (_addr.sun_path.offsetof + path.length + 1);

			_addr = cast (sockaddr_un*) (new ubyte[_length]).ptr;
			_addr.sun_family                     = AF_UNIX;
			_addr.sun_path.ptr[0 .. path.length] = cast (byte[]) path;
			_addr.sun_path.ptr[path.length]      = 0;
		}

		override sockaddr* name()
		{
			return cast (sockaddr*) _addr;
		}

		override const (sockaddr)* name () const
		{
			return cast (const (sockaddr)*) _addr;
		}

		override socklen_t nameLen() const
		{
			return _length;
		}

		@property string path () const
		{
			return (cast (char*) _addr.sun_path.ptr).to!string;
		}

		override string toString () const
		{
			return path;
		}

	private:
		sockaddr_un* _addr;
		socklen_t    _length;
	}

	class UnixServer : Server
	{
		this (Reactor reactor, Address address)
		{
			if (!cast (UnixAddress) address) {
				throw new Exception("you can only bind to an UnixAddress");
			}

			super(reactor, address);
		}

		override Descriptor start ()
		{
			if (_connection) {
				return _connection.to!Descriptor;
			}

			_socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);

			_connection = (new Connection).watched(reactor, new Descriptor(_socket));
			_connection.protocol     = "unix";
			_connection.asynchronous = true;

			_socket.bind(address);
			_socket.listen(reactor.backlog);

			_running = true;

			return _connection.to!Descriptor;
		}

		override void stop ()
		{
			if (!isRunning) {
				return;
			}

			remove((cast (UnixAddress) address).path);

			super.stop();
		}

		Connection accept ()
		{
			Socket socket;

			try {
				socket = _socket.accept();
			}
			catch {
				return null;
			}

			auto connection = cast (Connection) _handler.create();
			auto descriptor = new Descriptor(socket);

			connection.protocol = "unix";
			connection.accepted(this, descriptor);
			connection.addresses();
			if (_block) {
				_block(connection);
			}
			connection.initialized();

			return connection;
		}

	private:
		Socket _socket;
	}

	class NamedPipeAddress : UnknownAddress
	{
		this (string path, mode_t permissions = octal!666)
		{
			_path        = path;
			_permissions = permissions;
		}

		this (string path, bool read)
		{
			this(path);

			_readable = true;
		}

		this (string path, mode_t permissions, bool read)
		{
			this(path, permissions);

			_readable = true;
		}

		@property isReadable ()
		{
			return _readable;
		}

		@property isWritable ()
		{
			return !isReadable;
		}

		@property path ()
		{
			return _path;
		}

		@property permissions ()
		{
			return _permissions;
		}

	private:
		string _path;
		mode_t _permissions;
		bool   _readable;
	}

	class FifoServer : Server
	{
		this (Reactor reactor, Address address)
		{
			if (!cast (NamedPipeAddress) address) {
				throw new Exception("you can only bind to an UnixAddress");
			}

			super(reactor, address);
		}

		override Descriptor start ()
		{
			if (_connection) {
				return _connection.to!Descriptor;
			}

			int  result;
			auto pipe = cast (NamedPipeAddress) address;

			errnoEnforce((result = .mkfifo(pipe.path.toStringz(), pipe.permissions)) == 0);
			errnoEnforce((result = .open(pipe.path.toStringz(), O_RDONLY | O_NONBLOCK)) >= 0);

			_connection = (new Connection).watched(reactor, new Descriptor(result));
			_connection.protocol     = "fifo";
			_connection.asynchronous = true;
			_connection.isWritable   = false;

			_running = true;

			return _connection.to!Descriptor;
		}

		override void stop ()
		{
			if (!isRunning) {
				return;
			}

			remove((cast (NamedPipeAddress) address).path);

			super.stop();
		}

		ubyte[] read ()
		{
			return _connection.read();
		}

		override Connection connection ()
		{
			if (_client) {
				return _client;
			}

			_client = cast (Connection) _handler.create();

			_client.protocol   = "fifo";
			_client.isWritable = false;
			_client.accepted(this, _connection.to!Descriptor);
			if (_block) {
				_block(_client);
			}
			_client.initialized();

			return _client;
		}

		private:
			Connection _client;
	}
}
