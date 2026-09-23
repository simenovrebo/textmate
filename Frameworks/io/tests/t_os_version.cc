#include <oak/compat.h>
#include <io/exec.h>
#include <text/format.h>

void test_os_version ()
{
	OAK_ASSERT(oak::os_major() >= 11); // the minimum supported version

	std::string version = io::exec("/usr/bin/sw_vers", "-productVersion", nullptr);
	version.erase(version.find_last_not_of("\n") + 1);
	std::string expected = text::format("%zu.%zu", oak::os_major(), oak::os_minor());
	if(oak::os_patch())
		expected += text::format(".%zu", oak::os_patch());
	OAK_ASSERT_EQ(expected, version);
}
