#ifndef FILE_URL_REWRITER_H_4KQ7XB2M
#define FILE_URL_REWRITER_H_4KQ7XB2M

#include <string>
#include <cstring>

// WKWebView does not allow pages served from a custom scheme (command output) to load file:// resources.
// This rewrites file:// to tm-file:// (served by HOFileSchemeHandler) in HTML that is fed in arbitrary chunks.
//
// Only URLs in “URL position” are rewritten, i.e. when file:// is preceded by one of " ' = ( which covers
// attribute values, <base href>, CSS url(…), and string literals in inline scripts, but leaves text alone.
// A file:// URL that is a query parameter, as in txmt://open?url=file://…, is also left alone.

struct file_url_rewriter_t
{
	// Returns the rewritten data that can be passed on. Up to 6 bytes that might be the beginning of
	// “file://” are held back until the next call. Pass last = true to flush.
	std::string feed (char const* bytes, size_t len, bool last = false)
	{
		_pending.append(bytes, len);

		std::string res;
		size_t i = 0;
		while(i < _pending.size())
		{
			size_t const available = _pending.size() - i;
			if(!last && available < kFileScheme.size() && kFileScheme.compare(0, available, _pending, i, available) == 0)
				break; // might be the beginning of “file://”, wait for more data

			if(_pending.compare(i, kFileScheme.size(), kFileScheme) == 0 && _previous != '\0' && std::strchr("\"'=(", _previous) && !(_previous == '=' && _inQuery))
			{
				res += "tm-file://";
				i += kFileScheme.size();
				_previous = '/';
			}
			else
			{
				char const ch = _pending[i++];
				if(ch == '?')
					_inQuery = true;
				else if(ch != '\0' && std::strchr(" \t\n\r\"'<>()", ch))
					_inQuery = false;
				_previous = ch;
				res += ch;
			}
		}
		_pending.erase(0, i);
		return res;
	}

	std::string feed (std::string const& str, bool last = false)
	{
		return feed(str.data(), str.size(), last);
	}

private:
	inline static std::string const kFileScheme = "file://";
	std::string _pending;
	char _previous = ' ';
	bool _inQuery  = false; // after a “?” in the current attribute value or string
};

#endif /* end of include guard: FILE_URL_REWRITER_H_4KQ7XB2M */
