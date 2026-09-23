#include "resource.h"
#include "path.h"
#include <cf/cf.h>
#include <sys/xattr.h>

namespace path
{
	bool is_text_clipping (std::string const& path)
	{
		bool res = false;
		if(extension(path) == "textClipping")
		{
			res = true;
		}
		else
		{
			// The file type is stored (big-endian) in the first 4 bytes of the Finder info
			uint32_t finderInfo[8];
			if(getxattr(path.c_str(), XATTR_FINDERINFO_NAME, finderInfo, sizeof(finderInfo), 0, 0) == sizeof(finderInfo))
				res = OSSwapBigToHostInt32(finderInfo[0]) == kClippingTextType;
		}
		return res;
	}

} /* path */
