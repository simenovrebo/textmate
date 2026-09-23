#include <io/exec.h>
#include <io/path.h>
#include <test/jail.h>

// Only without administrator privileges, which is the same except for the password dialog

void test_do_shell_script ()
{
	std::string output;
	OAK_ASSERT(io::do_shell_script("printf '%s\\n' one two", false, &output));
	OAK_ASSERT_EQ(output, "one\ntwo\n"); // line endings are not changed to \r, only the newline added by osascript is removed

	// Quoting: AppleScript string escapes and shell words
	test::jail_t jail;
	std::string const path = jail.path("a \"quoted\" back\\slash $HOME `x`");
	OAK_ASSERT(io::do_shell_script("/usr/bin/touch " + path::escape(path) + " && /bin/echo -n ok", false, &output));
	OAK_ASSERT_EQ(output, "ok");
	OAK_ASSERT(path::exists(path));

	OAK_ASSERT(!io::do_shell_script("exit 3", false));
}
