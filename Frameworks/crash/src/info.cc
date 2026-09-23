#include "info.h"
#include <oak/debug.h>

// Crash reports include the message of the annotations in the __DATA,__crash_info section (the layout of
// CrashReporterClient.h, version 5, as used by e.g. LLVM). This replaces the __crashreporter_info__ symbol,
// whose REFERENCED_DYNAMICALLY flag is deprecated.
struct crashreporter_annotations_t
{
	uint64_t version;
	uint64_t message;
	uint64_t signature_string;
	uint64_t backtrace;
	uint64_t message2;
	uint64_t thread;
	uint64_t dialog_mode;
	uint64_t abort_cause;
};

extern "C" __attribute__ ((used, section ("__DATA,__crash_info"))) crashreporter_annotations_t gCRAnnotations = { 5 };

static void set_crash_reporter_message (char const* message)
{
	gCRAnnotations.message = (uint64_t)message;
}

namespace
{
	struct stack_t
	{
		void push (std::string const& str)
		{
			_stack.push_back(str);
			update();
		}

		void pop ()
		{
			_stack.pop_back();
			update();
		}

		void assign (std::string const& str)
		{
			_stack.back() = str;
			update();
		}

		void append (std::string const& str)
		{
			_stack.back().append("\n");
			_stack.back().append(str);
			update();
		}

	private:
		void update ()
		{
			set_crash_reporter_message(nullptr);

			bool first = true;
			_description.clear();
			for(auto const& str : _stack)
			{
				if(!std::exchange(first, false))
					_description.append("\n");
				_description.append(str);
			}

			if(!_description.empty())
				set_crash_reporter_message(_description.c_str());
		}

		std::vector<std::string> _stack;
		std::string _description;
	};

	static stack_t& stack ()
	{
		thread_local stack_t stack;
		return stack;
	}
}

crash_reporter_info_t::crash_reporter_info_t (std::string const& str)
{
	stack().push(str);
}

crash_reporter_info_t::crash_reporter_info_t (char const* format, ...)
{
	char* tmp = nullptr;

	va_list ap;
	va_start(ap, format);
	vasprintf(&tmp, format, ap);
	va_end(ap);

	if(tmp)
	{
		stack().push(tmp);
		free(tmp);
	}
}

crash_reporter_info_t::~crash_reporter_info_t ()
{
	stack().pop();
}

crash_reporter_info_t& crash_reporter_info_t::operator= (std::string const& str)
{
	stack().assign(str);
	return *this;
}

crash_reporter_info_t& crash_reporter_info_t::operator<< (std::string const& str)
{
	stack().append(str);
	return *this;
}
