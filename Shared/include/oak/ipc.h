#ifndef OAK_IPC_H_6ZP3RW8T
#define OAK_IPC_H_6ZP3RW8T

// Messages between TextMate and the command line tools it provides (tm_dialog, tm_dialog2, the commit window),
// replacing NSConnection (deprecated). The server listens on a Unix domain socket in the user’s temporary
// folder, which only the user can access, and only accepts connections from processes of the same user.
//
// A message is a 32 bit length (network byte order) followed by the data, optionally with file descriptors
// (sent with the length, using SCM_RIGHTS).

#include <string>
#include <vector>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <signal.h>
#include <dirent.h>

namespace oak::ipc
{
	// <user’s temporary folder>/name.pid — the folder is per user and not accessible to others. The folder is
	// taken from confstr() rather than TMPDIR, so that TextMate and the tools agree even when TMPDIR differs.
	inline std::string socket_path (std::string const& name, pid_t pid)
	{
		char buf[PATH_MAX];
		size_t len = confstr(_CS_DARWIN_USER_TEMP_DIR, buf, sizeof(buf));
		std::string dir = len > 0 && len <= sizeof(buf) ? buf : "/tmp/";
		if(dir.back() != '/')
			dir += '/';
		return dir + name + "." + std::to_string(pid);
	}

	// Remove sockets left behind by processes that no longer exist (e.g. after a crash)
	inline void remove_stale_sockets (std::string const& name)
	{
		std::string const path = socket_path(name, 0);
		std::string const dir = path.substr(0, path.rfind('/') + 1), prefix = name + ".";
		if(DIR* dirp = opendir(dir.c_str()))
		{
			while(dirent* entry = readdir(dirp))
			{
				std::string const file = entry->d_name;
				if(entry->d_type != DT_SOCK || file.compare(0, prefix.size(), prefix) != 0)
					continue;

				char* end;
				long pid = strtol(file.c_str() + prefix.size(), &end, 10);
				if(*end == '\0' && pid > 0 && kill((pid_t)pid, 0) == -1 && errno == ESRCH)
					unlink((dir + file).c_str());
			}
			closedir(dirp);
		}
	}

