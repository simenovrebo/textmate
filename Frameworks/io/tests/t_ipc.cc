#include <oak/ipc.h>
#include <test/jail.h>
#include <thread>

void test_ipc_message ()
{
	int fds[2];
	OAK_ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);

	std::string const large(200000, 'x'); // larger than the socket buffer
	std::thread sender([&]{
		oak::ipc::send_message(fds[0], "hello");
		oak::ipc::send_message(fds[0], "");
		oak::ipc::send_message(fds[0], large);
	});

	std::string data;
	OAK_ASSERT(oak::ipc::receive_message(fds[1], &data));
	OAK_ASSERT_EQ(data, "hello");
	OAK_ASSERT(oak::ipc::receive_message(fds[1], &data));
	OAK_ASSERT_EQ(data, "");
	OAK_ASSERT(oak::ipc::receive_message(fds[1], &data));
	OAK_ASSERT_EQ(data, large);
	sender.join();

	close(fds[0]);
	OAK_ASSERT(!oak::ipc::receive_message(fds[1], &data)); // closed
	close(fds[1]);
}

void test_ipc_file_descriptors ()
{
	int sockets[2], pipeFds[2];
	OAK_ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
	OAK_ASSERT_EQ(pipe(pipeFds), 0);

	OAK_ASSERT(oak::ipc::send_message(sockets[0], "fd", { pipeFds[1] }));
	close(pipeFds[1]);

	std::string data;
	std::vector<int> received;
	OAK_ASSERT(oak::ipc::receive_message(sockets[1], &data, &received));
	OAK_ASSERT_EQ(data, "fd");
	OAK_ASSERT_EQ(received.size(), 1);

	// Writing to the received descriptor reaches the pipe
	OAK_ASSERT_EQ(write(received[0], "abc", 3), 3);
	close(received[0]);

	char buf[8];
	OAK_ASSERT_EQ(read(pipeFds[0], buf, sizeof(buf)), 3);
	OAK_ASSERT_EQ(std::string(buf, 3), "abc");

	close(pipeFds[0]);
	close(sockets[0]);
	close(sockets[1]);
}

void test_ipc_socket_path ()
{
	std::string const path = oak::ipc::socket_path("tm-test", 123);
	OAK_ASSERT(path.ends_with("/tm-test.123"));
	OAK_ASSERT(path.size() < sizeof(sockaddr_un::sun_path));
}

void test_ipc_listen_and_connect ()
{
	test::jail_t jail;
	std::string const path = jail.path("socket");

	int listenFd = oak::ipc::listen(path);
	OAK_ASSERT(listenFd != -1);

	struct stat buf;
	OAK_ASSERT_EQ(stat(path.c_str(), &buf), 0);
	OAK_ASSERT_EQ(buf.st_mode & 077, 0); // only the user can connect

	int clientFd = oak::ipc::connect(path);
	OAK_ASSERT(clientFd != -1);
	int serverFd = oak::ipc::accept(listenFd); // same user
	OAK_ASSERT(serverFd != -1);

	OAK_ASSERT(oak::ipc::send_message(clientFd, "request"));
	std::string data;
	OAK_ASSERT(oak::ipc::receive_message(serverFd, &data));
	OAK_ASSERT_EQ(data, "request");

	OAK_ASSERT(oak::ipc::send_message(serverFd, "reply"));
	OAK_ASSERT(oak::ipc::receive_message(clientFd, &data));
	OAK_ASSERT_EQ(data, "reply");

	close(clientFd);
	close(serverFd);
	close(listenFd);

	OAK_ASSERT_EQ(oak::ipc::connect(jail.path("missing")), -1);
	OAK_ASSERT_EQ(oak::ipc::listen(jail.path(std::string(200, 'x'))), -1);
	OAK_ASSERT_EQ(errno, ENAMETOOLONG);
}

void test_ipc_remove_stale_sockets ()
{
	// A socket of a process that has exited
	pid_t pid = fork();
	if(pid == 0)
		_exit(0);
	waitpid(pid, nullptr, 0);

	std::string const stale = oak::ipc::socket_path("tm-ipc-test", pid);
	std::string const alive = oak::ipc::socket_path("tm-ipc-test", getpid());
	int staleFd = oak::ipc::listen(stale);
	int aliveFd = oak::ipc::listen(alive);
	OAK_ASSERT(staleFd != -1 && aliveFd != -1);
	close(staleFd);

	oak::ipc::remove_stale_sockets("tm-ipc-test");
	OAK_ASSERT_EQ(access(stale.c_str(), F_OK), -1);
	OAK_ASSERT_EQ(access(alive.c_str(), F_OK), 0);

	close(aliveFd);
	unlink(alive.c_str());
}
