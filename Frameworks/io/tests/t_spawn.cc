#include <io/exec.h>
#include <signal.h>
#include <pthread.h>

// Run a shell script that signals itself, returning its output and whether it was killed by the signal
static std::pair<std::string, bool> run_signalling_script (int sig)
{
	std::string const script = "kill -" + std::to_string(sig) + " $$; echo survived";
	io::process_t process = io::spawn(std::vector<std::string>{ "/bin/sh", "-c", script });
	OAK_ASSERT(process);
	close(process.in);

	std::string output;
	io::exhaust_fd(process.out, &output);
	close(process.err);

	int status = 0;
	OAK_ASSERT_EQ(waitpid(process.pid, &status, 0), process.pid);
	return { output, WIFSIGNALED(status) && WTERMSIG(status) == sig };
}

void test_spawn_resets_ignored_signals ()
{
	// Commands must not inherit signals ignored by TextMate, or they cannot be interrupted
	struct sigaction ignore = { }, old;
	ignore.sa_handler = SIG_IGN;
	sigaction(SIGINT, &ignore, &old);
	auto const [output, killed] = run_signalling_script(SIGINT);
	sigaction(SIGINT, &old, nullptr);

	OAK_ASSERT_EQ(output, "");
	OAK_ASSERT(killed);
}

void test_spawn_resets_blocked_signals ()
{
	// Threads (e.g. dispatch queues) may block signals, which children must not inherit
	sigset_t block, old;
	sigemptyset(&block);
	sigaddset(&block, SIGTERM);
	pthread_sigmask(SIG_BLOCK, &block, &old);
	auto const [output, killed] = run_signalling_script(SIGTERM);
	pthread_sigmask(SIG_SETMASK, &old, nullptr);

	OAK_ASSERT_EQ(output, "");
	OAK_ASSERT(killed);
}