	inline bool make_address (std::string const& path, sockaddr_un& addr)
	{
		addr = { };
		addr.sun_family = AF_UNIX;
		if(path.size() >= sizeof(addr.sun_path))
		{
			errno = ENAMETOOLONG;
			return false;
		}
		strlcpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path));
		return true;
	}

	// Returns the listening socket, or -1 (with errno set)
	inline int listen (std::string const& path)
	{
		sockaddr_un addr;
		if(!make_address(path, addr))
			return -1;

		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if(fd == -1)
			return -1;
		fcntl(fd, F_SETFD, FD_CLOEXEC);

		// Only the user can connect. The folder is already private, so changing the mode after bind() is safe,
		// and unlike changing the umask it does not affect files created by other threads.
		unlink(path.c_str()); // left behind by a process with the same process identifier
		bool ok = bind(fd, (sockaddr*)&addr, sizeof(addr)) == 0 && chmod(path.c_str(), 0600) == 0 && ::listen(fd, SOMAXCONN) == 0;

		if(!ok)
		{
			int err = errno;
			close(fd);
			errno = err;
			return -1;
		}
		return fd;
	}

	// Returns the connected socket, or -1 (with errno set)
	inline int connect (std::string const& path)
	{
		sockaddr_un addr;
		if(!make_address(path, addr))
			return -1;

		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if(fd == -1)
			return -1;
		fcntl(fd, F_SETFD, FD_CLOEXEC);

		int on = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

		if(::connect(fd, (sockaddr*)&addr, sizeof(addr)) == -1)
		{
			int err = errno;
			close(fd);
			errno = err;
			return -1;
		}
		return fd;
	}

	// Accept a connection from a process of the same user, or return -1
	inline int accept (int listenFd)
	{
		int fd = ::accept(listenFd, nullptr, nullptr);
		if(fd == -1)
			return -1;
		fcntl(fd, F_SETFD, FD_CLOEXEC);

		int on = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

		uid_t uid; gid_t gid;
		if(getpeereid(fd, &uid, &gid) == -1 || uid != geteuid())
		{
			close(fd);
			errno = EPERM;
			return -1;
		}
		return fd;
	}

	inline bool write_all (int fd, char const* bytes, size_t len)
	{
		while(len)
		{
			ssize_t n = write(fd, bytes, len);
			if(n == -1 && errno == EINTR)
				continue;
			if(n <= 0)
				return false;
			bytes += n;
			len   -= n;
		}
		return true;
	}

	inline bool read_all (int fd, char* bytes, size_t len)
	{
		while(len)
		{
			ssize_t n = read(fd, bytes, len);
			if(n == -1 && errno == EINTR)
				continue;
			if(n <= 0)
				return false;
			bytes += n;
			len   -= n;
		}
		return true;
	}

	inline bool send_message (int fd, std::string const& data, std::vector<int> const& fds = { })
	{
		if(data.size() > UINT32_MAX)
			return false;

		uint32_t header = htonl((uint32_t)data.size());
		iovec iov = { &header, sizeof(header) };

		std::vector<char> control(fds.empty() ? 0 : CMSG_SPACE(sizeof(int) * fds.size()));
		msghdr msg = { };
		msg.msg_iov    = &iov;
		msg.msg_iovlen = 1;
		if(!fds.empty())
		{
			msg.msg_control    = control.data();
			msg.msg_controllen = (socklen_t)control.size();

			cmsghdr* cmsg   = CMSG_FIRSTHDR(&msg);
			cmsg->cmsg_level = SOL_SOCKET;
			cmsg->cmsg_type  = SCM_RIGHTS;
			cmsg->cmsg_len   = CMSG_LEN(sizeof(int) * fds.size());
			memcpy(CMSG_DATA(cmsg), fds.data(), sizeof(int) * fds.size());
		}

		ssize_t n;
		while((n = sendmsg(fd, &msg, 0)) == -1 && errno == EINTR)
			;
		if(n != sizeof(header))
			return n > 0 && write_all(fd, (char const*)&header + n, sizeof(header) - n) && write_all(fd, data.data(), data.size());
		return write_all(fd, data.data(), data.size());
	}

	// Received file descriptors are owned by the caller
	inline bool receive_message (int fd, std::string* data, std::vector<int>* fds = nullptr, size_t maxSize = 64 * 1024 * 1024)
	{
		uint32_t header;
		iovec iov = { &header, sizeof(header) };

		char control[CMSG_SPACE(sizeof(int) * 16)];
		msghdr msg = { };
		msg.msg_iov        = &iov;
		msg.msg_iovlen     = 1;
		msg.msg_control    = control;
		msg.msg_controllen = sizeof(control);

		ssize_t n;
		while((n = recvmsg(fd, &msg, 0)) == -1 && errno == EINTR)
			;
		if(n <= 0)
			return false;

		for(cmsghdr* cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg))
		{
			if(cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS)
			{
				size_t count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
				int const* received = (int const*)CMSG_DATA(cmsg);
				for(size_t i = 0; i < count; ++i)
				{
					fcntl(received[i], F_SETFD, FD_CLOEXEC);
					if(fds)
						fds->push_back(received[i]);
					else
						close(received[i]);
				}
			}
		}

		if(n < (ssize_t)sizeof(header) && !read_all(fd, (char*)&header + n, sizeof(header) - n))
			return false;

		size_t len = ntohl(header);
		if(len > maxSize)
			return false;

		data->resize(len);
		return read_all(fd, data->data(), len);
	}

} /* oak::ipc */

#endif /* end of include guard: OAK_IPC_H_6ZP3RW8T */
