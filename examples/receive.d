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

import std.stdio;
import std.getopt;
import std.regex;
import std.conv;
import std.array;

import nucular.reactor;
import line = nucular.protocols.line;

class RawEcho : Connection
{
	override void initialized ()
	{
		writeln(remoteAddress, " connected");
	}

	override void receiveData (ubyte[] data)
	{
		writeln(remoteAddress, "sent: ", data);

		sendData(data);
	}

	override void unbind ()
	{
		if (error) {
			writeln(remoteAddress, " disconnected because: ", error.message);
		}
		else {
			writeln(remoteAddress, " disconnected");
		}
	}
}

class LineEcho : line.Protocol
{
	override void initialized ()
	{
		writeln(remoteAddress, " connected");
	}

	override void receiveLine (string line)
	{
		writeln(remoteAddress, " sent: ", line);

		sendLine(line);
	}

	override void unbind ()
	{
		if (error) {
			writeln(remoteAddress, " disconnected because: ", error.message);
		}
		else {
			writeln(remoteAddress, " disconnected");
		}
	}
}

int main (string[] args)
{
	Address address;
	string  protocol = "tcp";
	string  listen   = "localhost:10000";
	bool    ipv4     = true;
	bool    ipv6     = false;
	bool    line     = false;

	getopt(args, config.noPassThrough,
		"protocol|p", &protocol,
		"4",          &ipv4,
		"6",          &ipv6,
		"line|l",     &line);

	if (args.length >= 2) {
		listen = args.back;
	}

	switch (protocol) {
		case "tcp":
		case "udp":
			if (auto m = listen.match(ctRegex!`^(.*?):(\d+)$`)) {
				string host = m.captures[1];
				ushort port = m.captures[2].to!ushort;

				address = ipv6 ? new Internet6Address(host, port) : new InternetAddress(host, port);
			}
			break;

		version (Posix) {
			case "unix":
				address = new UnixAddress(listen);
				break;

			case "fifo":
				if (auto m = listen.match(r"^(.+?)(?::(\d+))?$")) {
					string path       = m.captures[1];
					int    permission = m.captures[2].empty ? octal!666 : toImpl!int(m.captures[2], 8);

					address = new NamedPipeAddress(path, permission);
				}
				break;
		}
		
		default:
			writeln("! unsupported protocol");
			return 1;
	}

	nucular.reactor.run({
		Server server = line ? address.startServer!LineEcho(protocol) : address.startServer!RawEcho(protocol);
	});

	return 0;
}
