#ifndef COMPAT_H_RD1Z6YZA
#define COMPAT_H_RD1Z6YZA

#include <sys/sysctl.h>
#include <array>

namespace oak
{
	// The macOS version (e.g. 15.1.0), previously from Gestalt (deprecated)
	inline std::array<size_t, 3> const& os_version ()
	{
		static std::array<size_t, 3> const res = []{
			std::array<size_t, 3> version = { };
			char buf[32];
			size_t len = sizeof(buf);
			if(sysctlbyname("kern.osproductversion", buf, &len, nullptr, 0) == 0)
				sscanf(buf, "%zu.%zu.%zu", &version[0], &version[1], &version[2]);
			return version;
		}();
		return res;
	}

	inline size_t os_major () { return os_version()[0]; }
	inline size_t os_minor () { return os_version()[1]; }
	inline size_t os_patch () { return os_version()[2]; }

} /* oak */

#endif /* end of include guard: COMPAT_H_RD1Z6YZA */
